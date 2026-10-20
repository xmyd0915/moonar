///|
pub fn cli_argument_start() -> Int {
  1
}

///|
pub fn canonical_path(path : String) -> Result[String, String] {
  if io_path_bytes(path) is Err(message) {
    return Err(message)
  }
  Err("external member path resolution requires the native or Node.js CLI")
}

///|
pub fn atomic_write(
  path : String,
  _data : Bytes,
  _overwrite : Bool,
) -> Result[Unit, String] {
  if io_path_bytes(path) is Err(message) {
    return Err(message)
  }
  Err("archive editing requires the native or Node.js CLI")
}

///|
pub fn check_member_path(
  base : String,
  target : String,
) -> Result[Unit, String] {
  if io_path_bytes(base) is Err(message) {
    return Err(message)
  }
  if io_path_bytes(target) is Err(message) {
    return Err(message)
  }
  Err("external member loading requires the native or Node.js CLI")
}
