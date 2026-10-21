///|
test "filesystem roots remain directories during archive path decomposition" {
  assert_eq(path_dir("C:/library.a"), "C:/")
  assert_eq(path_dir("/library.a"), "/")
  assert_eq(relative_path("/", "/object.o"), "object.o")
  assert_eq(relative_path("C:/", "c:/objects/object.o"), "objects/object.o")
  assert_eq(joined_path("/", "object.o"), "/object.o")
  assert_eq(joined_path("C:/", "object.o"), "C:/object.o")
  assert_eq(clean_path("C:/"), "C:/")
}

///|
test "Windows filesystem separators normalize without rewriting archive names or reported outputs" {
  let files : Map[String, Bytes] = { "obj/member.bin": b"payload" }
  let canonical = fn(path) {
    Ok(
      if path == "." {
        "C:\\work"
      } else {
        path.replace_all(old="/", new="\\")
      },
    )
  }
  let read = fn(path) {
    match files.get(path) {
      Some(bytes) => Ok(bytes)
      None => Err("missing " + path)
    }
  }
  let write = fn(path, bytes, _) {
    files[path] = bytes
    Ok(())
  }
  let reply = run(
    request(["create", "C:\\work\\library.a", "obj\\member.bin", "--json"]),
    read,
    write~,
    canonical~,
  )
  assert_eq(reply.exit_code, 0)
  assert_eq(contents(files["C:/work/library.a"]), [(b"member.bin", b"payload")])
  assert_true(
    @json.parse(reply.stdout)
    is Object({ "output": String("C:\\work\\library.a"), .. }),
  )
  let renamed = run(
    request(["rename", "C:\\work\\library.a", "0", "literal\\name"]),
    read,
    write~,
    canonical~,
  )
  assert_eq(renamed.exit_code, 0)
  assert_eq(contents(files["C:/work/library.a"]), [
    (b"literal\\name", b"payload"),
  ])
  assert_eq(windows_path("C:member.bin"), "C:./member.bin")
  assert_eq(path_name(windows_path("C:member.bin")), "member.bin")
  assert_eq(path_dir(windows_path("C:member.bin")), "C:.")
}

///|
test "Windows thin queries resolve current-drive root members without forming a UNC path" {
  let thin = @ar.ThinArchiveBuilder::from_members([
      @ar.ThinWriteMember::new(b"object.o", 3),
    ])
    .unwrap()
    .write()
    .unwrap()
  let seen : Array[String] = []
  let reply = run(
    request(["check", "\\library.a", "--external"]),
    fn(path) {
      seen.push(path)
      if path == "\\library.a" {
        Ok(thin)
      } else if path == "/object.o" {
        Ok(b"abc")
      } else {
        Err("wrong root")
      }
    },
    canonical=fn(_) { Ok("C:\\work") },
  )
  assert_eq(reply.exit_code, 0)
  assert_eq(seen, ["\\library.a", "/object.o"])
}

///|
test "help and version do not consult the filesystem for path syntax" {
  for command in ["--help", "--version"] {
    let seen : Array[String] = []
    let reply = run(request([command]), fn(_) { Err("unused") }, canonical=fn(
      path,
    ) {
      seen.push(path)
      Err("unused")
    })
    assert_eq(reply.exit_code, 0)
    assert_true(seen.is_empty())
  }
}

///|
test "POSIX filenames retain literal backslashes in ordinary archive members" {
  let files : Map[String, Bytes] = { "part\\name.bin": b"payload" }
  let reply = run(
    request(["create", "library.a", "part\\name.bin"]),
    fn(path) {
      match files.get(path) {
        Some(data) => Ok(data)
        None => Err("missing")
      }
    },
    write=fn(path, bytes, _) {
      files[path] = bytes
      Ok(())
    },
  )
  assert_eq(reply.exit_code, 0)
  assert_eq(contents(files["library.a"]), [(b"part\\name.bin", b"payload")])
}
