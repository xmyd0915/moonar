///|
fn thin_writer_plan(
  entries : Array[ThinWriteMember],
) -> ThinArchiveBuilder raise {
  writer_ok(ThinArchiveBuilder::from_members(entries))
}

///|
test "thin writer stores external sizes without payloads or external padding" {
  let entries = [
    ThinWriteMember::new(b"objects/a.o", 3),
    ThinWriteMember::new(b"../objects/b.o", 2147483647),
    ThinWriteMember::new(b"objects/a.o", 0),
    ThinWriteMember::new(b"__.SYMDEF", 2),
  ]
  let builder = thin_writer_plan(entries)
  let bytes = writer_ok(builder.write())
  let archive = thin_parsed(bytes)
  assert_eq(archive.member_count(), 5)
  assert_eq(
    archive.inline_bytes(0),
    Some(b"objects/a.o/\n../objects/b.o/\n__.SYMDEF/\n"),
  )
  assert_eq(archive.get_member(2).unwrap().size, 2147483647)
  assert_eq(
    archive.get_member(2).unwrap().header_offset -
    archive.get_member(1).unwrap().header_offset,
    60,
  )
  assert_eq(writer_ok(archive.edit()).members(), entries)
  assert_eq(writer_ok(builder.write()), bytes)
  assert_eq(writer_ok(ThinArchiveBuilder::new().write()), b"!<thin>\n")
}

///|
test "thin writer exact-position edits isolate arrays and preserve duplicates" {
  let entries = [
    ThinWriteMember::new(b"same.o", 1),
    ThinWriteMember::new(b"same.o", 2),
    ThinWriteMember::new(b"last.o", 3),
  ]
  let original = thin_writer_plan(entries)
  entries[0] = ThinWriteMember::new(b"changed.o", 9)
  let changed = writer_ok(
    original.insert(1, ThinWriteMember::new(b"same.o", 4)),
  )
  let changed = writer_ok(
    changed.replace(2, ThinWriteMember::new(b"same.o", 5)),
  )
  let changed = writer_ok(changed.remove(0))
  let changed = writer_ok(changed.move_member(2, 0))
  let changed = writer_ok(changed.append(ThinWriteMember::new(b"tail.o", 6)))
  assert_eq(changed.members().map(entry => entry.size), [3, 4, 5, 6])
  assert_eq(original.members().map(entry => entry.size), [1, 2, 3])
  let exposed = changed.members()
  exposed.clear()
  assert_eq(changed.member_count(), 4)
  for invalid in [-1, 3, 2147483647] {
    assert_eq(writer_code(original.remove(invalid)), "WR001")
    assert_eq(
      writer_code(original.replace(invalid, ThinWriteMember::new(b"a", 1))),
      "WR001",
    )
    assert_eq(writer_code(original.move_member(invalid, 0)), "WR001")
    assert_eq(writer_code(original.move_member(0, invalid)), "WR001")
  }
  assert_eq(
    writer_code(original.insert(-1, ThinWriteMember::new(b"a", 1))),
    "WR001",
  )
  assert_eq(
    writer_code(original.insert(4, ThinWriteMember::new(b"a", 1))),
    "WR001",
  )
  assert_eq(
    writer_ok(original.insert(3, ThinWriteMember::new(b"a", 4))).member_count(),
    4,
  )
  assert_eq(
    writer_ok(original.move_member(0, 2)).members().map(entry => entry.size),
    [2, 3, 1],
  )
  assert_eq(writer_ok(original.move_member(1, 1)).members(), original.members())
}

///|
test "thin writer validates relative file paths sizes and metadata" {
  let empty = ThinArchiveBuilder::new()
  for
    path in [
      b"", b"/absolute", b"C:/file", b"\\root", b"a\\b", b"file:stream", b"a\x00b",
      b"line\nbreak", b"dir/", b"./", b"dir/.", b"..", b"a/..",
    ] {
    assert_eq(writer_code(empty.append(ThinWriteMember::new(path, 1))), "WR001")
  }
  assert_eq(writer_code(empty.append(ThinWriteMember::new(b"a", -1))), "WR001")
  assert_eq(
    writer_code(
      empty.append(
        ThinWriteMember::new(b"a", 1, metadata={
          timestamp: Some(-1L),
          uid: None,
          gid: None,
          mode: None,
        }),
      ),
    ),
    "WR002",
  )
  assert_eq(empty.member_count(), 0)
  let builder = thin_writer_plan([ThinWriteMember::new(b"../elsewhere/a.o", 1)])
  assert_eq(
    thin_parsed(writer_ok(builder.write())).get_member(1).unwrap().name,
    b"../elsewhere/a.o",
  )
}

///|
test "thin writer 32 and 64 bit symbol indexes target final edited headers" {
  let builder = thin_writer_plan([
    ThinWriteMember::new(b"objects/first.o", 3),
    ThinWriteMember::new(b"objects/second.o", 9),
  ])
  let builder = writer_ok(builder.move_member(1, 0))
  let symbols : Array[WriteSymbol] = [
    { name: b"shared", member_index: 1, },
    { name: b"entry", member_index: 0, },
    { name: b"shared", member_index: 0, },
  ]
  for symbol_width in [32, 64] {
    let bytes = writer_ok(builder.write(symbols=Some(symbols), symbol_width~))
    let archive = thin_parsed(bytes)
    let index = archive.symbol_indexes()[0]
    assert_eq(index.format, if symbol_width == 32 { "gnu32" } else { "gnu64" })
    assert_eq(index.symbols.map(symbol => symbol.name), [
      b"shared", b"entry", b"shared",
    ])
    assert_eq(index.symbols.map(symbol => symbol.member_index), [3, 2, 2])
    assert_eq(archive.get_member(2).unwrap().name, b"objects/second.o")
    assert_eq(archive.get_member(3).unwrap().name, b"objects/first.o")
    assert_eq(writer_code(archive.edit()), "WR004")
    let edited = writer_ok(archive.edit(drop_symbol_indexes=true))
    assert_eq(edited.members(), builder.members())
    assert_eq(thin_parsed(writer_ok(edited.write())).symbol_indexes(), [])
  }
}

///|
test "thin writer validates index requests and permits explicit empty indexes" {
  let builder = thin_writer_plan([ThinWriteMember::new(b"a.o", 1)])
  for
    symbol in [
      { name: b"", member_index: 0, },
      { name: b"a\x00b", member_index: 0, },
      { name: b"x", member_index: -1, },
      { name: b"x", member_index: 1, },
    ] {
    assert_eq(writer_code(builder.write(symbols=Some([symbol]))), "WR005")
  }
  assert_eq(writer_code(builder.write(symbol_width=16)), "WR005")
  for symbol_width in [32, 64] {
    let bytes = writer_ok(
      ThinArchiveBuilder::new().write(symbols=Some([]), symbol_width~),
    )
    let archive = thin_parsed(bytes)
    assert_eq(archive.member_count(), 1)
    assert_eq(archive.symbol_indexes()[0].symbols, [])
  }
}

///|
test "thin writer budgets count physical names indexes padding and headers" {
  let builder = thin_writer_plan([
    ThinWriteMember::new(b"objects/odd.o", 2147483647),
    ThinWriteMember::new(b"objects/odd.o", 2147483647),
  ])
  let symbols : Array[WriteSymbol] = [{ name: b"entry", member_index: 1, }]
  for symbol_width in [32, 64] {
    let bytes = writer_ok(builder.write(symbols=Some(symbols), symbol_width~))
    let archive = thin_parsed(bytes)
    let mut names = 0
    for entry in archive.archive.records {
      names += entry.name.length()
    }
    assert_eq(
      writer_ok(
        builder.write(
          symbols=Some(symbols),
          symbol_width~,
          max_bytes=bytes.length(),
          max_members=4,
          max_name_bytes=names,
          max_symbols=1,
          max_symbol_name_bytes=5,
        ),
      ),
      bytes,
    )
    assert_eq(
      writer_code(
        builder.write(
          symbols=Some(symbols),
          symbol_width~,
          max_bytes=bytes.length() - 1,
        ),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(symbols=Some(symbols), symbol_width~, max_members=3),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(
          symbols=Some(symbols),
          symbol_width~,
          max_name_bytes=names - 1,
        ),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(symbols=Some(symbols), symbol_width~, max_symbols=0),
      ),
      "WR003",
    )
    assert_eq(
      writer_code(
        builder.write(
          symbols=Some(symbols),
          symbol_width~,
          max_symbol_name_bytes=4,
        ),
      ),
      "WR003",
    )
  }
  let empty = ThinArchiveBuilder::new()
  assert_eq(
    writer_ok(empty.write(max_bytes=8, max_members=0, max_name_bytes=0)),
    b"!<thin>\n",
  )
  assert_eq(writer_code(empty.write(max_bytes=7)), "WR003")
  assert_eq(writer_code(empty.write(max_bytes=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_members=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_name_bytes=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_symbols=-1)), "WR003")
  assert_eq(writer_code(empty.write(max_symbol_name_bytes=-1)), "WR003")
}

///|
test "thin writer metadata preservation and deterministic output" {
  let metadata : Metadata = {
    timestamp: Some(987654321L),
    uid: Some(123L),
    gid: Some(456L),
    mode: Some(33261L),
  }
  let blank : Metadata = { timestamp: None, uid: None, gid: None, mode: None, }
  let builder = thin_writer_plan([
    ThinWriteMember::new(b"first.o", 1, metadata~),
    ThinWriteMember::new(b"second.o", 2, metadata=blank),
  ])
  let preserved = thin_parsed(writer_ok(builder.write(metadata=Preserve)))
  assert_eq(preserved.get_member(1).unwrap().metadata, metadata)
  assert_eq(preserved.get_member(2).unwrap().metadata, blank)
  let deterministic = thin_parsed(writer_ok(builder.write()))
  assert_eq(deterministic.get_member(1).unwrap().metadata, {
    timestamp: Some(0L),
    uid: Some(0L),
    gid: Some(0L),
    mode: Some(420L),
  })
  assert_eq(
    deterministic.get_member(1).unwrap().metadata,
    deterministic.get_member(2).unwrap().metadata,
  )
}

///|
test "thin parent-path policy is explicit and preserves traversal semantics" {
  let archive = thin_with_path(b"./../objects//a.o")
  assert_true(archive.member_path(1) is Err({ code: "AR012", .. }))
  assert_eq(
    archive.member_path(1, allow_parent_paths=true),
    Ok(b"../objects/a.o"),
  )
  let calls : Array[Bytes] = []
  assert_eq(
    archive.load_member(
      1,
      fn(path, _) {
        calls.push(path)
        Ok(b"abc")
      },
      allow_parent_paths=true,
    ),
    Ok(b"abc"),
  )
  assert_eq(calls, [b"../objects/a.o"])
  let path = thin_with_path(b"link/../a.o").member_path(
    1,
    allow_parent_paths=true,
  )
  assert_eq(path, Ok(b"link/../a.o"))
  for path in [b"../", b"../..", b"a/..", b"/a.o", b"C:/a.o"] {
    assert_true(
      thin_with_path(path).member_path(1, allow_parent_paths=true)
      is Err({ code: "AR012", .. }),
    )
  }
}

///|
test "thin materialization preserves payload order names and metadata" {
  let metadata : Metadata = {
    timestamp: Some(123L),
    uid: Some(4L),
    gid: Some(5L),
    mode: Some(420L),
  }
  let builder = thin_writer_plan([
    ThinWriteMember::new(b"dir/a.o", 3, metadata~),
    ThinWriteMember::new(b"../b.o", 2, metadata~),
    ThinWriteMember::new(b"dir/a.o", 3, metadata~),
  ])
  let archive = thin_parsed(writer_ok(builder.write(metadata=Preserve)))
  let calls : Array[(Bytes, Int32)] = []
  let materialized = match
    archive.materialize(
      fn(path, limit) {
        calls.push((path, limit))
        Ok(if path == b"dir/a.o" { b"abc" } else { b"de" })
      },
      allow_parent_paths=true,
      max_bytes=8,
    ) {
    Ok(builder) => builder
    Err(error) => fail("\{error.code}: \{error.message}")
  }
  assert_eq(calls, [(b"dir/a.o", 3), (b"../b.o", 2), (b"dir/a.o", 3)])
  assert_eq(materialized.members(), [
    WriteMember::new(b"dir/a.o", b"abc", metadata~),
    WriteMember::new(b"../b.o", b"de", metadata~),
    WriteMember::new(b"dir/a.o", b"abc", metadata~),
  ])
  let regular = parsed(writer_ok(materialized.write(metadata=Preserve)))
  assert_eq(writer_ok(regular.edit()).members(), materialized.members())
}

///|
test "thin materialization preflights all declarations and reports loader errors" {
  let calls : Array[Unit] = []
  let loader = fn(_path : Bytes, _size : Int32) -> Result[Bytes, String] {
    calls.push(())
    Ok(b"abc")
  }
  let archive = thin_parsed(
    writer_ok(
      thin_writer_plan([
        ThinWriteMember::new(b"a.o", 3),
        ThinWriteMember::new(b"b.o", 4),
      ]).write(),
    ),
  )
  assert_true(
    archive.materialize(loader, max_bytes=6) is Err({ code: "AR008", .. }),
  )
  assert_true(
    archive.materialize(loader, max_bytes=-1) is Err({ code: "AR008", .. }),
  )
  let unsafe_archive = thin_parsed(
    writer_ok(
      thin_writer_plan([
        ThinWriteMember::new(b"a.o", 3),
        ThinWriteMember::new(b"../b.o", 3),
      ]).write(),
    ),
  )
  assert_true(unsafe_archive.materialize(loader) is Err({ code: "AR012", .. }))
  assert_eq(calls.length(), 0)
  let special_spelling = thin_with_path(b"__.SYMDEF")
  let materialized = match special_spelling.materialize((_, _) => Ok(b"abc")) {
    Ok(builder) => builder
    Err(error) => fail("\{error.code}: \{error.message}")
  }
  let regular = parsed(writer_ok(materialized.write()))
  assert_eq(regular.get_member(1).unwrap().name, b"__.SYMDEF")
  assert_eq(regular.get_member(1).unwrap().kind, Regular)
  assert_eq(regular.member_bytes(1), Some(b"abc"))
  assert_eq(regular.symbol_indexes(), [])
  let single = thin_with_path(b"a.o")
  assert_true(
    single.materialize((_, _) => Err("missing")) is Err({ code: "AR013", .. }),
  )
  assert_true(
    single.materialize((_, _) => Ok(b"ab")) is Err({ code: "AR014", .. }),
  )
  assert_true(
    single.materialize((_, _) => Ok(b"abcd")) is Err({ code: "AR014", .. }),
  )
  let indexed = thin_parsed(thin_indexed(4))
  assert_true(indexed.materialize(loader) is Err({ code: "AR011", .. }))
  assert_eq(calls.length(), 0)
  let loaded = indexed.materialize(
    (_, _) => Ok(Bytes::make(17, b'x')),
    drop_symbol_indexes=true,
  )
  assert_true(loaded is Ok(_))
}
