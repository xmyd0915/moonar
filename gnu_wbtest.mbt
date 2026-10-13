///|
test "GNU name table preserves raw names and repeated references" {
  let names = b"directory/long_filename.o/\n\xff.o/\n"
  let input = b"!<arch>\n" +
    record("//", names) +
    record("/0", b"one") +
    record("/27", b"two") +
    record("/0", b"three")
  let archive = parsed(input)
  assert_eq(archive.get_member(0).unwrap().kind, NameTable)
  assert_eq(archive.get_member(1).unwrap().name, b"directory/long_filename.o")
  assert_eq(archive.get_member(2).unwrap().name, b"\xff.o")
  assert_eq(archive.get_member(2).unwrap().name_hex(), "ff2e6f")
  assert_eq(
    archive.get_member(3).unwrap().name,
    archive.get_member(1).unwrap().name,
  )
  assert_eq(archive.member_bytes(3), Some(b"three"))
}

///|
test "GNU table can follow a reference and include internal newline padding" {
  let archive = parsed(
    b"!<arch>\n" + record("/0", b"x") + record("//", b"a/\n\n"),
  )
  assert_eq(archive.get_member(0).unwrap().name, b"a")
}

///|
test "GNU references require table entry boundaries" {
  for reference in ["/1", "/100", "/x", "/ 0"] {
    assert_eq(
      error_code(
        b"!<arch>\n" + record("//", b"abc/\n") + record(reference, b""),
      ),
      "AR006",
    )
  }
  assert_eq(error_code(b"!<arch>\n" + record("/0", b"")), "AR006")
}

///|
test "GNU malformed and duplicate name tables fail explicitly" {
  for names in [b"unterminated", b"/\n", b"a/\ninvalid"] {
    assert_eq(error_code(b"!<arch>\n" + record("//", names)), "AR006")
  }
  assert_eq(
    error_code(b"!<arch>\n" + record("//", b"a/\n") + record("//", b"b/\n")),
    "AR006",
  )
}
