///|
fn execute(args : Array[String], files : Map[String, Bytes]) -> Reply raise {
  run(
    request(args),
    fn(path) {
      match files.get(clean_path(path)) {
        Some(data) => Ok(data)
        None => Err("missing " + path)
      }
    },
    write=fn(path, data, overwrite) {
      if files.get(path) is Some(_) && !overwrite {
        return Err("output exists")
      }
      files[path] = data
      Ok(())
    },
  )
}

///|
fn contents(bytes : Bytes) -> Array[(Bytes, Bytes)] {
  @ar.parse(bytes)
  .unwrap()
  .edit(drop_symbol_indexes=true)
  .unwrap()
  .members()
  .map(e => (e.name, e.data))
}

///|
test "nested thin CLI creates from archives then resolves edits and protects transitive sources" {
  let base = @ar.ArchiveBuilder::from_members([
      @ar.WriteMember::new(b"one.o", b"abc"),
      @ar.WriteMember::new(b"two.o", b"defg"),
    ])
    .unwrap()
    .write()
    .unwrap()
  let files : Map[String, Bytes] = { "dir/base.a": base }
  assert_eq(
    execute(
      ["create", "outer.a", "dir/base.a", "--thin", "--index", "none"],
      files,
    ).exit_code,
    0,
  )
  let archive = @ar.parse_thin(files["outer.a"]).unwrap()
  assert_eq(archive.get_member(1).unwrap().archive_member_offset, Some(8))
  assert_eq(execute(["check", "outer.a", "--external"], files).exit_code, 0)
  assert_eq(execute(["extract", "outer.a", "1", "copy"], files).exit_code, 0)
  assert_eq(files["copy"], b"defg")
  assert_eq(
    execute(["move", "outer.a", "1", "0", "--index", "none"], files).exit_code,
    0,
  )
  assert_eq(
    execute(["convert", "outer.a", "flat.a", "--index", "none"], files).exit_code,
    0,
  )
  assert_eq(contents(files["flat.a"]), [(b"two.o", b"defg"), (b"one.o", b"abc")])
  assert_eq(
    execute(["diff", "outer.a", "flat.a", "--logical"], files).exit_code,
    0,
  )
  let direct = @ar.ThinArchiveBuilder::from_members([
      @ar.ThinWriteMember::new(b"leaf.o", 3),
    ])
    .unwrap()
    .write()
    .unwrap()
  let offset = @ar.parse_thin(direct).unwrap().get_member(1).unwrap().header_offset
  files["dir/inner.a"] = direct
  files["dir/leaf.o"] = b"abc"
  files["chain.a"] = @ar.ThinArchiveBuilder::from_members([
      @ar.ThinWriteMember::new(
        b"dir/inner.a",
        3,
        archive_member_offset=Some(offset),
      ),
    ])
    .unwrap()
    .write()
    .unwrap()
  for
    args in [
      ["extract", "chain.a", "0", "dir/leaf.o", "--force"],
      ["convert", "chain.a", "dir/leaf.o", "--index", "none", "--force"],
      [
        "delete", "chain.a", "0", "--output", "dir/leaf.o", "--index", "none", "--force",
      ],
    ] {
    assert_eq(execute(args, files).exit_code, 2)
    assert_eq(files["dir/leaf.o"], b"abc")
  }
  files.remove("dir/inner.a") |> ignore
  assert_eq(
    execute(["delete", "chain.a", "0", "--index", "none"], files).exit_code,
    0,
  )
  assert_eq(@ar.parse_thin(files["chain.a"]).unwrap().member_count(), 0)
}

///|
test "editing CLI operates on duplicate members and preserves input on failure" {
  let files : Map[String, Bytes] = {
    "a/same": b"first",
    "b/same": b"second",
    "new": b"replacement",
  }
  assert_eq(
    execute(["create", "out.a", "a/same", "b/same"], files).exit_code,
    0,
  )
  assert_eq(contents(files["out.a"]), [
    (b"same", b"first"),
    (b"same", b"second"),
  ])
  assert_eq(execute(["replace", "out.a", "1", "new"], files).exit_code, 0)
  assert_eq(execute(["move", "out.a", "1", "0"], files).exit_code, 0)
  assert_eq(execute(["rename", "out.a", "1", "old"], files).exit_code, 0)
  assert_eq(
    execute(["add", "out.a", "a/same", "--at", "1"], files).exit_code,
    0,
  )
  assert_eq(contents(files["out.a"]), [
    (b"same", b"replacement"),
    (b"same", b"first"),
    (b"old", b"first"),
  ])
  let saved = files["out.a"]
  assert_eq(execute(["delete", "out.a", "99"], files).exit_code, 2)
  assert_eq(execute(["delete", "out.a", "1", "1"], files).exit_code, 2)
  assert_eq(files["out.a"], saved)
  assert_eq(execute(["delete", "out.a", "0", "2"], files).exit_code, 0)
  assert_eq(contents(files["out.a"]), [(b"same", b"first")])
}

///|
test "extract and conversion use explicit outputs and overwrite policy" {
  let files : Map[String, Bytes] = { "data": b"\x00\xff\n" }
  assert_eq(execute(["create", "out.a", "data"], files).exit_code, 0)
  let saved = files["out.a"]
  assert_eq(execute(["create", "out.a"], files).exit_code, 2)
  assert_eq(files["out.a"], saved)
  assert_eq(
    execute(["extract", "out.a", "0", "out.a", "--force"], files).exit_code,
    2,
  )
  assert_eq(execute(["extract", "out.a", "0", "copy"], files).exit_code, 0)
  assert_eq(files["copy"], files["data"])
  assert_eq(execute(["extract", "out.a", "0", "copy"], files).exit_code, 2)
  assert_eq(
    execute(["convert", "out.a", "bsd.a", "--format", "bsd64"], files).exit_code,
    0,
  )
  assert_eq(contents(files["bsd.a"]), contents(saved))
  assert_eq(
    @ar.parse(files["bsd.a"]).unwrap().symbol_indexes()[0].format,
    "bsd64-neutral",
  )
}

///|
test "thin create edit rebase materialize and member access form one workflow" {
  let files : Map[String, Bytes] = { "obj/a": b"aaa", "obj/b": b"bbbb" }
  assert_eq(
    execute(["create", "lib.a", "obj/a", "obj/b", "--thin"], files).exit_code,
    0,
  )
  assert_true(files["lib.a"].has_prefix(b"!<thin>\n"[:]))
  assert_eq(execute(["move", "lib.a", "1", "0"], files).exit_code, 0)
  assert_eq(execute(["extract", "lib.a", "0", "copy"], files).exit_code, 0)
  assert_eq(files["copy"], b"bbbb")
  assert_eq(execute(["convert", "lib.a", "regular.a"], files).exit_code, 0)
  assert_eq(contents(files["regular.a"]), [
    (b"obj/b", b"bbbb"),
    (b"obj/a", b"aaa"),
  ])
  assert_eq(
    execute(["index", "lib.a", "--output", "dist/lib.a"], files).exit_code,
    0,
  )
  assert_eq(
    execute(["extract", "dist/lib.a", "0", "copy2"], files).exit_code,
    2,
  )
  assert_eq(
    execute(
      ["extract", "dist/lib.a", "0", "copy2", "--allow-parent-paths"],
      files,
    ).exit_code,
    0,
  )
  assert_eq(files["copy2"], b"bbbb")
  files["obj/b"] = b"changed"
  let saved = files["lib.a"]
  assert_eq(execute(["index", "lib.a"], files).exit_code, 2)
  assert_eq(files["lib.a"], saved)
  // Deletion of the missing/stale member remains possible before rebuilding.
  assert_eq(execute(["delete", "lib.a", "0"], files).exit_code, 0)
}

///|
test "recognized malformed objects fail before writing and index none is explicit" {
  let files : Map[String, Bytes] = {
    "bad.o": b"\x7fELF",
    "out.a": b"unchanged",
  }
  assert_eq(
    execute(["create", "out.a", "bad.o", "--force"], files).exit_code,
    2,
  )
  assert_eq(files["out.a"], b"unchanged")
  assert_eq(
    execute(["create", "out.a", "bad.o", "--force", "--index", "none"], files).exit_code,
    0,
  )
  assert_eq(@ar.parse(files["out.a"]).unwrap().symbol_indexes(), [])
}

///|
test "thin canonical path validation is called before file reading" {
  let plan = @ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"link/object", 3),
  ]).unwrap()
  let archive = plan.write().unwrap()
  let paths : Array[String] = []
  let checked : Array[(String, String)] = []
  let reply = run(
    request(["extract", "dir/lib.a", "0", "out"]),
    fn(path) {
      paths.push(path)
      Ok(archive)
    },
    validate_path=fn(base, target) {
      checked.push((base, target))
      Err("resolved path leaves the archive directory")
    },
  )
  assert_eq(reply.exit_code, 2)
  assert_eq(paths, ["dir/lib.a"])
  assert_eq(checked, [("dir", "dir/link/object")])
}

///|
test "edit arguments reject invalid or irrelevant options and positions" {
  for
    args in [
      ["replace", "a", "-1", "file"],
      ["move", "a", "0", "2147483648"],
      ["create", "a", "--format", "unknown"],
      ["add", "a", "file", "--thin"],
      ["rename", "a", "0", "new", "--at", "1"],
      ["extract", "a", "0", "out", "--index", "none"],
      ["create", "a", "--output", "b"],
      ["index", "a", "--index", "none"],
      ["create", "a", "--thin", "--format", "bsd"],
      ["create", "a", "--max-bytes", "1", "--max-bytes", "2"],
      ["create", "a", "--big-endian-index"],
      ["create", "a\u0000b"],
    ] {
    assert_true(parse_args(args) is Err(_))
  }
}

///|
test "management output identities resolve existing aliases and new output parents" {
  let paths : Map[String, String] = {
    "link/existing.a": "C:/real/existing.a",
    "link": "C:/real",
  }
  let canonical = fn(path) {
    match paths.get(path) {
      Some(value) => Ok(value)
      None => Err("missing " + path)
    }
  }
  assert_eq(
    output_path_identity("link/existing.a", canonical),
    "C:/real/existing.a",
  )
  assert_eq(output_path_identity("link/new.a", canonical), "C:/real/new.a")
  assert_true(same_path_identity("C:/real/existing.a", "c:/REAL/EXISTING.A"))
  assert_true(same_path_identity("//server/share/file", "//SERVER/SHARE/FILE"))
  assert_false(same_path_identity("/real/existing.a", "/real/EXISTING.A"))
}

///|
test "thin relative paths retain drive and UNC share roots" {
  assert_eq(
    relative_path("C:/lib", "c:/lib/objects/member.o"),
    "objects/member.o",
  )
  assert_eq(relative_path("C:/Base", "c:/base/member.o"), "../base/member.o")
  assert_eq(
    relative_path("C:/Parent/Base", "c:/Parent/base/member.o"),
    "../base/member.o",
  )
  assert_eq(
    relative_path("//server/share/lib", "//SERVER/SHARE/objects/member.o"),
    "../objects/member.o",
  )
  assert_eq(
    relative_path("//server/share/Base", "//SERVER/SHARE/base/member.o"),
    "../base/member.o",
  )
  for
    (base, target) in [
      ("C:/lib", "D:/objects/member.o"),
      ("//server/shareA/lib", "//server/shareB/objects/member.o"),
      ("//serverA/share/lib", "//serverB/share/objects/member.o"),
      ("/server/share/lib", "//server/share/objects/member.o"),
    ] {
    let rejected = try {
      ignore(relative_path(base, target))
      false
    } catch {
      ManageFailure(code, _) => code == "IO003"
    }
    assert_true(rejected)
  }
}

///|
test "extract and thin writes protect canonical original and final dependencies even without an index" {
  let archive = @ar.ArchiveBuilder::from_members([
      @ar.WriteMember::new(b"first", b"payload"),
    ])
    .unwrap()
    .write()
    .unwrap()
  let thin = @ar.ThinArchiveBuilder::from_members([
      @ar.ThinWriteMember::new(b"payload", 7),
    ])
    .unwrap()
    .write()
    .unwrap()
  let files : Map[String, Bytes] = {
    "archive.a": archive,
    "thin.a": thin,
    "payload": b"payload",
  }
  let canonical = fn(path : String) -> Result[String, String] {
    let path = clean_path(path)
    Ok(
      if path == "." || path == "alias" {
        "C:/real"
      } else if path.has_prefix("C:/") || path.has_prefix("c:/") {
        path
      } else if path.has_prefix("alias/") {
        "C:/real/" + path_name(path)
      } else {
        "C:/real/" + path
      },
    )
  }
  let writes : Array[String] = []
  for
    args in [
      ["extract", "archive.a", "0", "ARCHIVE.A", "--force"],
      ["extract", "archive.a", "0", "alias/archive.a", "--force"],
      ["create", "PAYLOAD", "payload", "--thin", "--index", "none", "--force"],
      ["index", "thin.a", "--output", "alias/payload", "--force"],
      ["rename", "thin.a", "0", "THIN.A", "--index", "none"],
      [
        "delete", "thin.a", "0", "--output", "PAYLOAD", "--index", "none", "--force",
      ],
      ["convert", "thin.a", "PAYLOAD", "--index", "none", "--force"],
      [
        "replace", "thin.a", "0", "archive.a", "--output", "alias/archive.a", "--index",
        "none", "--force",
      ],
    ] {
    let reply = run(
      request(args),
      fn(path) {
        match files.get(path_name(path).to_lower()) {
          Some(bytes) => Ok(bytes)
          None => Err("missing " + path)
        }
      },
      canonical~,
      write=fn(path, _, _) {
        writes.push(path)
        Ok(())
      },
    )
    assert_eq(reply.exit_code, 2)
    assert_true(reply.stderr.has_prefix("IO003"))
  }
  assert_eq(writes, [])
  assert_eq(files["archive.a"], archive)
  assert_eq(files["thin.a"], thin)
  assert_eq(files["payload"], b"payload")
}

///|
test "metadata edits can remove absent thin members while protecting their resolved output identity" {
  let thin = @ar.ThinArchiveBuilder::from_members([
      @ar.ThinWriteMember::new(b"missing", 7),
    ])
    .unwrap()
    .write()
    .unwrap()
  let canonical = fn(path : String) -> Result[String, String] {
    match clean_path(path) {
      "." | "C:/real" => Ok("C:/real")
      "thin.a" => Ok("C:/real/thin.a")
      _ => Err("missing")
    }
  }
  let writes : Array[String] = []
  let reply = run(
    request(["delete", "thin.a", "0", "--index", "none"]),
    fn(_) { Ok(thin) },
    canonical~,
    write=fn(path, _, overwrite) {
      assert_true(overwrite) catch {
        _ => return Err("in-place write must replace")
      }
      writes.push(path)
      Ok(())
    },
  )
  assert_eq(reply.exit_code, 0)
  assert_eq(writes, ["thin.a"])
  let blocked = run(
    request(["delete", "thin.a", "0", "--index", "none", "--output", "missing"]),
    fn(_) { Ok(thin) },
    canonical~,
    write=fn(path, _, _) {
      writes.push(path)
      Ok(())
    },
  )
  assert_eq(blocked.exit_code, 2)
  assert_eq(writes, ["thin.a"])
}

///|
test "case-distinct canonical Windows outputs never receive implicit replacement permission" {
  let archive = @ar.ArchiveBuilder::from_members([
      @ar.WriteMember::new(b"first", b"payload"),
    ])
    .unwrap()
    .write()
    .unwrap()
  for
    args in [
      [
        "rename", "C:/Base/library.a", "0", "changed", "--output", "C:/base/library.a",
        "--index", "none",
      ],
      ["convert", "C:/Base/library.a", "C:/base/library.a", "--index", "none"],
      ["index", "C:/Base/library.a", "--output", "C:/base/library.a"],
    ] {
    let permissions : Array[Bool] = []
    let reply = run(
      request(args),
      fn(_) { Ok(archive) },
      canonical=fn(path) { Ok(path) },
      write=fn(_, _, overwrite) {
        permissions.push(overwrite)
        if overwrite {
          Ok(())
        } else {
          Err("output exists")
        }
      },
    )
    assert_eq(permissions, [false])
    assert_eq(reply.exit_code, 2)
    let forced = args.copy()
    forced.push("--force")
    let reply = run(
      request(forced),
      fn(_) { Ok(archive) },
      canonical=fn(path) { Ok(path) },
      write=fn(_, _, overwrite) {
        permissions.push(overwrite)
        if overwrite {
          Ok(())
        } else {
          Err("output exists")
        }
      },
    )
    assert_eq(permissions, [false, true])
    assert_eq(reply.exit_code, 0)
  }
}
