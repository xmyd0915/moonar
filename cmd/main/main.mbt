///|
fn main {
  // Minimal in-memory example until the file-oriented CLI is introduced.
  let input = b"!<arch>\nnote.txt/       0           0     0     644     3         `\nabc\n"
  match @ar.parse(input) {
    Ok(archive) => {
      let entry = archive.get_member(0).unwrap()
      println("\{entry.name_text()}: \{entry.size} bytes")
    }
    Err(error) => println("\{error.code}: \{error.message}")
  }
}
