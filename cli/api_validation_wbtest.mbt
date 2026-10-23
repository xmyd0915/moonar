///|
fn rejected_without_io(value : Request) -> Unit raise {
  let callbacks : Array[String] = []
  let reply = run(
    value,
    fn(path) {
      callbacks.push("read:" + path)
      Ok(b"!<arch>\n")
    },
    write=fn(path, _, _) {
      callbacks.push("write:" + path)
      Ok(())
    },
    canonical=fn(path) {
      callbacks.push("canonical:" + path)
      Ok(path)
    },
    validate_path=fn(_, path) {
      callbacks.push("validate:" + path)
      Ok(())
    },
  )
  assert_eq(reply.exit_code, 2)
  assert_true(callbacks.is_empty())
  if value.json_output {
    assert_eq(reply.stderr, "")
    assert_true(
      @json.parse(reply.stdout)
      is Object({ "error": Object({ "code": String("CLI001"), .. }), .. }),
    )
  } else {
    assert_eq(reply.stdout, "")
    assert_true(reply.stderr.has_prefix("CLI001:"))
  }
}

///|
test "public CLI rejects missing and surplus operation arguments before callbacks" {
  let base = request(["create", "out.a"])
  guard base.command is Manage(options) else { abort("manage request") }
  for
    operation in [
      "create", "add", "replace", "delete", "move", "rename", "extract", "convert",
      "index",
    ] {
    rejected_without_io({
      ..base,
      command: Manage({ ..options, operation, arguments: [], }),
    })
  }
  for operation in ["replace", "move", "rename", "extract", "convert", "index"] {
    rejected_without_io({
      ..base,
      command: Manage({
        ..options,
        operation,
        arguments: ["in.a", "0", "out.a", "unexpected"],
      }),
    })
  }
}

///|
test "public CLI rejects malformed member selectors before callbacks" {
  let base = request(["create", "out.a"])
  guard base.command is Manage(options) else { abort("manage request") }
  for operation in ["replace", "delete", "move", "rename", "extract"] {
    for selector in ["-1", "x", "2147483648", ""] {
      let arguments = if operation == "delete" {
        ["in.a", selector]
      } else if operation == "move" {
        ["in.a", "0", selector]
      } else {
        ["in.a", selector, "out.a"]
      }
      rejected_without_io({
        ..base,
        command: Manage({ ..options, operation, arguments, }),
      })
    }
  }
}

///|
test "public CLI rejects unknown operations and index modes before writing" {
  let base = request(["create", "out.a", "--json"])
  guard base.command is Manage(options) else { abort("manage request") }
  rejected_without_io({
    ..base,
    command: Manage({ ..options, operation: "unknown", }),
  })
  rejected_without_io({
    ..base,
    command: Manage({ ..options, index_mode: "invalid", }),
  })
}

///|
test "public CLI rejects invalid write option combinations before callbacks" {
  let base = request(["create", "out.a"])
  guard base.command is Manage(options) else { abort("manage request") }
  let invalid : Array[ManageOptions] = [
    { ..options, output: Some("second.a"), },
    { ..options, at: Some(0), },
    { ..options, thin: true, format: @ar.Bsd, },
    { ..options, little_endian: false, },
    { ..options, operation: "index", thin: true, },
    { ..options, operation: "index", index_mode: "none", },
    {
      ..options,
      operation: "add",
      arguments: ["out.a", "input"],
      at: Some(-1),
    },
    {
      ..options,
      operation: "extract",
      arguments: ["in.a", "0", "out"],
      preserve: true,
    },
    {
      ..options,
      operation: "extract",
      arguments: ["in.a", "0", "out"],
      index_mode: "none",
    },
  ]
  for item in invalid {
    rejected_without_io({ ..base, command: Manage(item), })
  }
  rejected_without_io({ ..base, allow_parent_paths: true, })
  rejected_without_io({
    ..base,
    command: Manage({ ..options, allow_parent: true, }),
  })
}

///|
test "public CLI rejects invalid paths and query flag combinations" {
  let base = request(["check", "in.a"])
  for path in ["", "part\u0000name"] {
    for command in [Inspect(path), List(path), Check(path), Diff("in.a", path)] {
      rejected_without_io({ ..base, command, })
    }
    let create = request(["create", "out.a"])
    guard create.command is Manage(options) else { abort("manage request") }
    rejected_without_io({
      ..create,
      command: Manage({ ..options, arguments: [path], }),
    })
    rejected_without_io({
      ..create,
      command: Manage({ ..options, operation: "index", output: Some(path), }),
    })
  }
  rejected_without_io({ ..base, logical: true, })
  rejected_without_io({ ..base, command: List("in.a"), external: true, })
  rejected_without_io({ ..base, command: Diff("a", "b"), external: true, })
  rejected_without_io({ ..base, allow_parent_paths: true, })
}

///|
test "public CLI rejects negative budgets and excessive nesting before callbacks" {
  let base = request(["check", "in.a", "--json"])
  for
    invalid in [
      { ..base, max_bytes: -1, },
      { ..base, max_members: -1, },
      { ..base, max_name_bytes: -1, },
      { ..base, max_symbols: -1, },
      { ..base, max_symbol_name_bytes: -1, },
      { ..base, max_archive_bytes: -1, },
      { ..base, max_depth: -1, },
      { ..base, max_depth: 65, },
    ] {
    rejected_without_io(invalid)
  }
}

///|
test "public CLI accepts directly constructed valid requests and zero resource budgets" {
  let base = request(["create", "out.a"])
  guard base.command is Manage(options) else { abort("manage request") }
  let written : Array[Bytes] = []
  let created = run(
    {
      ..base,
      command: Manage({
        ..options,
        format: @ar.Bsd,
        little_endian: false,
        index_mode: "none",
      }),
      max_bytes: 8,
      max_members: 0,
      max_name_bytes: 0,
      max_symbols: 0,
      max_symbol_name_bytes: 0,
      max_archive_bytes: 0,
      max_depth: 64,
    },
    fn(_) { Err("no input is needed") },
    write=fn(path, bytes, overwrite) {
      if path != "out.a" {
        return Err("wrong output")
      }
      if overwrite {
        return Err("unexpected replacement")
      }
      written.push(bytes)
      Ok(())
    },
  )
  assert_eq(created.exit_code, 0)
  assert_eq(written, [b"!<arch>\n"])
  let checked = run(
    {
      ..base,
      command: Check("out.a"),
      max_bytes: 8,
      max_members: 0,
      max_name_bytes: 0,
      max_symbols: 0,
      max_symbol_name_bytes: 0,
      max_archive_bytes: 0,
      max_depth: 0,
    },
    fn(_) { Ok(written[0]) },
  )
  assert_eq(checked.exit_code, 0)
}
