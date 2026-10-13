///|
pub(all) enum Command {
  Help
  Version
  Inspect(String)
  Check(String)
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
  if args == ["--help"] || args == ["-h"] {
    return Ok({
      command: Help,
      json_output: false,
      max_bytes: 67108864,
      max_members: 100000,
    })
  }
  if args == ["--version"] {
    return Ok({
      command: Version,
      json_output: false,
      max_bytes: 67108864,
      max_members: 100000,
    })
  }
  if args.is_empty() || (args[0] != "inspect" && args[0] != "check") {
    return Err("expected inspect or check; use --help for usage")
  }
  let paths : Array[String] = []
  let mut json_output = false
  let mut max_bytes = 67108864
  let mut max_members = 100000
  let mut saw_bytes = false
  let mut saw_members = false
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
    } else if arg == "--max-bytes" || arg == "--max-members" {
      if i + 1 >= args.length() {
        return Err("\{arg} needs a nonnegative integer")
      }
      guard limit_number(args[i + 1]) is Some(value) else {
        return Err("\{arg} needs an integer between 0 and 2147483647")
      }
      if arg == "--max-bytes" {
        if saw_bytes {
          return Err("--max-bytes was specified more than once")
        }
        saw_bytes = true
        max_bytes = value
      } else {
        if saw_members {
          return Err("--max-members was specified more than once")
        }
        saw_members = true
        max_members = value
      }
      i += 1
    } else if arg.has_prefix("-") {
      return Err("unknown option; use -- before a filename beginning with '-' ")
    } else {
      paths.push(arg)
    }
    i += 1
  }
  if paths.length() != 1 || paths[0].is_empty() {
    return Err("this command needs exactly one input file")
  }
  let command = if args[0] == "inspect" {
    Inspect(paths[0])
  } else {
    Check(paths[0])
  }
  Ok({ command, json_output, max_bytes, max_members, })
}
