///|
fn archive_input_error(
  request : Request,
  path : String,
  error : @ar.ParseError,
  exit_code : Int,
) -> Reply {
  if request.json_output {
    {
      exit_code,
      stdout: Json::object({
        "schema_version": Json(1),
        "input": Json(path),
        "error": Json::object({
          "code": Json(error.code),
          "offset": Json(error.offset),
          "message": Json(error.message),
        }),
      }).stringify() +
      "\n",
      stderr: "",
    }
  } else {
    {
      exit_code,
      stdout: "",
      stderr: "\{Json(path).stringify()}: \{error.code} at byte \{error.offset}: \{Json(error.message).stringify()}\n",
    }
  }
}

///|
// The library validates portable paths and declared sizes before this callback.
// The filesystem adapter resolves links before a read unless parent access is
// explicitly allowed. It still reads whole files; size limits are not read caps.
fn external_reader(
  archive_path : String,
  allow_parent_paths : Bool,
  read : (String) -> Result[Bytes, String],
  validate_path : (String, String) -> Result[Unit, String],
) -> (Bytes, Int) -> Result[Bytes, String] {
  fn(name, _expected) {
    let name = @utf8.decode(name[:], ignore_bom=false) catch {
      _ => return Err("filesystem member paths must be UTF-8")
    }
    let base = path_dir(archive_path)
    let path = joined_path(base, name)
    if !allow_parent_paths {
      match validate_path(base, path) {
        Ok(_) => ()
        Err(message) => return Err("\{path}: \{message}")
      }
    }
    match read(path) {
      Ok(bytes) => Ok(bytes)
      Err(message) => Err("\{path}: \{message}")
    }
  }
}

///|
fn nested_limits(request : Request) -> @ar.NestedLimits {
  @ar.NestedLimits::new(
    max_bytes=request.max_archive_bytes,
    max_depth=request.max_depth,
    max_members=request.max_members,
    max_name_bytes=request.max_name_bytes,
    max_symbols=request.max_symbols,
    max_symbol_name_bytes=request.max_symbol_name_bytes,
  )
}
