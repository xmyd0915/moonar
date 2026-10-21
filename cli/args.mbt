///|
pub(all) enum Command {
  Help
  Version
  Inspect(String)
  List(String)
  Check(String)
  Diff(String, String)
  Manage(ManageOptions)
} derive(Eq, Debug)

///|
pub extend Command with Eq::{equal, not_equal}

///|
pub extend Command with Debug::{to_repr}

///|
pub(all) struct Request {
  command : Command
  json_output : Bool
  max_bytes : Int
  max_members : Int
  logical : Bool
  max_name_bytes : Int
  max_symbols : Int
  max_symbol_name_bytes : Int
  external : Bool
  allow_parent_paths : Bool
  max_archive_bytes : Int
  max_depth : Int
}

///|
pub(all) struct Reply {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
fn limit_number(text : String) -> Int? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for c in text.iter() {
    let digit = c.to_int() - 48
    if digit < 0 || digit > 9 || value > (2147483647 - digit) / 10 {
      return None
    }
    value = value * 10 + digit
  }
  Some(value)
}

///|
/// Parse arguments excluding the program name. No files are opened here.
pub fn parse_args(args : Array[String]) -> Result[Request, String] {
  if !args.is_empty() &&
    [
      "create", "add", "replace", "delete", "move", "rename", "extract", "convert",
      "index",
    ].contains(args[0]) {
    return parse_manage_args(args)
  }
  if args == ["--help"] || args == ["-h"] {
    return Ok({
      command: Help,
      json_output: false,
      max_bytes: 67108864,
      max_members: 100000,
      logical: false,
      max_name_bytes: 67108864,
      max_symbols: 1000000,
      max_symbol_name_bytes: 67108864,
      external: false,
      allow_parent_paths: false,
      max_archive_bytes: 67108864,
      max_depth: 16,
    })
  }
  if args == ["--version"] {
    return Ok({
      command: Version,
      json_output: false,
      max_bytes: 67108864,
      max_members: 100000,
      logical: false,
      max_name_bytes: 67108864,
      max_symbols: 1000000,
      max_symbol_name_bytes: 67108864,
      external: false,
      allow_parent_paths: false,
      max_archive_bytes: 67108864,
      max_depth: 16,
    })
  }
  if args.is_empty() ||
    (
      args[0] != "inspect" &&
      args[0] != "list" &&
      args[0] != "check" &&
      args[0] != "diff"
    ) {
    return Err("unknown command; use --help for usage")
  }
  let paths : Array[String] = []
  let mut json_output = false
  let mut max_bytes = 67108864
  let mut max_members = 100000
  let mut max_name_bytes = 67108864
  let mut max_symbols = 1000000
  let mut max_symbol_name_bytes = 67108864
  let mut max_archive_bytes = 67108864
  let mut max_depth = 16
  let mut logical = false
  let mut external = false
  let mut allow_parent_paths = false
  let seen : Map[String, Unit] = Map([])
  let mut literal = false
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if literal {
      paths.push(arg)
    } else if arg == "--" {
      literal = true
    } else if arg == "--json" {
      if json_output {
        return Err("--json was specified more than once")
      }
      json_output = true
    } else if arg == "--logical" {
      if args[0] != "diff" || logical {
        return Err("--logical is allowed once, only with diff")
      }
      logical = true
    } else if arg == "--external" {
      if args[0] != "check" || external {
        return Err("--external is allowed once, only with check")
      }
      external = true
    } else if arg == "--allow-parent-paths" {
      if allow_parent_paths {
        return Err("--allow-parent-paths was specified more than once")
      }
      allow_parent_paths = true
    } else if arg == "--max-bytes" ||
      arg == "--max-members" ||
      arg == "--max-name-bytes" ||
      arg == "--max-symbols" ||
      arg == "--max-symbol-name-bytes" ||
      arg == "--max-archive-bytes" ||
      arg == "--max-depth" {
      if i + 1 >= args.length() {
        return Err("\{arg} needs a nonnegative integer")
      }
      guard limit_number(args[i + 1]) is Some(value) else {
        return Err("\{arg} needs an integer between 0 and 2147483647")
      }
      if seen.get(arg) is Some(_) {
        return Err("\{arg} was specified more than once")
      }
      seen[arg] = ()
      match arg {
        "--max-bytes" => max_bytes = value
        "--max-members" => max_members = value
        "--max-name-bytes" => max_name_bytes = value
        "--max-symbols" => max_symbols = value
        "--max-archive-bytes" => max_archive_bytes = value
        "--max-depth" => max_depth = value
        _ => max_symbol_name_bytes = value
      }
      i += 1
    } else if arg.has_prefix("-") {
      return Err("unknown option; use -- before a filename beginning with '-' ")
    } else {
      paths.push(arg)
    }
    i += 1
  }
  if max_depth > 64 {
    return Err("--max-depth must be between 0 and 64")
  }
  let expected_paths = if args[0] == "diff" { 2 } else { 1 }
  if paths.length() != expected_paths ||
    paths.any(fn(path) { path.is_empty() || path.contains("\u0000") }) {
    return Err("this command needs exactly \{expected_paths} input file(s)")
  }
  if allow_parent_paths && !external && !logical {
    return Err(
      "--allow-parent-paths requires check --external or diff --logical",
    )
  }
  let command = if args[0] == "diff" {
    Diff(paths[0], paths[1])
  } else if args[0] == "inspect" {
    Inspect(paths[0])
  } else if args[0] == "list" {
    List(paths[0])
  } else {
    Check(paths[0])
  }
  Ok({
    command,
    json_output,
    max_bytes,
    max_members,
    logical,
    max_name_bytes,
    max_symbols,
    max_symbol_name_bytes,
    external,
    allow_parent_paths,
    max_archive_bytes,
    max_depth,
  })
}
