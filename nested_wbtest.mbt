///|
fn nested_thin(
  path : Bytes,
  offset : Int32,
  size : Int32,
  copies~ : Int32 = 1,
) -> ThinArchive raise {
  let entries = Array::make(
    copies,
    ThinWriteMember::new(path, size, archive_member_offset=Some(offset)),
  )
  thin_parsed(writer_ok(thin_writer_plan(entries).write()))
}

///|
test "nested GNU references resolve logical names and cache shared containers" {
  let contents = writer_ok(
    writer_plan([WriteMember::new(b"actual.o", b"abc")]).write(),
  )
  let archive = nested_thin(b"dir/base.a", 8, 3, copies=2)
  let calls : Array[(Bytes, Int32)] = []
  let loader = fn(path, limit) {
    calls.push((path, limit))
    Ok(contents)
  }
  let loaded = archive.materialize(loader).unwrap()
  assert_eq(loaded.members().map(e => (e.name, e.data)), [
    (b"actual.o", b"abc"),
    (b"actual.o", b"abc"),
  ])
  assert_eq(calls, [(b"dir/base.a", 67108864)])
  assert_eq(archive.get_member(1).unwrap().archive_member_offset, Some(8))
  let rewritten = writer_ok(writer_ok(archive.edit()).write())
  assert_eq(
    thin_parsed(rewritten).get_member(2).unwrap().archive_member_offset,
    Some(8),
  )
  let ordinary = parsed(writer_ok(loaded.write()))
  assert_true(
    archive.snapshot(loader).unwrap().compare_logical(ordinary.snapshot()).content_equal,
  )
  assert_eq(archive.resolve_member(1, loader).unwrap().name, b"actual.o")
}

///|
test "nested resolution checks exact targets sizes and aggregate budgets" {
  let data = writer_ok(
    writer_plan([WriteMember::new(b"actual.o", b"abc")]).write(),
  )
  let loader = (_, _) => Ok(data)
  for offset in [10, 68, 70, 1000] {
    assert_true(
      nested_thin(b"base.a", offset, 3).materialize(loader)
      is Err({ code: "AR015", .. }),
    )
  }
  let root = nested_thin(b"base.a", 8, 2)
  assert_true(
    root.materialize(loader) is Err({ code: "AR014", offset: 76, .. }),
  )
  let root = nested_thin(b"base.a", 8, 3)
  assert_true(
    root.materialize(
      loader,
      nested_limits=NestedLimits::new(max_bytes=data.length() - 1),
    )
    is Err({ code: "AR008", .. }),
  )
  assert_true(
    root.materialize(loader, nested_limits=NestedLimits::new(max_members=0))
    is Err({ code: "AR008", .. }),
  )
  assert_true(
    root.materialize(loader, nested_limits=NestedLimits::new(max_name_bytes=5))
    is Err({ code: "AR008", .. }),
  )
  assert_true(
    root.materialize((_, _) => Err("unavailable")) is Err({ code: "AR013", .. }),
  )
  let calls : Array[Int32] = []
  let counting = fn(_, _) {
    calls.push(1)
    Ok(data)
  }
  assert_true(
    root.materialize(counting, max_bytes=2) is Err({ code: "AR008", .. }),
  )
  assert_true(
    root.materialize(counting, nested_limits=NestedLimits::new(max_depth=65))
    is Err({ code: "AR008", .. }),
  )
  assert_eq(calls.length(), 0)
  let indexed = writer_ok(
    writer_plan([WriteMember::new(b"actual.o", b"abc")]).write(
      symbols=Some([{ name: b"z", member_index: 0, }]),
    ),
  )
  assert_true(
    nested_thin(b"base.a", 8, 3).materialize((_, _) => Ok(indexed))
    is Err({ code: "AR015", .. }),
  )
}

///|
test "nested thin chains keep directory context and metadata without loading manifest payloads" {
  let outer = nested_thin(b"dir/inner.a", 8, 3)
  let inner = b"!<thin>\n" + thin_header("leaf.o/", 3)
  let calls : Array[Bytes] = []
  let loader = fn(path, _) {
    calls.push(path)
    if path == b"dir/inner.a" {
      Ok(inner)
    } else if path == b"dir/leaf.o" {
      Ok(b"abc")
    } else {
      Err("wrong directory")
    }
  }
  assert_eq(outer.member_sources(loader), Ok([b"dir/inner.a", b"dir/leaf.o"]))
  assert_eq(calls, [b"dir/inner.a"])
  calls.clear()
  let actual = outer.resolve_member(1, loader).unwrap()
  assert_eq(actual.name, b"leaf.o")
  assert_eq(actual.data, b"abc")
  assert_eq(actual.metadata, outer.get_member(1).unwrap().metadata)
  assert_eq(calls, [b"dir/inner.a", b"dir/leaf.o"])
  assert_true(
    outer.materialize(loader, nested_limits=NestedLimits::new(max_depth=0))
    is Err({ code: "AR008", .. }),
  )
}

///|
test "repeated nested paths consume the exact name budget only once" {
  let outer = nested_thin(b"dir/inner.a", 8, 3, copies=2)
  let inner = b"!<thin>\n" + thin_header("leaf.o/", 3)
  let calls : Array[Bytes] = []
  let loader = fn(path, _) {
    calls.push(path)
    if path == b"dir/inner.a" {
      Ok(inner)
    } else if path == b"dir/leaf.o" {
      Ok(b"abc")
    } else {
      Err("unexpected dependency")
    }
  }
  // Source paths (11 + 10 bytes) plus the parsed container name (6 bytes).
  let limits = NestedLimits::new(max_name_bytes=27)
  assert_eq(outer.validate_members(loader, nested_limits=limits), Ok(6))
  assert_eq(calls, [b"dir/inner.a", b"dir/leaf.o", b"dir/leaf.o"])
  calls.clear()
  assert_eq(
    outer.member_sources(loader, nested_limits=limits),
    Ok([b"dir/inner.a", b"dir/leaf.o"]),
  )
  assert_eq(calls, [b"dir/inner.a"])
  let packed = outer.materialize(loader, nested_limits=limits).unwrap()
  assert_eq(packed.members().map(e => (e.name, e.data)), [
    (b"leaf.o", b"abc"),
    (b"leaf.o", b"abc"),
  ])
  let ordinary = parsed(writer_ok(packed.write()))
  assert_true(
    outer
    .snapshot(loader, nested_limits=limits)
    .unwrap()
    .compare_logical(ordinary.snapshot()).content_equal,
  )
  calls.clear()
  assert_true(
    outer.validate_members(
      loader,
      nested_limits=NestedLimits::new(max_name_bytes=26),
    )
    is Err({ code: "AR008", .. }),
  )
  assert_eq(calls, [b"dir/inner.a"])
}

///|
test "a new nested path still fails before its loader when the shared budget is exhausted" {
  let outer = thin_parsed(
    writer_ok(
      thin_writer_plan([
        ThinWriteMember::new(b"dir/inner.a", 3, archive_member_offset=Some(8)),
        ThinWriteMember::new(b"dir/inner.a", 3, archive_member_offset=Some(68)),
      ]).write(),
    ),
  )
  let inner = b"!<thin>\n" +
    thin_header("leaf.o/", 3) +
    thin_header("other.o/", 3)
  let calls : Array[Bytes] = []
  let result = outer.validate_members(
    fn(path, _) {
      calls.push(path)
      if path == b"dir/inner.a" {
        Ok(inner)
      } else {
        Ok(b"abc")
      }
    },
    // 11-byte container path, 13 bytes of parsed names, first 10-byte leaf path.
    nested_limits=NestedLimits::new(max_name_bytes=34),
  )
  assert_true(result is Err({ code: "AR008", .. }))
  assert_eq(calls, [b"dir/inner.a", b"dir/leaf.o"])
}

///|
test "nested cycles depth limits invalid paths and nested parse offsets stay bounded" {
  let cycle = nested_thin(b"cycle.a", 78, 3)
  let bytes = writer_ok(writer_ok(cycle.edit()).write())
  let root = nested_thin(b"cycle.a", 78, 3)
  assert_true(
    root.materialize((_, _) => Ok(bytes)) is Err({ code: "AR015", .. }),
  )
  assert_true(
    nested_thin(b"root.a", 78, 3).materialize(
      (_, _) => Ok(bytes),
      nested_limits=NestedLimits::new(max_depth=1),
    )
    is Err({ code: "AR008", .. }),
  )
  let bad_path = b"!<thin>\n" + thin_header("../escape/", 3)
  assert_true(
    nested_thin(b"inner.a", 8, 3).materialize((_, _) => Ok(bad_path))
    is Err({ code: "AR012", .. }),
  )
  assert_true(
    root.materialize((_, _) => Ok(b"invalid!")) is Err({ code: "AR001", .. }),
  )
}

///|
test "archive-offset encodings reject malformed and unrepresentable references" {
  for name in ["/0:", "/:8", "/0:7", "/0:9", "/0:-8", "/0:8:8", "/0:2147483648"] {
    assert_true(
      parse_thin(
        b"!<thin>\n" + record("//", b"base.a/\n") + thin_header(name, 3),
      )
      is Err(_),
    )
  }
  assert_true(
    ThinArchiveBuilder::from_members([
      ThinWriteMember::new(b"a", 0, archive_member_offset=Some(9)),
    ])
    is Err({ code: "WR001", .. }),
  )
  let plan = thin_writer_plan([
    ThinWriteMember::new(b"a", 0, archive_member_offset=Some(2147483646)),
  ])
  assert_eq(
    thin_parsed(writer_ok(plan.write())).get_member(1).unwrap().archive_member_offset,
    Some(2147483646),
  )
  let wide = thin_writer_plan([
    ThinWriteMember::new(Bytes::make(10000, b'a'), 0),
    ThinWriteMember::new(b"b", 0, archive_member_offset=Some(2147483646)),
  ])
  assert_true(wide.write() is Err({ code: "WR001", .. }))
}

///|
test "nested container truncations and mutated thin headers cannot escape parser checks" {
  let data = writer_ok(
    writer_plan([WriteMember::new(b"actual.o", b"abc")]).write(),
  )
  let archive = nested_thin(b"base.a", 8, 3)
  for end in 0..<data.length() {
    assert_true(
      archive.materialize((_, _) => Ok(data[:end].to_owned())) is Err(_),
    )
  }
  let input = writer_ok(writer_ok(archive.edit()).write())
  for i in 0..<input.length() {
    let mutated = Bytes::makei(input.length(), fn(j) {
      if i == j {
        b'\xff'
      } else {
        input[j]
      }
    })
    if parse_thin(mutated) is Ok(thin) {
      ignore(thin.materialize((_, _) => Ok(data)))
    }
  }
}
