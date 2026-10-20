///|
pub fn cli_argument_start() -> Int {
  1
}

///|
#borrow(path, data)
extern "C" fn atomic_write_native(
  path : Bytes,
  data : Bytes,
  size : Int,
  overwrite : Bool,
) -> Bytes = "moonar_atomic_write"

///|
#borrow(base, target)
extern "C" fn check_member_path_native(base : Bytes, target : Bytes) -> Bytes = "moonar_check_member_path"

///|
#borrow(path)
extern "C" fn canonical_path_native(path : Bytes) -> Bytes = "moonar_canonical_path"

///|
pub fn canonical_path(path : String) -> Result[String, String] {
  let path = match io_path_bytes(path) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let result = canonical_path_native(path)
  if !result.is_empty() && result[0] == b'\x00' {
    Ok(@utf8.decode(result[1:])) catch {
      _ => Err("resolved path is not UTF-8")
    }
  } else {
    Err(@utf8.decode_lossy(result[:]))
  }
}

///|
/// Publish a complete file using an exclusively created temporary file in the
/// destination directory. An unsuccessful operation leaves the old file intact.
pub fn atomic_write(
  path : String,
  data : Bytes,
  overwrite : Bool,
) -> Result[Unit, String] {
  let path = match io_path_bytes(path) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let error = atomic_write_native(path, data, data.length(), overwrite)
  if error.is_empty() {
    Ok(())
  } else {
    Err(@utf8.decode_lossy(error[:]))
  }
}

///|
/// Resolve existing paths and require the target to remain inside base.
/// Callers must avoid concurrent path mutation between this check and opening.
pub fn check_member_path(
  base : String,
  target : String,
) -> Result[Unit, String] {
  let base = match io_path_bytes(base) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let target = match io_path_bytes(target) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let error = check_member_path_native(base, target)
  if error.is_empty() {
    Ok(())
  } else {
    Err(@utf8.decode_lossy(error[:]))
  }
}
