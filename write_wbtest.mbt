///|
fn[T] writer_ok(result : Result[T, WriteError]) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
fn[T] writer_code(result : Result[T, WriteError]) -> String raise {
  match result {
    Ok(_) => fail("expected a write error")
    Err(error) => error.code
  }
}

///|
fn writer_plan(entries : Array[WriteMember]) -> ArchiveBuilder raise {
  writer_ok(ArchiveBuilder::from_members(entries))
}

///|
test "writer empty and short-name GNU bytes are deterministic" {
  let empty = ArchiveBuilder::new()
  assert_eq(writer_ok(empty.write()), b"!<arch>\n")
  let builder = writer_ok(empty.append(WriteMember::new(b"a.o", b"one")))
  let bytes = writer_ok(builder.write())
  assert_eq(bytes, b"!<arch>\n" + record("a.o/", b"one"))
  assert_eq(writer_ok(builder.write()), bytes)
  assert_eq(empty.member_count(), 0)
}

///|
test "writer bulk construction isolates input and reports the failing position" {
  let entries = [
    WriteMember::new(b"same", b"one"),
    WriteMember::new(b"same", b"two"),
    WriteMember::new(b"last", b"three"),
  ]
  let builder = writer_ok(ArchiveBuilder::from_members(entries))
  entries[1] = WriteMember::new(b"", b"invalid")
  assert_eq(builder.members()[1].data, b"two")
  match ArchiveBuilder::from_members(entries) {
    Err(error) => {
      assert_eq(error.code, "WR001")
      assert_eq(error.member_index, Some(1))
    }
    Ok(_) => fail("bulk creation must reject an invalid name")
  }
  assert_eq(entries.length(), 3)
  let bulk = Array::makei(2000, fn(index) {
    WriteMember::new(b"same", @utf8.encode(index.to_string()))
  })
  let builder = writer_ok(ArchiveBuilder::from_members(bulk))
  assert_eq(parsed(writer_ok(builder.write())).member_count(), 2000)
}

///|
test "writer GNU and BSD preserve names payloads and duplicate order" {
  let entries = [
    WriteMember::new(b"short", b""),
    WriteMember::new(b"long_filename_for_an_object.o", b"\x00\xff\n"),
    WriteMember::new(b"long_filename_for_an_object.o", b"second"),
    WriteMember::new(b" leading and trailing ", b"\n\n"),
    WriteMember::new(b"directory/object.o", b"abc"),
    WriteMember::new(b"#1/12", b"xyz"),
    WriteMember::new(b"/123", b"a"),
    WriteMember::new(b"\xff", b"z"),
    WriteMember::new(b"end/", b"q"),
    WriteMember::new(b"#1", b"marker"),
  ]
  let builder = writer_plan(entries)
  for format in [Gnu, Bsd] {
    let archive = parsed(writer_ok(builder.write(format~)))
    let restored = writer_ok(archive.edit())
    assert_eq(restored.members(), entries)
    assert_eq(archive.symbol_indexes(), [])
    if format == Gnu {
      assert_eq(archive.get_member(0).unwrap().kind, NameTable)
      assert_eq(archive.get_member(0).unwrap().name, b"//")
      let table = archive.member_bytes(0).unwrap()
      // The duplicate long name has one physical table entry.
      assert_eq(
        table, b"long_filename_for_an_object.o/\n leading and trailing /\ndirectory/object.o/\n#1/12/\n/123/\nend//\n#1/\n",
      )
    }
  }
}

///|
test "writer raw member-name bytes roundtrip in both encodings" {
  for format in [Gnu, Bsd] {
    let mut builder = ArchiveBuilder::new()
    for value = 1; value < 256; value = value + 1 {
      if format != Gnu || value != 10 {
        let name = b"x" + Bytes::make(1, value.to_byte()) + b"y"
        builder = writer_ok(builder.append(WriteMember::new(name, name)))
      }
    }
    let restored = writer_ok(parsed(writer_ok(builder.write(format~))).edit())
    assert_eq(restored.members(), builder.members())
  }
}

///|
test "writer GNU rejects delimiter ambiguity and BSD preserves it" {
  for name in [b"path/\nnext", b"line\nbreak.o"] {
    let builder = writer_plan([WriteMember::new(name, b"body")])
    assert_eq(writer_code(builder.write(format=Gnu)), "WR001")
    let archive = parsed(writer_ok(builder.write(format=Bsd)))
    assert_eq(archive.get_member(0).unwrap().name, name)
    assert_eq(archive.member_bytes(0), Some(b"body"))
  }
}

///|
test "writer edits target exact ordinary-member positions and are atomic" {
  let original = writer_plan([
    WriteMember::new(b"same", b"first"),
    WriteMember::new(b"same", b"second"),
    WriteMember::new(b"last", b"third"),
  ])
  let changed = writer_ok(
    original.replace(1, WriteMember::new(b"same", b"new")),
  )
  let changed = writer_ok(changed.remove(0))
  let changed = writer_ok(changed.move_member(1, 0))
  let changed = writer_ok(changed.append(WriteMember::new(b"last", b"fourth")))
  assert_eq(changed.members().map(fn(entry) { entry.data }), [
    b"third", b"new", b"fourth",
  ])
  assert_eq(original.members().map(fn(entry) { entry.data }), [
    b"first", b"second", b"third",
  ])
  for invalid in [-1, 3, 2147483647] {
    assert_eq(writer_code(original.remove(invalid)), "WR001")
    assert_eq(
      writer_code(original.replace(invalid, WriteMember::new(b"x", b"y"))),
      "WR001",
    )
    assert_eq(writer_code(original.move_member(invalid, 0)), "WR001")
    assert_eq(writer_code(original.move_member(0, invalid)), "WR001")
  }
  assert_eq(
    writer_ok(original.move_member(0, 2))
    .members()
    .map(fn(entry) { entry.data }),
    [b"second", b"third", b"first"],
  )
  assert_eq(writer_ok(original.move_member(1, 1)).members(), original.members())
  let exposed = original.members()
  exposed[0] = WriteMember::new(b"external", b"change")
  assert_eq(original.members()[0].name, b"same")
  assert_eq(
    writer_code(original.replace(0, WriteMember::new(b"", b"bad"))),
    "WR001",
  )
  assert_eq(original.member_count(), 3)
}

///|
test "writer rejects empty and NUL member names" {
  let empty = ArchiveBuilder::new()
  for name in [b"", b"a\x00b"] {
    assert_eq(writer_code(empty.append(WriteMember::new(name, b""))), "WR001")
  }
  assert_eq(empty.member_count(), 0)
}

///|
test "writer GNU preserves reserved names through ordinary table references" {
  let entries = [
    b"/", b"//", b"/SYM64/", b"__.SYMDEF", b"__.SYMDEF SORTED", b"__.SYMDEF_64",
    b"__.SYMDEF_64 SORTED",
  ].map(fn(name) { WriteMember::new(name, b"ordinary content") })
  let builder = writer_plan(entries)
  for format in [Gnu, Gnu64] {
    let archive = parsed(writer_ok(builder.write(format~)))
    assert_eq(archive.symbol_indexes(), [])
    assert_eq(archive.member_count(), 8)
    for index = 1; index < 8; index = index + 1 {
      assert_eq(archive.get_member(index).unwrap().kind, Regular)
    }
    assert_eq(writer_ok(archive.edit()).members(), entries)
    let indexed = parsed(
      writer_ok(
        builder.write(
          format~,
          symbols=Some([{ name: b"entry", member_index: 3, }]),
        ),
      ),
    )
    assert_eq(indexed.symbol_indexes()[0].symbols[0].member_index, 5)
    assert_eq(indexed.get_member(5).unwrap().name, b"__.SYMDEF")
  }
  for format in [Bsd, Bsd64, Darwin, Darwin64] {
    for entry in entries {
      assert_eq(writer_code(writer_plan([entry]).write(format~)), "WR001")
    }
  }
}

///|
test "writer metadata preservation is explicit and blank fields roundtrip" {
  let source : Metadata = {
    timestamp: Some(123456789L),
    uid: Some(123L),
    gid: Some(456L),
    mode: Some(33261L),
  }
  let blank : Metadata = { timestamp: None, uid: None, gid: None, mode: None, }
  let builder = writer_plan([
    WriteMember::new(b"a", b"data", metadata=source),
    WriteMember::new(b"b", b"", metadata=blank),
  ])
  for format in [Gnu, Bsd] {
    let preserved = parsed(writer_ok(builder.write(format~, metadata=Preserve)))
    assert_eq(preserved.get_member(0).unwrap().metadata, source)
    assert_eq(preserved.get_member(1).unwrap().metadata, blank)
    let normalized = parsed(writer_ok(builder.write(format~)))
    assert_eq(normalized.get_member(0).unwrap().metadata, {
      timestamp: Some(0L),
      uid: Some(0L),
      gid: Some(0L),
      mode: Some(420L),
    })
    assert_eq(
      normalized.get_member(0).unwrap().metadata,
      normalized.get_member(1).unwrap().metadata,
    )
  }
}

///|
test "writer rejects negative and overflowing numeric fields" {
  let base : Metadata = {
    timestamp: Some(0L),
    uid: Some(0L),
    gid: Some(0L),
    mode: Some(420L),
  }
  let empty = ArchiveBuilder::new()
  for
    metadata in [
      { ..base, timestamp: Some(-1L), },
      { ..base, timestamp: Some(1000000000000L), },
      { ..base, uid: Some(-1L), },
      { ..base, uid: Some(1000000L), },
      { ..base, gid: Some(-1L), },
      { ..base, gid: Some(1000000L), },
      { ..base, mode: Some(-1L), },
      { ..base, mode: Some(16777216L), },
    ] {
    assert_eq(
      writer_code(empty.append(WriteMember::new(b"a", b"", metadata~))),
      "WR002",
    )
  }
  let maximum : Metadata = {
    timestamp: Some(999999999999L),
    uid: Some(999999L),
    gid: Some(999999L),
    mode: Some(16777215L),
  }
  let builder = writer_plan([WriteMember::new(b"a", b"", metadata=maximum)])
  assert_eq(
    parsed(writer_ok(builder.write(metadata=Preserve))).get_member(0).unwrap().metadata,
    maximum,
  )
}

///|
test "writer layout budgets include physical records names and padding" {
  let builder = writer_plan([
    WriteMember::new(b"a_long_object_filename.o", b"odd"),
  ])
  for format in [Gnu, Bsd] {
    let bytes = writer_ok(builder.write(format~))
    let archive = parsed(bytes)
    let names = archive.records.fold(init=0, fn(total, entry) {
      total + entry.name.length()
    })
    assert_eq(
      writer_ok(
        builder.write(
          format~,
          max_bytes=bytes.length(),
          max_members=archive.member_count(),
          max_name_bytes=names,
        ),
      ),
      bytes,
    )
    assert_eq(
      writer_code(builder.write(format~, max_bytes=bytes.length() - 1)),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(format~, max_members=archive.member_count() - 1),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(builder.write(format~, max_name_bytes=names - 1)),
      "WR003",
    )
  }
  let empty = ArchiveBuilder::new()
  assert_eq(
    writer_ok(empty.write(max_bytes=8, max_members=0, max_name_bytes=0)),
    b"!<arch>\n",
  )
  assert_eq(writer_code(empty.write(max_bytes=7)), "WR003")
  assert_eq(writer_code(empty.write(max_bytes=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_members=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_name_bytes=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_symbols=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_symbol_name_bytes=-1)), "WR003")
  assert_eq(writer_ok(empty.write(max_bytes=2147483647)), b"!<arch>\n")
}

///|
test "writer refuses implicit symbol-index removal and rebuilds fresh targets" {
  let source = parsed(indexed_archive(b"entry"))
  assert_eq(writer_code(source.edit()), "WR004")
  let builder = writer_ok(source.edit(drop_symbol_indexes=true))
  assert_eq(builder.member_count(), 1)
  assert_eq(parsed(writer_ok(builder.write())).symbol_indexes(), [])
  let builder = writer_ok(
    builder.append(WriteMember::new(b"a_second_long_object_file.o", b"other")),
  )
  let builder = writer_ok(builder.move_member(1, 0))
  let symbols : Array[WriteSymbol] = [
    { name: b"new_symbol", member_index: 0, },
    { name: b"entry", member_index: 1, },
    { name: b"entry", member_index: 0, },
  ]
  let archive = parsed(writer_ok(builder.write(symbols=Some(symbols))))
  assert_eq(archive.symbol_indexes().length(), 1)
  let index = archive.symbol_indexes()[0]
  assert_eq(index.format, "gnu32")
  assert_eq(index.symbols.map(fn(symbol) { symbol.name }), [
    b"new_symbol", b"entry", b"entry",
  ])
  assert_eq(index.symbols.map(fn(symbol) { symbol.member_index }), [2, 3, 2])
  assert_eq(archive.member_bytes(2), Some(b"other"))
  assert_eq(archive.member_bytes(3), Some(b"payload"))
  // The caller's array is not retained by the builder for subsequent edits.
  symbols[0] = { name: b"changed", member_index: 0, }
  let removed = writer_ok(builder.remove(0))
  assert_eq(parsed(writer_ok(removed.write())).symbol_indexes(), [])
  assert_eq(writer_code(removed.write(symbols=Some(symbols))), "WR005")
}

///|
test "writer symbol names targets format and resource limits are checked" {
  let builder = writer_plan([WriteMember::new(b"a.o", b"data")])
  for
    symbol in [
      { name: b"", member_index: 0, },
      { name: b"a\x00b", member_index: 0, },
      { name: b"a", member_index: -1, },
      { name: b"a", member_index: 1, },
    ] {
    assert_eq(writer_code(builder.write(symbols=Some([symbol]))), "WR005")
  }
  let symbols : Array[WriteSymbol] = [{ name: b"x\xff", member_index: 0, }]
  let bytes = writer_ok(
    builder.write(symbols=Some(symbols), max_symbols=1, max_symbol_name_bytes=2),
  )
  let archive = parsed(bytes)
  assert_eq(archive.symbol_indexes()[0].symbols[0].name, b"x\xff")
  assert_eq(
    writer_code(builder.write(symbols=Some(symbols), max_symbols=0)),
    "WR003",
  )
  assert_eq(
    writer_code(builder.write(symbols=Some(symbols), max_symbol_name_bytes=1)),
    "WR003",
  )
  assert_eq(
    writer_code(
      builder.write(symbols=Some(symbols), max_bytes=bytes.length() - 1),
    ),
    "WR003",
  )
  assert_eq(
    writer_code(builder.write(symbols=Some(symbols), max_members=1)),
    "WR003",
  )
  assert_eq(
    writer_code(builder.write(symbols=Some(symbols), max_name_bytes=3)),
    "WR003",
  )
  assert_eq(
    parsed(writer_ok(builder.write(format=Bsd, symbols=Some(symbols)))).symbol_indexes()[0].symbols[0].name,
    b"x\xff",
  )
}

///|
test "writer empty index preserves presence with no members or symbols" {
  let empty = ArchiveBuilder::new()
  let bytes = writer_ok(
    empty.write(
      symbols=Some([]),
      max_members=1,
      max_name_bytes=1,
      max_symbols=0,
      max_symbol_name_bytes=0,
    ),
  )
  assert_eq(
    bytes,
    b"!<arch>\n" +
    @utf8.encode(
      field("/", 16) +
      field("", 12) +
      field("", 6) +
      field("", 6) +
      field("", 8) +
      field("4", 10) +
      "`\n",
    ) +
    b"\x00\x00\x00\x00",
  )
  let archive = parsed(bytes)
  assert_eq(archive.symbol_indexes()[0].symbols, [])
  assert_eq(writer_code(archive.edit()), "WR004")
}

///|
test "writer insertion targets gaps without changing the original plan" {
  let original = writer_plan([
    WriteMember::new(b"same", b"first"),
    WriteMember::new(b"same", b"last"),
  ])
  let inserted = writer_ok(
    original.insert(1, WriteMember::new(b"same", b"middle")),
  )
  let inserted = writer_ok(inserted.insert(0, WriteMember::new(b"head", b"0")))
  let inserted = writer_ok(inserted.insert(4, WriteMember::new(b"tail", b"4")))
  assert_eq(inserted.members().map(fn(entry) { entry.data }), [
    b"0", b"first", b"middle", b"last", b"4",
  ])
  assert_eq(original.member_count(), 2)
  for index in [-1, 3, 2147483647] {
    assert_eq(
      writer_code(original.insert(index, WriteMember::new(b"a", b""))),
      "WR001",
    )
  }
  assert_eq(
    writer_code(original.insert(1, WriteMember::new(b"\x00", b""))),
    "WR001",
  )
  assert_eq(
    writer_ok(ArchiveBuilder::new().insert(0, WriteMember::new(b"x", b""))).member_count(),
    1,
  )
}

///|
test "writer all symbol layouts retain names target order and byte order" {
  let builder = writer_plan([
    WriteMember::new(b"long_first_object_name.o", b"12345678"),
    WriteMember::new(b"same.o", b"abcdefg\n"),
    WriteMember::new(b"same.o", b""),
  ])
  let symbols : Array[WriteSymbol] = [
    { name: b"z", member_index: 1, },
    { name: b"entry", member_index: 0, },
    { name: b"z", member_index: 2, },
  ]
  for
    (format, bits, bsd) in [
      (Gnu, "32", false),
      (Gnu64, "64", false),
      (Bsd, "32", true),
      (Bsd64, "64", true),
      (Darwin, "32", true),
      (Darwin64, "64", true),
    ] {
    for little in [true, false] {
      let bytes = writer_ok(
        builder.write(
          format~,
          symbols=Some(symbols),
          index_little_endian=little,
        ),
      )
      let archive = parsed(bytes)
      let index = archive.symbol_indexes()[0]
      assert_eq(
        index.format,
        if bsd {
          "bsd\{bits}-\{if little { "le" } else { "be" }}"
        } else {
          "gnu\{bits}"
        },
      )
      assert_eq(index.symbols.map(fn(symbol) { symbol.name }), [
        b"z", b"entry", b"z",
      ])
      assert_eq(
        index.symbols.map(fn(symbol) {
          archive.member_bytes(symbol.member_index).unwrap()
        }),
        [b"abcdefg\n", b"12345678", b""],
      )
      let imported = writer_ok(archive.edit(drop_symbol_indexes=true))
      assert_eq(imported.members().map(fn(entry) { entry.name }), [
        b"long_first_object_name.o", b"same.o", b"same.o",
      ])
      if !bsd {
        assert_eq(
          bytes,
          writer_ok(
            builder.write(
              format~,
              symbols=Some(symbols),
              index_little_endian=!little,
            ),
          ),
        )
      }
    }
  }
}

///|
test "writer GNU64 emits 64 bit counts and full absolute header offsets" {
  let builder = writer_plan([WriteMember::new(b"a.o", b"xyz")])
  let bytes = writer_ok(
    builder.write(
      format=Gnu64,
      symbols=Some([{ name: b"f", member_index: 0, }]),
    ),
  )
  assert_eq(bytes[8:24].to_owned(), b"/SYM64/         ")
  // The index is 8-byte count, 8-byte target, then "f\0".
  // 8 + 60 + 18 = 86: the absolute ordinary header offset.
  assert_eq(
    bytes[68:86].to_owned(),
    b"\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x56f\x00",
  )
  assert_eq(parsed(bytes).get_member(1).unwrap().header_offset, 86)
}

///|
test "writer BSD ranlib field sizes and string offsets match the wire format" {
  let builder = writer_plan([WriteMember::new(b"a.o", b"xyz\n\n")])
  let symbols : Array[WriteSymbol] = [
    { name: b"f", member_index: 0, },
    { name: b"long", member_index: 0, },
  ]
  let bytes = writer_ok(builder.write(format=Bsd, symbols=Some(symbols)))
  assert_eq(bytes[8:24].to_owned(), b"#1/12           ")
  assert_eq(bytes[68:80].to_owned(), b"__.SYMDEF\x00\x00\x00")
  // Two ranlib32 entries occupy 16 bytes. The string table is 7 bytes.
  // A zero byte pads the index to 32 bytes; the first member header is 112.
  assert_eq(
    bytes[80:112].to_owned(),
    b"\x10\x00\x00\x00\x00\x00\x00\x00\x70\x00\x00\x00\x02\x00\x00\x00\x70\x00\x00\x00\x07\x00\x00\x00f\x00long\x00\x00",
  )
  let archive = parsed(bytes)
  assert_eq(archive.get_member(1).unwrap().header_offset, 112)
  assert_eq(archive.get_member(1).unwrap().data_offset, 176)
  assert_eq(archive.member_bytes(1), Some(b"xyz\n\n"))
  for format in [Bsd, Bsd64] {
    for little in [true, false] {
      let archive = parsed(
        writer_ok(
          builder.write(
            format~,
            symbols=Some(symbols),
            index_little_endian=little,
          ),
        ),
      )
      assert_eq(archive.member_bytes(1), Some(b"xyz\n\n"))
      assert_eq(archive.get_member(1).unwrap().data_offset % 8, 0)
    }
  }
}

///|
test "writer Darwin aligns declared data and retains original trailing newlines" {
  let entries = [
    WriteMember::new(b"same.o", b"x\n\n"),
    WriteMember::new(b"same.o", b"1234567\n"),
    WriteMember::new(b"last_long_member.o", b""),
  ]
  let builder = writer_plan(entries)
  for format in [Darwin, Darwin64] {
    let bytes = writer_ok(builder.write(format~))
    let archive = parsed(bytes)
    assert_eq(archive.symbol_indexes().length(), 1)
    assert_eq(archive.symbol_indexes()[0].symbols, [])
    assert_eq(archive.member_count(), 4)
    assert_eq(archive.member_bytes(1), Some(b"x\n\n\n\n\n\n\n"))
    assert_eq(archive.member_bytes(2), Some(b"1234567\n"))
    assert_eq(archive.member_bytes(3), Some(b""))
    assert_eq(archive.get_member(1).unwrap().metadata.timestamp, Some(0L))
    assert_eq(archive.get_member(2).unwrap().metadata.timestamp, Some(1L))
    for index = 0; index < archive.member_count(); index = index + 1 {
      let entry = archive.get_member(index).unwrap()
      assert_eq(entry.data_offset % 8, 0)
      assert_eq(entry.size % 8, 0)
    }
    let imported = writer_ok(archive.edit(drop_symbol_indexes=true))
    assert_eq(writer_ok(imported.write(format~)), bytes)
    let preserved = parsed(writer_ok(builder.write(format~, metadata=Preserve)))
    assert_eq(preserved.get_member(2).unwrap().metadata.timestamp, Some(0L))
  }
}

///|
test "writer indexed layouts enforce exact physical record name and byte budgets" {
  let builder = writer_plan([
    WriteMember::new(b"long_object_member.o", b"odd\n"),
    WriteMember::new(b"b", b""),
  ])
  let symbols : Array[WriteSymbol] = [
    { name: b"entry", member_index: 0, },
    { name: b"last", member_index: 1, },
  ]
  for format in [Gnu, Gnu64, Bsd, Bsd64, Darwin, Darwin64] {
    let bytes = writer_ok(builder.write(format~, symbols=Some(symbols)))
    let archive = parsed(bytes)
    let names = archive.records.fold(init=0, fn(total, entry) {
      total + entry.name.length()
    })
    assert_eq(
      writer_ok(
        builder.write(
          format~,
          symbols=Some(symbols),
          max_bytes=bytes.length(),
          max_members=archive.member_count(),
          max_name_bytes=names,
          max_symbols=2,
          max_symbol_name_bytes=9,
        ),
      ),
      bytes,
    )
    assert_eq(
      writer_code(
        builder.write(
          format~,
          symbols=Some(symbols),
          max_bytes=bytes.length() - 1,
        ),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(
          format~,
          symbols=Some(symbols),
          max_members=archive.member_count() - 1,
        ),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(format~, symbols=Some(symbols), max_name_bytes=names - 1),
      ),
      "WR003",
    )
  }
}
