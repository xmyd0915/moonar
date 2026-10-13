///|
fn field(text : String, width : Int) -> String {
  text + " ".repeat(width - text.length())
}

///|
fn record(name : String, payload : Bytes, date? : String = "0") -> Bytes {
  let header = field(name, 16) +
    field(date, 12) +
    field("0", 6) +
    field("0", 6) +
    field("644", 8) +
    field(payload.length().to_string(), 10) +
    "`\n"
  let padding = if payload.length() % 2 == 1 { b"\n" } else { b"" }
  @utf8.encode(header) + payload + padding
}

///|
fn parsed(input : Bytes) -> Archive raise {
  match parse(input) {
    Ok(archive) => archive
    Err(error) => fail("\{error.code} at \{error.offset}: \{error.message}")
  }
}

///|
fn error_code(input : Bytes) -> String raise {
  match parse(input) {
    Err(error) => error.code
    Ok(_) => fail("expected malformed archive to fail")
  }
}

///|
test "empty archive and invalid signature" {
  assert_eq(parsed(b"!<arch>\n").member_count(), 0)
  assert_eq(error_code(b""), "AR001")
  assert_eq(error_code(b"!<thin>\n"), "AR007")
}

///|
test "members preserve order, duplicate names and binary payload" {
  let input = b"!<arch>\n" +
    record("a.o/", b"\x00\xff\x01") +
    record("a.o/", b"two!")
  let archive = parsed(input)
  assert_eq(archive.member_count(), 2)
  let first = archive.get_member(0).unwrap()
  assert_eq(first.name, b"a.o")
  assert_eq(first.header_offset, 8)
  assert_eq(first.data_offset, 68)
  assert_eq(first.size, 3)
  assert_eq(first.metadata.mode, Some(420L))
  assert_eq(archive.get_member(1).unwrap().header_offset, 72)
  assert_eq(archive.member_bytes(0), Some(b"\x00\xff\x01"))
  assert_eq(archive.member_bytes(-1), None)
  assert_eq(archive.get_member(2), None)
}

///|
test "malformed fields and payloads are rejected" {
  assert_eq(error_code(b"!<arch>\npartial"), "AR002")
  assert_eq(error_code(b"!<arch>\n" + record("a/", b"", date="x")), "AR004")
  let odd = b"!<arch>\n" + record("a/", b"x")
  assert_eq(error_code(odd[:odd.length() - 1].to_owned()), "AR003")
  assert_eq(error_code(odd[:odd.length() - 2].to_owned()), "AR002")
  let bad_trailer = b"!<arch>\n" + @utf8.encode(field("a/", 58)) + b"??"
  assert_eq(error_code(bad_trailer), "AR003")
}

///|
test "resource limits fail before reading another record" {
  let input = b"!<arch>\n" + record("a/", b"")
  assert_true(parse(input, max_members=0) is Err({ code: "AR008", .. }))
  assert_true(parse(input, max_bytes=7) is Err({ code: "AR008", .. }))
  assert_true(parse(input, max_bytes=-1) is Err({ code: "AR008", .. }))
}

///|
test "symbol indexes are exposed as opaque records" {
  let archive = parsed(b"!<arch>\n" + record("/", b"index"))
  assert_eq(archive.get_member(0).unwrap().kind, SymbolTable)
  assert_eq(archive.member_bytes(0), Some(b"index"))
}
