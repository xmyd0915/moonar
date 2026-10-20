///|
fn io_path_bytes(path : String) -> Result[Bytes, String] {
  let bytes = @utf8.encode(path)
  for byte in bytes {
    if byte == b'\x00' {
      return Err("path contains NUL")
    }
  }
  if bytes.is_empty() {
    return Err("path must not be empty")
  }
  Ok(bytes + b"\x00")
}
