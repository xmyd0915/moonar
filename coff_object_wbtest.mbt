///|
fn coff_test_symbol(
  name : Bytes,
  section : UInt32,
  value~ : Int32 = 0,
  storage~ : Int32 = 2,
  aux~ : Int32 = 0,
) -> Bytes {
  let symbol = @buffer.Buffer()
  symbol.write_bytes(name[:])
  for i = name.length(); i < 8; i = i + 1 {
    symbol.write_byte(b'\x00')
  }
  symbol.write_int_le(value)
  symbol.write_uint_le(section)
  symbol.write_uint16_le(0)
  symbol.write_byte(storage.to_byte())
  symbol.write_byte(aux.to_byte())
  symbol.to_bytes()
}

///|
fn coff_test_big(section_count~ : Int32 = 1) -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(b"\x00\x00\xff\xff\x02\x00\x64\x86"[:])
  out.write_int_le(0)
  out.write_bytes(
    b"\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"[:],
  )
  for _i in 0..<4 {
    out.write_int_le(0)
  }
  out.write_int_le(section_count)
  out.write_int_le(56 + section_count * 40)
  out.write_int_le(6)
  out.write_bytes(Bytes::make(section_count * 40, b'\x00')[:])
  out.write_bytes(
    coff_test_symbol(b"defined", section_count.reinterpret_as_uint())[:],
  )
  out.write_bytes(coff_test_symbol(b"absolute", 0xffffffffU)[:])
  out.write_bytes(coff_test_symbol(b"common", 0U, value=4)[:])
  out.write_bytes(coff_test_symbol(b"undef", 0U)[:])
  out.write_bytes(coff_test_symbol(b"alias", 0U, storage=105, aux=1)[:])
  out.write_int_le(0)
  out.write_int_le(3)
  out.write_bytes(Bytes::make(12, b'\x00')[:])
  out.write_int_le(4)
  out.to_bytes()
}

///|
fn coff_test_import(kind~ : Int32 = 0, name_type~ : Int32 = 1) -> Bytes {
  let payload = b"_entry@4\x00example.dll\x00" +
    (if name_type == 4 { b"actual_export\x00" } else { b"" })
  b"\x00\x00\xff\xff\x00\x00\x64\x86" +
  word(0, 4, true) +
  word(payload.length(), 4, true) +
  word(1, 2, true) +
  word(kind | (name_type << 2), 2, true) +
  payload
}

///|
test "bigobj supports 32-bit section numbers auxiliary records and symbol budgets" {
  for count in [1, 65537] {
    let data = coff_test_big(section_count=count)
    assert_eq(object_names(data), [b"defined", b"absolute", b"common", b"alias"])
    assert_true(
      symbols_from_object(data, max_symbols=5) is Err({ code: "OB003", .. }),
    )
    assert_true(
      symbols_from_object(data, max_symbol_name_bytes=25)
      is Err({ code: "OB003", .. }),
    )
  }
}

///|
test "short imports expose code and import-pointer names across name modes" {
  for mode in [0, 1, 2, 3, 4] {
    assert_eq(object_names(coff_test_import(name_type=mode)), [
      b"__imp__entry@4", b"_entry@4",
    ])
    for kind in [1, 2] {
      assert_eq(object_names(coff_test_import(kind~, name_type=mode)), [
        b"__imp__entry@4",
      ])
    }
  }
  let data = coff_test_import()
  assert_true(
    symbols_from_object(data, max_symbols=1) is Err({ code: "OB003", .. }),
  )
  assert_true(
    symbols_from_object(data, max_symbol_name_bytes=21)
    is Err({ code: "OB003", .. }),
  )
  assert_eq(
    symbols_from_object(data, max_symbols=2, max_symbol_name_bytes=22),
    Ok([b"__imp__entry@4", b"_entry@4"]),
  )
}

///|
test "bigobj and short imports reject malformed structures and classify unknown variants" {
  for
    data in [coff_test_big(), coff_test_import(), coff_test_import(name_type=4)] {
    for cut = 4; cut < data.length(); cut = cut + 1 {
      assert_true(symbols_from_object(data[:cut].to_owned()) is Err(_))
    }
  }
  assert_true(
    symbols_from_object(
      object_fixture_put(coff_test_big(), 48, word(8, 4, true)),
    )
    is Err({ code: "OB001", .. }),
  )
  assert_true(
    symbols_from_object(object_fixture_put(coff_test_big(), 12, b"x"))
    is Err({ code: "OB002", .. }),
  )
  assert_true(
    symbols_from_object(
      object_fixture_put(coff_test_import(), 12, word(1, 4, true)),
    )
    is Err({ code: "OB001", .. }),
  )
  assert_true(
    symbols_from_object(object_fixture_put(coff_test_import(), 20, b"\x00"))
    is Err({ code: "OB001", .. }),
  )
  assert_true(
    symbols_from_object(coff_test_import(kind=3)) is Err({ code: "OB002", .. }),
  )
  assert_true(
    symbols_from_object(coff_test_import(name_type=5))
    is Err({ code: "OB002", .. }),
  )
  assert_true(
    symbols_from_object(object_fixture_put(coff_test_import(), 18, b"\x24\x00"))
    is Err({ code: "OB001", .. }),
  )
}
