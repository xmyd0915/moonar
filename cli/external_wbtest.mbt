///|
fn query_thin(entries : Array[@ar.ThinWriteMember]) -> Bytes {
  @ar.ThinArchiveBuilder::from_members(entries).unwrap().write().unwrap()
}

///|
test "thin check external loads actual bytes while metadata check stays independent" {
  let bytes = query_thin([@ar.ThinWriteMember::new(b"a.o", 3)])
  let reads : Array[String] = []
  let read = fn(path) {
    reads.push(path)
    if path == "build/lib.a" {
      Ok(bytes)
    } else {
      Err("missing external file")
    }
  }
  assert_eq(run(request(["check", "build/lib.a"]), read).exit_code, 0)
  assert_eq(reads, ["build/lib.a"])
  reads.clear()
  let failure = run(
    request(["check", "build/lib.a", "--external", "--json"]),
    read,
  )
  assert_eq(failure.exit_code, 1)
  assert_true(
    @json.parse(failure.stdout)
    is {
      "input": String("build/lib.a"),
      "error": { "code": String("AR013"), "offset": Number(_, ..), .. },
      ..
    },
  )
  assert_eq(reads, ["build/lib.a", "build/a.o"])
  let success = run(request(["check", "build/lib.a", "--external", "--json"]), fn(
    path,
  ) {
    if path == "build/lib.a" {
      Ok(bytes)
    } else {
      Ok(b"abc")
    }
  })
  assert_eq(success.exit_code, 0)
  assert_true(
    @json.parse(success.stdout)
    is {
      "format": String("thin"),
      "external_checked": True,
      "external_byte_length": Number(3, ..),
      ..
    },
  )
}

///|
test "thin external validation preflights paths and cumulative size without reading payloads" {
  let files : Map[String, Bytes] = {
    "bad.a": query_thin([
      @ar.ThinWriteMember::new(b"safe", 3),
      @ar.ThinWriteMember::new(b"../outside", 3),
    ]),
    "big.a": query_thin([
      @ar.ThinWriteMember::new(b"a", 200),
      @ar.ThinWriteMember::new(b"b", 200),
    ]),
  }
  let calls : Array[String] = []
  let read = fn(path) {
    calls.push(path)
    match files.get(path) {
      Some(bytes) => Ok(bytes)
      None => Err("must not read payload")
    }
  }
  let bad = run(request(["check", "bad.a", "--external", "--json"]), read)
  assert_true(
    @json.parse(bad.stdout) is { "error": { "code": String("AR012"), .. }, .. },
  )
  let big = run(
    request(["check", "big.a", "--external", "--max-bytes", "300", "--json"]),
    read,
  )
  assert_true(
    @json.parse(big.stdout) is { "error": { "code": String("AR008"), .. }, .. },
  )
  assert_eq(calls, ["bad.a", "big.a"])
}

///|
test "logical CLI directly compares thin snapshots and mixed archive storage" {
  let files : Map[String, Bytes] = { "left/a.o": b"abc", "right/a.o": b"abc" }
  assert_eq(
    execute(["create", "left/lib.a", "left/a.o", "--thin"], files).exit_code,
    0,
  )
  assert_eq(
    execute(["create", "right/lib.a", "right/a.o", "--thin"], files).exit_code,
    0,
  )
  assert_eq(files["left/lib.a"], files["right/lib.a"])
  assert_eq(execute(["create", "packed.a", "right/a.o"], files).exit_code, 0)
  let equal = execute(
    ["diff", "left/lib.a", "packed.a", "--logical", "--json"],
    files,
  )
  assert_eq(equal.exit_code, 0)
  assert_true(
    @json.parse(equal.stdout)
    is {
      "bytes_equal": False,
      "content_equal": True,
      "symbols_equal": True,
      ..
    },
  )
  files["right/a.o"] = b"xyz"
  let changed = execute(
    ["diff", "left/lib.a", "right/lib.a", "--logical", "--json"],
    files,
  )
  assert_eq(changed.exit_code, 1)
  assert_true(
    @json.parse(changed.stdout)
    is {
      "bytes_equal": True,
      "content_equal": False,
      "symbols_equal": True,
      "changes": [
        {
          "before_index": Number(2, ..),
          "after_index": Number(2, ..),
          "payload_changed": True,
          ..
        },
      ],
      ..
    },
  )
  let text = execute(["diff", "left/lib.a", "right/lib.a", "--logical"], files)
  assert_true(text.stdout.contains("container bytes are identical"))
  assert_true(text.stdout.contains("payload=true"))
  assert_eq(execute(["diff", "left/lib.a", "right/lib.a"], files).exit_code, 2)
}

///|
test "thin logical input failures stop before the other archive and retain its path" {
  let archive = query_thin([@ar.ThinWriteMember::new(b"a.o", 3)])
  let calls : Array[String] = []
  let reply = run(
    request(["diff", "first/lib.a", "second/lib.a", "--logical", "--json"]),
    fn(path) {
      calls.push(path)
      Ok(if path == "first/lib.a" { archive } else { b"wrong size" })
    },
  )
  assert_eq(reply.exit_code, 2)
  assert_eq(calls, ["first/lib.a", "first/a.o"])
  assert_true(
    @json.parse(reply.stdout)
    is {
      "input": String("first/lib.a"),
      "error": { "code": String("AR014"), .. },
      ..
    },
  )
}

///|
test "read-only thin commands validate filesystem roots unless parent access is explicit" {
  let archive = query_thin([@ar.ThinWriteMember::new(b"a.o", 3)])
  let reads : Array[String] = []
  let read = fn(path) {
    reads.push(path)
    Ok(if path == "dir/lib.a" { archive } else { b"abc" })
  }
  let denied = run(
    request(["check", "dir/lib.a", "--external", "--json"]),
    read,
    validate_path=fn(_, _) { Err("link resolves outside root") },
  )
  assert_eq(denied.exit_code, 1)
  assert_eq(reads, ["dir/lib.a"])
  reads.clear()
  let allowed = run(
    request(["check", "dir/lib.a", "--external", "--allow-parent-paths"]),
    read,
    validate_path=fn(_, _) { Err("must not check opt-in") },
  )
  assert_eq(allowed.exit_code, 0)
  assert_eq(reads, ["dir/lib.a", "dir/a.o"])
  for
    args in [
      ["inspect", "a", "--external"],
      ["diff", "a", "b", "--external"],
      ["check", "a", "--external", "--external"],
      ["inspect", "a", "--allow-parent-paths"],
      ["diff", "a", "b", "--allow-parent-paths"],
      ["check", "a", "--allow-parent-paths"],
      ["check", "a\u0000b"],
    ] {
    assert_true(parse_args(args) is Err(_))
  }
}
