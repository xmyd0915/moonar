///|
// Run from the repository root. No extraction or decompression happens here.
fn read_demo() -> Unit raise {
  let bytes = @fs.read_file_to_bytes("examples/data/demo.deb")
  let archive = match @ar.parse(bytes) {
    Ok(archive) => archive
    Err(error) =>
      fail("\{error.code} at byte \{error.offset}: \{error.message}")
  }
  let mut found_version = false
  for i = 0; i < archive.member_count(); i = i + 1 {
    let entry = archive.get_member(i).unwrap()
    if entry.kind != @ar.Regular {
      continue
    }
    println("\{Json(entry.name_text()).stringify()}: \{entry.size} bytes")
    if entry.name == b"debian-binary" {
      found_version = archive.member_bytes(i) == Some(b"2.0\n")
    }
  }
  guard found_version else { fail("expected the Debian 2.0 version marker") }
  println("Read the version marker through the public library API.")
}

///|
fn main {
  read_demo() catch {
    error => {
      eprintln(error)
      @sys.exit(1)
    }
  }
}
