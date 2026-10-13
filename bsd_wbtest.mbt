///|
test "BSD name bytes are excluded from payload size" {
  let input = b"!<arch>\n" +
    record("#1/8", b"long.o\x00\x00abc") +
    record("next/", b"z")
  let archive = parsed(input)
  let first = archive.get_member(0).unwrap()
  assert_eq(first.name, b"long.o")
  assert_eq(first.size, 3)
  assert_eq(first.stored_size, 11)
  assert_eq(first.data_offset, 76)
  assert_eq(archive.member_bytes(0), Some(b"abc"))
  assert_eq(archive.get_member(1).unwrap().header_offset, 80)
}

///|
test "BSD symbol tables including sorted 64-bit names remain opaque" {
  for
    name in [
      "__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED",
    ] {
    let archive = parsed(
      b"!<arch>\n" +
      record("#1/\{name.length()}", @utf8.encode(name) + b"index"),
    )
    assert_eq(archive.get_member(0).unwrap().kind, SymbolTable)
    assert_eq(archive.member_bytes(0), Some(b"index"))
  }
  assert_eq(
    parsed(b"!<arch>\n" + record("__.SYMDEF/", b"x")).get_member(0).unwrap().kind,
    SymbolTable,
  )
}

///|
test "BSD names retain non-UTF-8 bytes and trailing spaces" {
  let archive = parsed(b"!<arch>\n" + record("#1/4", b"\xff.o "))
  assert_eq(archive.get_member(0).unwrap().name, b"\xff.o ")
  assert_eq(archive.member_bytes(0), Some(b""))
}

///|
test "BSD name lengths and embedded NUL are validated" {
  for name in ["#1/", "#1/0", "#1/9", "#1/-1", "#1/x", "#1/ 1"] {
    assert_eq(error_code(b"!<arch>\n" + record(name, b"abcd")), "AR006")
  }
  assert_eq(error_code(b"!<arch>\n" + record("#1/4", b"a\x00bc")), "AR006")
  assert_eq(error_code(b"!<arch>\n" + record("#1/2", b"\x00\x00")), "AR006")
}

///|
test "Darwin alignment inside the declared member size remains payload" {
  let archive = parsed(
    b"!<arch>\n" + record("#1/12", b"short.txt\x00\x00\x00abc\n\n\n\n\n"),
  )
  let entry = archive.get_member(0).unwrap()
  assert_eq(entry.name, b"short.txt")
  assert_eq(entry.data_offset, 80)
  assert_eq(entry.size, 8)
  assert_eq(archive.member_bytes(0), Some(b"abc\n\n\n\n\n"))
}
