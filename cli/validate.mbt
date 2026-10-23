///|
fn valid_path_argument(path : String) -> Bool {
  !path.is_empty() && !path.contains("\u0000")
}

///|
fn validate_manage_options(options : ManageOptions) -> Result[Unit, String] {
  let operation = options.operation
  let paths = options.arguments
  let valid_count = match operation {
    "create" => paths.length() >= 1
    "add" | "delete" => paths.length() >= 2
    "replace" | "move" | "rename" | "extract" => paths.length() == 3
    "convert" => paths.length() == 2
    "index" => paths.length() == 1
    _ => return Err("unknown archive operation; use --help")
  }
  if !valid_count {
    return Err("wrong number of arguments; use --help")
  }
  if paths.any(p => !valid_path_argument(p)) ||
    (options.output is Some(p) && !valid_path_argument(p)) {
    return Err("paths and names must be nonempty and contain no NUL")
  }
  if options.index_mode != "auto" && options.index_mode != "none" {
    return Err("--index must be auto or none")
  }
  if options.thin && operation != "create" {
    return Err("--thin is a create option; edits retain thin storage")
  }
  if options.at is Some(position) {
    if operation != "add" {
      return Err("--at is an add option")
    }
    if position < 0 {
      return Err("--at needs an integer between 0 and 2147483647")
    }
  }
  if options.output is Some(_) &&
    ["create", "convert", "extract"].contains(operation) {
    return Err("this command supplies its output as a positional argument")
  }
  if operation == "extract" &&
    (
      options.format != @ar.Gnu ||
      options.index_mode != "auto" ||
      options.preserve ||
      !options.little_endian
    ) {
    return Err(
      "extract accepts only --force, --allow-parent-paths, --json and limits",
    )
  }
  if operation == "index" && options.index_mode != "auto" {
    return Err("index requires automatic symbol discovery")
  }
  if !options.little_endian &&
    (
      options.format == @ar.Gnu ||
      options.format == @ar.Gnu64 ||
      options.format == @ar.Coff
    ) {
    return Err("--big-endian-index requires a BSD or Darwin format")
  }
  if options.thin && options.format != @ar.Gnu && options.format != @ar.Gnu64 {
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
  Ok(())
}

///|
// Public requests can be built directly, so the runner and argument parser
// share these checks before any injected filesystem operation is called.
fn checked_request(request : Request) -> Result[Request, String] {
  for
    (name, value) in [
      ("--max-bytes", request.max_bytes),
      ("--max-members", request.max_members),
      ("--max-name-bytes", request.max_name_bytes),
      ("--max-symbols", request.max_symbols),
      ("--max-symbol-name-bytes", request.max_symbol_name_bytes),
      ("--max-archive-bytes", request.max_archive_bytes),
    ] {
    if value < 0 {
      return Err("\{name} needs an integer between 0 and 2147483647")
    }
  }
  if request.max_depth < 0 || request.max_depth > 64 {
    return Err("--max-depth must be between 0 and 64")
  }
  if request.logical && !(request.command is Diff(_, _)) {
    return Err("--logical is allowed once, only with diff")
  }
  if request.external && !(request.command is Check(_)) {
    return Err("--external is allowed once, only with check")
  }
  match request.command {
    Manage(options) => {
      if options.allow_parent != request.allow_parent_paths {
        return Err(
          "request and archive options must agree on parent path access",
        )
      }
      match validate_manage_options(options) {
        Ok(_) => ()
        Err(message) => return Err(message)
      }
    }
    command => {
      let paths = match command {
        Inspect(path) | List(path) | Check(path) => [path]
        Diff(before, after) => [before, after]
        _ => []
      }
      if paths.any(p => !valid_path_argument(p)) {
        return Err("paths must be nonempty and contain no NUL")
      }
      if request.allow_parent_paths && !request.external && !request.logical {
        return Err(
          "--allow-parent-paths requires check --external or diff --logical",
        )
      }
    }
  }
  Ok(request)
}
