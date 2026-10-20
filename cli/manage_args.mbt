///|
pub(all) struct ManageOptions {
  operation : String
  arguments : Array[String]
  output : String?
  format : @ar.WriteFormat
  thin : Bool
  index_mode : String
  preserve : Bool
  force : Bool
  at : Int?
  allow_parent : Bool
  little_endian : Bool
} derive(Eq, Debug)

///|
pub extend ManageOptions with Eq::{equal, not_equal}

///|
pub extend ManageOptions with Debug::{to_repr}

///|
fn parse_manage_args(args : Array[String]) -> Result[Request, String] {
  let operation = args[0]
  let paths : Array[String] = []
  let mut output : String? = None
  let mut format = @ar.Gnu
  let mut thin = false
  let mut index_mode = "auto"
  let mut preserve = false
  let mut force = false
  let mut at : Int? = None
  let mut allow_parent = false
  let mut little_endian = true
  let mut json_output = false
  let mut max_bytes = 67108864
  let mut max_members = 100000
  let mut max_name_bytes = 67108864
  let mut max_symbols = 1000000
  let mut max_symbol_name_bytes = 67108864
  let mut literal = false
  let seen : Map[String, Unit] = Map([])
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if literal {
      paths.push(arg)
    } else if arg == "--" {
      literal = true
    } else if !arg.has_prefix("-") {
      paths.push(arg)
    } else {
      if seen.contains(arg) {
        return Err("duplicate option: \{arg}")
      }
      seen[arg] = ()
      match arg {
        "--thin" => thin = true
        "--preserve-metadata" => preserve = true
        "--force" => force = true
        "--allow-parent-paths" => allow_parent = true
        "--big-endian-index" => little_endian = false
        "--json" => json_output = true
        "--output"
        | "--format"
        | "--index"
        | "--at"
        | "--max-bytes"
        | "--max-members"
        | "--max-name-bytes"
        | "--max-symbols"
        | "--max-symbol-name-bytes" => {
          if i + 1 >= args.length() {
            return Err("\{arg} needs a value")
          }
          i += 1
          let value = args[i]
          match arg {
            "--output" => output = Some(value)
            "--index" => {
              if value != "auto" && value != "none" {
                return Err("--index must be auto or none")
              }
              index_mode = value
            }
            "--format" =>
              format = match value {
                "gnu" => @ar.Gnu
                "gnu64" => @ar.Gnu64
                "bsd" => @ar.Bsd
                "bsd64" => @ar.Bsd64
                "darwin" => @ar.Darwin
                "darwin64" => @ar.Darwin64
                _ => return Err("unsupported output format")
              }
            _ => {
              guard limit_number(value) is Some(number) else {
                return Err("\{arg} needs an integer between 0 and 2147483647")
              }
              match arg {
                "--at" => at = Some(number)
                "--max-bytes" => max_bytes = number
                "--max-members" => max_members = number
                "--max-name-bytes" => max_name_bytes = number
                "--max-symbols" => max_symbols = number
                _ => max_symbol_name_bytes = number
              }
            }
          }
        }
        _ => return Err("unknown option: \{arg}")
      }
    }
    i += 1
  }
  if paths.any(p => p.is_empty() || p.contains("\u0000")) ||
    (output is Some(p) && (p.is_empty() || p.contains("\u0000"))) {
    return Err("paths and names must be nonempty and contain no NUL")
  }
  let valid_count = match operation {
    "create" => paths.length() >= 1
    "add" | "delete" => paths.length() >= 2
    "replace" | "move" | "rename" | "extract" => paths.length() == 3
    "convert" => paths.length() == 2
    "index" => paths.length() == 1
    _ => false
  }
  if !valid_count {
    return Err("wrong number of arguments; use --help")
  }
  if thin && operation != "create" {
    return Err("--thin is a create option; edits retain thin storage")
  }
  if at is Some(_) && operation != "add" {
    return Err("--at is an add option")
  }
  if output is Some(_) && ["create", "convert", "extract"].contains(operation) {
    return Err("this command supplies its output as a positional argument")
  }
  if operation == "extract" &&
    seen
    .keys()
    .any(k => {
      k != "--force" &&
      k != "--allow-parent-paths" &&
      k != "--json" &&
      !k.has_prefix("--max-")
    }) {
    return Err(
      "extract accepts only --force, --allow-parent-paths, --json and limits",
    )
  }
  if operation == "index" && index_mode != "auto" {
    return Err("index requires automatic symbol discovery")
  }
  if !little_endian && (format == @ar.Gnu || format == @ar.Gnu64) {
    return Err("--big-endian-index requires a BSD or Darwin format")
  }
  if thin && format != @ar.Gnu && format != @ar.Gnu64 {
    return Err("thin output requires gnu or gnu64")
  }
  let numeric_positions = match operation {
    "replace" | "rename" | "extract" => [1]
    "move" => [1, 2]
    "delete" => Array::makei(paths.length() - 1, fn(i) { i + 1 })
    _ => []
  }
  for position in numeric_positions {
    if limit_number(paths[position]) is None {
      return Err("member positions must be nonnegative integers")
    }
  }
  Ok({
    command: Manage({
      operation,
      arguments: paths,
      output,
      format,
      thin,
      index_mode,
      preserve,
      force,
      at,
      allow_parent,
      little_endian,
    }),
    json_output,
    max_bytes,
    max_members,
    max_name_bytes,
    max_symbols,
    max_symbol_name_bytes,
    logical: false,
  })
}
