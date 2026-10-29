///|
pub fn cli_argument_start() -> Int32 {
  2
}

///|
#module("node:fs")
extern "js" fn io_open(path : String, flags : String) -> Int32 = "openSync"

///|
#module("node:fs")
extern "js" fn io_write(
  fd : Int32,
  bytes : Bytes,
  offset : Int32,
  length : Int32,
) -> Int32 = "writeSync"

///|
#module("node:fs")
extern "js" fn io_fsync(fd : Int32) -> Unit = "fsyncSync"

///|
#module("node:fs")
extern "js" fn io_close(fd : Int32) -> Unit = "closeSync"

///|
#module("node:fs")
extern "js" fn io_rename(from : String, to : String) -> Unit = "renameSync"

///|
#module("node:fs")
extern "js" fn io_link(from : String, to : String) -> Unit = "linkSync"

///|
#module("node:fs")
extern "js" fn io_unlink(path : String) -> Unit = "unlinkSync"

///|
#external
priv type IoFileStat

///|
#module("node:fs")
extern "js" fn io_stat(path : String) -> IoFileStat = "statSync"

///|
#module("node:fs")
extern "js" fn io_chmod(fd : Int32, mode : Int32) -> Unit = "fchmodSync"

///|
#module("node:path")
extern "js" fn io_dirname(path : String) -> String = "dirname"

///|
extern "js" fn atomic_write_js(
  open : (String, String) -> Int32,
  write : (Int32, Bytes, Int32, Int32) -> Int32,
  fsync : (Int32) -> Unit,
  close : (Int32) -> Unit,
  rename : (String, String) -> Unit,
  link : (String, String) -> Unit,
  unlink : (String) -> Unit,
  stat : (String) -> IoFileStat,
  chmod : (Int32, Int32) -> Unit,
  dirname : (String) -> String,
  path : String,
  bytes : Bytes,
  overwrite : Bool,
) -> String =
  #| (open, write, fsync, close, rename, link, unlink, stat, chmod, dirname, path, bytes, overwrite) => {
  #|   if (!path || path.includes("\0")) return "invalid output path";
  #|   let temporary, fd, ownsTemporary = false;
  #|   try {
  #|     for (let attempt = 0; attempt < 128; attempt++) {
  #|       temporary = `${dirname(path)}/.moonar-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}.tmp`;
  #|       try { fd = open(temporary, "wx"); ownsTemporary = true; break; }
  #|       catch (error) { if (error.code !== "EEXIST") throw error; }
  #|     }
  #|     if (!ownsTemporary) throw new Error("cannot create temporary output");
  #|     if (overwrite) {
  #|       try {
  #|         const previous = stat(path);
  #|         if (previous.isFile()) chmod(fd, previous.mode & 0o777);
  #|       } catch (error) { if (error.code !== "ENOENT") throw error; }
  #|     }
  #|     for (let offset = 0; offset < bytes.length;) {
  #|       const written = write(fd, bytes, offset, bytes.length - offset);
  #|       if (written <= 0) throw new Error("cannot write temporary output");
  #|       offset += written;
  #|     }
  #|     fsync(fd);
  #|     close(fd); fd = undefined;
  #|     if (overwrite) rename(temporary, path);
  #|     else { link(temporary, path); try { unlink(temporary); } catch {} }
  #|     ownsTemporary = false;
  #|     return "";
  #|   } catch (error) {
  #|     if (fd !== undefined) { try { close(fd); } catch {} }
  #|     if (ownsTemporary) { try { unlink(temporary); } catch {} }
  #|     return error.message;
  #|   }
  #| }

///|
pub fn atomic_write(
  path : String,
  data : Bytes,
  overwrite : Bool,
) -> Result[Unit, String] {
  if io_path_bytes(path) is Err(message) {
    return Err(message)
  }
  let error = atomic_write_js(
    io_open, io_write, io_fsync, io_close, io_rename, io_link, io_unlink, io_stat,
    io_chmod, io_dirname, path, data, overwrite,
  )
  if error.is_empty() {
    Ok(())
  } else {
    Err(error)
  }
}

///|
// Use the OS implementation so macOS resolves the stored spelling of names.
extern "js" fn io_realpath(path : String) -> String =
  #| path => process.getBuiltinModule("node:fs").realpathSync.native(path)

///|
#external
priv type CanonicalResult

///|
extern "js" fn canonical_path_js(
  realpath : (String) -> String,
  path : String,
) -> CanonicalResult =
  #| (realpath, path) => {
  #|   try { return { ok: true, text: realpath(path) }; }
  #|   catch (error) { return { ok: false, text: error.message }; }
  #| }

///|
extern "js" fn CanonicalResult::is_ok(self : Self) -> Bool =
  #| result => result.ok

///|
extern "js" fn CanonicalResult::text(self : Self) -> String =
  #| result => result.text

///|
pub fn canonical_path(path : String) -> Result[String, String] {
  if io_path_bytes(path) is Err(message) {
    return Err(message)
  }
  let result = canonical_path_js(io_realpath, path)
  if result.is_ok() {
    Ok(result.text())
  } else {
    Err(result.text())
  }
}

///|
#module("node:path")
extern "js" fn io_relative(from : String, to : String) -> String = "relative"

///|
#module("node:path")
extern "js" fn io_is_absolute(path : String) -> Bool = "isAbsolute"

///|
extern "js" fn check_member_path_js(
  realpath : (String) -> String,
  relative : (String, String) -> String,
  is_absolute : (String) -> Bool,
  base : String,
  target : String,
) -> String =
  #| (realpath, relative, isAbsolute, base, target) => {
  #|   if (!base || !target || base.includes("\0") || target.includes("\0")) return "invalid external member path";
  #|   try {
  #|     const root = realpath(base), resolved = realpath(target);
  #|     const path = relative(root, resolved);
  #|     if (!resolved.startsWith(root)) return "external member resolves outside the archive directory";
  #|     if (!path || path === ".." || path.startsWith("../") || path.startsWith("..\\") || isAbsolute(path))
  #|       return "external member resolves outside the archive directory";
  #|     return "";
  #|   } catch (error) { return error.message; }
  #| }

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
  let error = check_member_path_js(
    io_realpath, io_relative, io_is_absolute, base, target,
  )
  if error.is_empty() {
    Ok(())
  } else {
    Err(error)
  }
}
