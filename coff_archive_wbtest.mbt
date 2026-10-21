///|
fn coff_test_archive() -> Bytes raise {
  writer_ok(
    writer_plan([
      WriteMember::new(b"long_object_filename.obj", b"abc"),
      WriteMember::new(b"long_object_filename.obj", b"xyz"),
    ]).write(
      format=Coff,
      symbols=Some([
        { name: b"z", member_index: 0, },
        { name: b"a", member_index: 1, },
        { name: b"a", member_index: 0, },
      ]),
    ),
  )
}

///|
test "COFF truncation and hostile byte mutations always return bounded parser results" {
  let data = coff_test_archive()
  for end in 0..<data.length() {
    ignore(parse(data[:end].to_owned()))
  }
  for i in 0..<data.length() {
    for value in [b'\x00', b'\xff', b' ', b'\n'] {
      let mutated = Bytes::makei(data.length(), fn(j) {
        if j == i {
          value
        } else {
          data[j]
        }
      })
      ignore(parse(mutated, max_symbols=1000, max_symbol_name_bytes=10000))
    }
  }
}

///|
test "COFF writer and parser preserve duplicate members and canonical sorted mappings" {
  let bytes = coff_test_archive()
  let archive = parsed(bytes)
  assert_eq(archive.member_count(), 5)
  assert_eq(archive.symbol_indexes().length(), 1)
  let index = archive.symbol_indexes()[0]
  assert_eq(index.format, "coff")
  assert_eq(index.record_index, 1)
  assert_eq(index.symbols.map(s => (s.name, s.member_index)), [
    (b"a", 4),
    (b"a", 3),
    (b"z", 3),
  ])
  assert_eq(archive.member_bytes(3), Some(b"abc"))
  assert_eq(archive.member_bytes(4), Some(b"xyz"))
  let plan = writer_ok(archive.edit(drop_symbol_indexes=true))
  let other = parsed(
    writer_ok(
      plan.write(
        symbols=Some([
          { name: b"z", member_index: 0, },
          { name: b"a", member_index: 1, },
          { name: b"a", member_index: 0, },
        ]),
      ),
    ),
  )
  let compared = compare_logical(archive, other)
  assert_true(compared.content_equal && compared.symbols_equal)
  assert_false(compared.symbol_index_presence_changed)
  assert_eq(
    writer_ok(
      plan.write(
        format=Coff,
        symbols=Some([
          { name: b"z", member_index: 0, },
          { name: b"a", member_index: 1, },
          { name: b"a", member_index: 0, },
        ]),
      ),
    ),
    bytes,
  )
}

///|
test "COFF validates both linker members sorted offsets names and agreement" {
  let bytes = coff_test_archive()
  let archive = parsed(bytes)
  let first = archive.get_member(0).unwrap().data_offset
  let second = archive.get_member(1).unwrap().data_offset
  for
    (offset, value) in [
      (
        first + 4,
        word(archive.get_member(3).unwrap().header_offset + 1, 4, false),
      ),
      (second + 4, word(8, 4, true)),
      (second + 8, word(archive.get_member(3).unwrap().header_offset, 4, true)),
      (second + 16, word(0, 2, true)),
      (second + 16, word(1, 2, true)),
      (second + 22, b"z"),
    ] {
    assert_true(
      parse(object_fixture_put(bytes, offset, value))
      is Err({ code: "AR009", .. }),
    )
  }
  assert_true(parse(bytes, max_symbols=5) is Err({ code: "AR008", .. }))
  assert_true(
    parse(bytes, max_symbol_name_bytes=5) is Err({ code: "AR008", .. }),
  )
  assert_true(parse(bytes, max_symbols=6, max_symbol_name_bytes=6) is Ok(_))
}

///|
test "COFF long names use NUL boundaries and preserve special spellings" {
  let plan = writer_plan([
    WriteMember::new(b"__.SYMDEF", b"x"),
    WriteMember::new(b"line\nname", b""),
    WriteMember::new(b"//", b"y"),
  ])
  let archive = parsed(writer_ok(plan.write(format=Coff)))
  assert_eq(
    writer_ok(archive.edit(drop_symbol_indexes=true)).members(),
    plan.members(),
  )
  assert_eq(archive.symbol_indexes()[0].symbols, [])
  let bytes = writer_ok(plan.write(format=Coff))
  let offset = archive.get_member(2).unwrap().data_offset
  assert_true(
    parse(
      object_fixture_put(
        bytes,
        offset + archive.get_member(2).unwrap().size - 1,
        b"x",
      ),
    )
    is Err({ code: "AR006", .. }),
  )
}

///|
test "COFF layout and duplicate symbol-table budgets fail before serialization" {
  let empty = writer_ok(ArchiveBuilder::new().write(format=Coff))
  assert_eq(empty.length(), 140)
  assert_eq(parsed(empty).symbol_indexes()[0].format, "coff")
  assert_true(
    ArchiveBuilder::new().write(format=Coff, max_members=1)
    is Err({ code: "WR003", .. }),
  )
  assert_true(
    ArchiveBuilder::new().write(format=Coff, max_bytes=139)
    is Err({ code: "WR003", .. }),
  )
  let plan = writer_plan([WriteMember::new(b"a", b"x")])
  let symbols = [{ name: b"entry", member_index: 0, }]
  assert_true(
    plan.write(format=Coff, symbols=Some(symbols), max_symbols=1)
    is Err({ code: "WR003", .. }),
  )
  assert_true(
    plan.write(format=Coff, symbols=Some(symbols), max_symbol_name_bytes=9)
    is Err({ code: "WR003", .. }),
  )
  assert_true(
    plan.write(format=Coff, symbols=Some([{ name: b"x", member_index: 1, }]))
    is Err({ code: "WR005", .. }),
  )
  assert_true(
    plan.write(format=Coff, symbols=Some(symbols), max_symbol_name_bytes=10)
    is Ok(_),
  )
}

///|
test "COFF symbol ordering is lexical rather than length-first and unknown timestamps are absent" {
  let bytes = writer_ok(
    writer_plan([
      WriteMember::new(b"a.obj", b"x"),
      WriteMember::new(b"b.obj", b"y"),
    ]).write(
      format=Coff,
      symbols=Some([
        { name: b"moon_beta", member_index: 1, },
        { name: b"moon_alpha", member_index: 0, },
      ]),
    ),
  )
  let archive = parsed(bytes)
  assert_eq(archive.symbol_indexes()[0].symbols.map(s => s.name), [
    b"moon_alpha", b"moon_beta",
  ])
  let mut sentinel = bytes
  for entry in archive.records {
    sentinel = object_fixture_put(
      sentinel,
      entry.header_offset + 16,
      b"-1          ",
    )
  }
  let imported = parsed(sentinel)
  assert_true(imported.records.all(entry => entry.metadata.timestamp is None))
  let plan = writer_ok(imported.edit(drop_symbol_indexes=true))
  assert_true(plan.write(format=Coff, metadata=Preserve) is Ok(_))
  let ordinary = writer_ok(plan.write())
  assert_true(
    parse(object_fixture_put(ordinary, 24, b"-1          "))
    is Err({ code: "AR004", .. }),
  )
}
