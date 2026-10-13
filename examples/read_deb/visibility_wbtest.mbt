///|
test "changing a returned record does not change the parsed archive" {
  let archive = @ar.parse(
    b"!<arch>\nitem/           0           0     0     644     1         `\nx\n",
  ).unwrap()
  let entry = archive.get_member(0).unwrap()
  let changed = { ..entry, data_offset: 2147483647, size: 100, }
  assert_eq(changed.data_offset, 2147483647)
  assert_eq(archive.get_member(0), Some(entry))
  assert_eq(archive.member_bytes(0), Some(b"x"))
}
