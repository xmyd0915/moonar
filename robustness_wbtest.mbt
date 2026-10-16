///|
test "every truncated prefix either ends on a record boundary or fails" {
  let first = record("//", b"long_filename.o/\n")
  let second = record("/0", b"abc")
  let third = record("#1/4", b"x.o\x00yz")
  let bytes = b"!<arch>\n" + first + second + third
  let valid_ends = [
    8,
    8 + first.length(),
    8 + first.length() + second.length(),
    bytes.length(),
  ]
  for length = 0; length <= bytes.length(); length = length + 1 {
    match parse(bytes[:length].to_owned()) {
      Ok(_) => assert_true(valid_ends.contains(length))
      Err(error) => {
        assert_false(valid_ends.contains(length))
        assert_true(error.offset >= 0 && error.offset <= length)
      }
    }
  }
}

///|
test "mutated headers and payloads never panic and keep bounded diagnostics" {
  let input = b"!<arch>\n" +
    record("//", b"long_filename.o/\n") +
    record("/0", b"abc") +
    record("#1/4", b"x.o\x00yz")
  for index = 0; index < input.length(); index = index + 1 {
    for replacement in [b'\x00', b'\x7f', b'\xff'] {
      let changed = Bytes::makei(input.length(), fn(i) {
        if i == index {
          replacement
        } else {
          input[i]
        }
      })
      match parse(changed) {
        Ok(archive) =>
          for i = 0; i < archive.member_count(); i = i + 1 {
            let entry = archive.get_member(i).unwrap()
            assert_eq(archive.member_bytes(i).unwrap().length(), entry.size)
          }
        Err(error) =>
          assert_true(error.offset >= 0 && error.offset <= input.length())
      }
    }
  }
}

///|
test "name expansion is bounded even when many records share one GNU name" {
  let table = record("//", @utf8.encode("n".repeat(1000)) + b"/\n")
  let refs = record("/0", b"").repeat(20)
  let input = b"!<arch>\n" + table + refs
  assert_true(input.length() < 3000)
  assert_true(parse(input, max_name_bytes=3000) is Err({ code: "AR008", .. }))
  assert_true(parse(input, max_name_bytes=20002) is Ok(_))
  assert_true(parse(input, max_name_bytes=-1) is Err({ code: "AR008", .. }))
}

///|
test "header integer overflow and octal modes are checked" {
  let prefix = b"!<arch>\n" +
    @utf8.encode(
      field("a/", 16) + field("0", 12) + field("0", 6) + field("0", 6),
    )
  assert_eq(
    error_code(prefix + @utf8.encode(field("888", 8) + field("0", 10)) + b"`\n"),
    "AR004",
  )
  assert_eq(
    error_code(prefix + @utf8.encode(field("644", 8) + "9999999999") + b"`\n"),
    "AR005",
  )
  assert_eq(
    error_code(prefix + @utf8.encode(field("644", 8) + field("", 10)) + b"`\n"),
    "AR004",
  )
}

///|
test "NUL names are rejected consistently across name encodings" {
  assert_eq(error_code(b"!<arch>\n" + record("a\u0000b/", b"")), "AR006")
  assert_eq(
    error_code(b"!<arch>\n" + record("//", b"a\x00b/\n") + record("/0", b"")),
    "AR006",
  )
}
