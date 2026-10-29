///|
fn snapshot_thin(
  entries : Array[ThinWriteMember],
  symbols~ : Array[WriteSymbol]? = None,
  width~ : Int32 = 32,
  metadata~ : WriteMetadata = Deterministic,
) -> ThinArchive raise {
  thin_parsed(
    writer_ok(
      thin_writer_plan(entries).write(symbols~, symbol_width=width, metadata~),
    ),
  )
}

///|
fn snapshot_ok(
  value : Result[ArchiveSnapshot, ParseError],
) -> ArchiveSnapshot raise {
  match value {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
}

///|
test "thin snapshots detect changed contents with identical container bytes" {
  let archive = snapshot_thin(
    [ThinWriteMember::new(b"a.o", 3)],
    symbols=Some([{ name: b"entry", member_index: 0, }]),
  )
  let before = snapshot_ok(archive.snapshot((_, _) => Ok(b"abc")))
  let after = snapshot_ok(archive.snapshot((_, _) => Ok(b"xyz")))
  let result = before.compare_logical(after)
  assert_true(result.bytes_equal)
  assert_false(result.content_equal)
  assert_true(result.symbols_equal)
  assert_false(result.symbol_index_presence_changed)
  assert_eq(result.changes.length(), 1)
  assert_true(result.changes[0].payload_changed)
  assert_eq(result.changes[0].before_index, Some(2))
  assert_eq(result.changes[0].after_index, Some(2))
  assert_eq(archive.inline_bytes(2), None)
}

///|
test "thin and ordinary snapshots compare contents and retained symbol mappings" {
  for width in [32, 64] {
    let thin = snapshot_thin(
      [ThinWriteMember::new(b"long_member_name.o", 3)],
      width~,
      symbols=Some([{ name: b"entry", member_index: 0, }]),
    )
    let ordinary = parsed(
      writer_ok(
        writer_plan([WriteMember::new(b"long_member_name.o", b"abc")]).write(
          format=Bsd64,
          symbols=Some([{ name: b"entry", member_index: 0, }]),
        ),
      ),
    )
    let result = snapshot_ok(thin.snapshot((_, _) => Ok(b"abc"))).compare_logical(
      ordinary.snapshot(),
    )
    assert_false(result.bytes_equal)
    assert_true(result.content_equal && result.symbols_equal)
    assert_false(
      result.metadata_changed ||
      result.order_changed ||
      result.symbol_index_presence_changed,
    )
    assert_eq(result.changes, [])
    let missing_index = snapshot_thin([
      ThinWriteMember::new(b"long_member_name.o", 3),
    ])
    let without = snapshot_ok(missing_index.snapshot((_, _) => Ok(b"abc")))
    let result = without.compare_logical(ordinary.snapshot())
    assert_true(result.symbol_index_presence_changed)
    assert_false(result.symbols_equal)
  }
}

///|
test "snapshots retain bytes after loading and preserve original ambiguity indices" {
  let archive = snapshot_thin([
    ThinWriteMember::new(b"same", 3),
    ThinWriteMember::new(b"same", 3),
  ])
  let calls : Array[Bytes] = []
  let snapshot = snapshot_ok(
    archive.snapshot(fn(path, size) {
      calls.push(path)
      assert_true(size == 3) catch {
        _ => return Err("bad declared size")
      }
      Ok(b"abc")
    }),
  )
  let other = snapshot_thin(
    [ThinWriteMember::new(b"same", 3), ThinWriteMember::new(b"same", 3)],
    symbols=Some([]),
  )
  let result = snapshot.compare_logical(
    snapshot_ok(other.snapshot((_, _) => Ok(b"abc"))),
  )
  assert_true(result.content_equal)
  assert_true(result.symbol_index_presence_changed)
  assert_eq(result.ambiguities[0].before_indices, [1, 2])
  assert_eq(result.ambiguities[0].after_indices, [2, 3])
  ignore(snapshot.compare_logical(snapshot))
  assert_eq(calls, [b"same", b"same"])
}

///|
test "snapshot and validation preflight all paths and cumulative budgets before I/O" {
  let calls : Array[Bytes] = []
  let loader = fn(path, _) {
    calls.push(path)
    Ok(b"abc")
  }
  let bad = snapshot_thin([
    ThinWriteMember::new(b"safe", 3),
    ThinWriteMember::new(b"../escape", 3),
  ])
  assert_true(bad.snapshot(loader) is Err({ code: "AR012", .. }))
  assert_true(bad.validate_members(loader) is Err({ code: "AR012", .. }))
  assert_eq(calls, [])
  let repeated = snapshot_thin([
    ThinWriteMember::new(b"same", 3),
    ThinWriteMember::new(b"same", 3),
  ])
  assert_true(
    repeated.snapshot(loader, max_bytes=5) is Err({ code: "AR008", .. }),
  )
  assert_true(
    repeated.validate_members(loader, max_bytes=5) is Err({ code: "AR008", .. }),
  )
  assert_true(
    repeated.snapshot(loader, max_bytes=-1) is Err({ code: "AR008", .. }),
  )
  assert_true(
    repeated.validate_members(loader, max_bytes=-1)
    is Err({ code: "AR008", .. }),
  )
  assert_eq(calls, [])
  assert_eq(repeated.validate_members(loader, max_bytes=6), Ok(6))
  assert_eq(calls, [b"same", b"same"])
  assert_true(bad.snapshot(loader, allow_parent_paths=true) is Ok(_))
}

///|
test "external validation and snapshot errors retain original member offsets" {
  let archive = snapshot_thin([ThinWriteMember::new(b"a.o", 3)])
  let offset = archive.get_member(1).unwrap().header_offset
  for validate in [false, true] {
    let failure = if validate {
      archive.validate_members((_, _) => Err("missing")).map(_ => ())
    } else {
      archive.snapshot((_, _) => Err("missing")).map(_ => ())
    }
    assert_true(
      failure is Err({ code: "AR013", offset: found, .. }) && found == offset,
    )
    let failure = if validate {
      archive.validate_members((_, _) => Ok(b"four")).map(_ => ())
    } else {
      archive.snapshot((_, _) => Ok(b"four")).map(_ => ())
    }
    assert_true(
      failure is Err({ code: "AR014", offset: found, .. }) && found == offset,
    )
  }
  let empty = thin_parsed(b"!<thin>\n")
  assert_eq(
    empty.validate_members((_, _) => Err("must not load"), max_bytes=0),
    Ok(0),
  )
  let snapshot = snapshot_ok(
    empty.snapshot((_, _) => Err("must not load"), max_bytes=0),
  )
  assert_true(
    snapshot.compare_logical(parsed(b"!<arch>\n").snapshot()).content_equal,
  )
}

///|
test "snapshots preserve binary path identities and ordinary comparison semantics" {
  let archive = snapshot_thin([ThinWriteMember::new(b"raw\xff.o", 3)])
  let snapshot = snapshot_ok(
    archive.snapshot(fn(path, _) {
      if path == b"raw\xff.o" {
        Ok(b"abc")
      } else {
        Err("wrong bytes")
      }
    }),
  )
  let ordinary = parsed(
    writer_ok(writer_plan([WriteMember::new(b"raw\xff.o", b"abc")]).write()),
  )
  assert_true(snapshot.compare_logical(ordinary.snapshot()).content_equal)
  assert_eq(
    ordinary.snapshot().compare_logical(ordinary.snapshot()),
    compare_logical(ordinary, ordinary),
  )
}

///|
test "snapshot comparison preserves original target changes order and metadata" {
  let a = ThinWriteMember::new(b"a", 3)
  let b = ThinWriteMember::new(b"b", 3)
  let loader = fn(path, _) { Ok(if path == b"a" { b"aaa" } else { b"bbb" }) }
  let before = snapshot_ok(
    snapshot_thin([a, b], symbols=Some([{ name: b"entry", member_index: 0, }])).snapshot(
      loader,
    ),
  )
  let retargeted = snapshot_ok(
    snapshot_thin([a, b], symbols=Some([{ name: b"entry", member_index: 1, }])).snapshot(
      loader,
    ),
  )
  let result = before.compare_logical(retargeted)
  assert_true(result.content_equal)
  assert_false(result.symbols_equal)
  assert_eq(result.changes, [])
  let moved = snapshot_ok(
    snapshot_thin([b, a], symbols=Some([{ name: b"entry", member_index: 1, }])).snapshot(
      loader,
    ),
  )
  let result = before.compare_logical(moved)
  assert_true(
    result.order_changed && result.symbols_equal && result.content_equal,
  )
  let later = { ..a, metadata: { ..a.metadata, timestamp: Some(7L), }, }
  let metadata = snapshot_ok(
    snapshot_thin(
      [later, b],
      metadata=Preserve,
      symbols=Some([{ name: b"entry", member_index: 0, }]),
    ).snapshot(loader),
  )
  let result = before.compare_logical(metadata)
  assert_true(
    result.content_equal && result.metadata_changed && result.symbols_equal,
  )
  assert_eq(result.changes[0].before_index, Some(2))
}
