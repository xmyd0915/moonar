///|
test "JSON list selectors extract and delete the same ordinary member" {
  for thin in [false, true] {
    let files : Map[String, Bytes] = { "first": b"one", "second": b"two" }
    let args = ["create", "lib.a", "first", "second"]
    if thin {
      args.push("--thin")
    }
    assert_eq(execute(args, files).exit_code, 0)
    let reply = execute(["list", "lib.a", "--json"], files)
    assert_eq(reply.exit_code, 0)
    let value = @json.parse(reply.stdout)
    let fields = match value {
      Object(fields) => fields
      _ => abort("list object")
    }
    assert_eq(fields["index_kind"], Json("ordinary_member"))
    let members = match fields["members"] {
      Array(members) => members
      _ => abort("members array")
    }
    assert_eq(members.length(), 2)
    let first = match members[0] {
      Object(first) => first
      _ => abort("member object")
    }
    assert_eq(first["index"], Json(0))
    assert_true(first["record_index"] != Json(0))
    let index = first["index"].stringify()
    assert_eq(execute(["extract", "lib.a", index, "copy"], files).exit_code, 0)
    assert_eq(files["copy"], b"one")
    assert_eq(execute(["delete", "lib.a", index], files).exit_code, 0)
    assert_eq(
      execute(["extract", "lib.a", "0", "remaining"], files).exit_code,
      0,
    )
    assert_eq(files["remaining"], b"two")
  }
}

///|
test "thin query diagnostics retain the structured byte offset" {
  for command in ["list", "inspect", "check"] {
    let reply = run(request([command, "broken.a", "--json"]), fn(_) {
      Ok(b"!<thin>\nx")
    })
    assert_eq(reply.exit_code, 1)
    let value = @json.parse(reply.stdout)
    let fields = match value {
      Object(fields) => fields
      _ => abort("error object")
    }
    let error = match fields["error"] {
      Object(error) => error
      _ => abort("error details")
    }
    assert_eq(error["code"], Json("AR002"))
    assert_eq(error["offset"], Json(8))
  }
}
