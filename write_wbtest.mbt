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
test "writer rejects reserved empty and NUL member names" {
  let empty = ArchiveBuilder::new()
  for
    name in [
      b"", b"/", b"//", b"/SYM64/", b"__.SYMDEF", b"__.SYMDEF SORTED", b"__.SYMDEF_64",
      b"__.SYMDEF_64 SORTED", b"a\x00b",
    ] {
    assert_eq(writer_code(empty.append(WriteMember::new(name, b""))), "WR001")
  }
  assert_eq(empty.member_count(), 0)
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
    writer_code(builder.write(format=Bsd, symbols=Some(symbols))),
    "WR005",
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
