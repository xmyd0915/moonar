///|
test "GCC slim object markers cannot become misleading archive definitions" {
  for wide in [false, true] {
    for little in [false, true] {
      assert_true(
        symbols_from_object(object_fixture_elf(wide, little, slim=true))
        is Err({ code: "OB002", .. }),
      )
    }
  }
  let data = object_fixture_coff()
  let slim = object_fixture_put(
    data,
    data.length() - b"long_external_name\x00".length(),
    b"__gnu_lto_slim\x00",
  )
  assert_true(symbols_from_object(slim) is Err({ code: "OB002", .. }))
  let plan = writer_plan([WriteMember::new(b"slim.o", slim)])
  assert_true(
    plan.discover_symbols() is Err({ code: "WR006", member_index: Some(0), .. }),
  )
  assert_true(
    plan.write(symbols=Some([{ name: b"supplied", member_index: 0, }])) is Ok(_),
  )
}
