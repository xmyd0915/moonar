///|
fn request(args : Array[String]) -> Request raise {
  match parse_args(args) {
    Ok(request) => request
    Err(message) => fail(message)
  }
}

///|
test "CLI validates arguments before reading a file" {
  for
    args in [
      [],
      ["bad"],
      ["inspect"],
      ["check", "a", "b"],
      ["inspect", "--bad", "a"],
      ["check", "a", "--max-bytes"],
      ["check", "a", "--max-members", "-1"],
      ["check", "a", "--max-bytes", "2147483648"],
      ["check", "a", "--max-bytes", "1x"],
      ["check", "a", "--json", "--json"],
    ] {
    assert_true(parse_args(args) is Err(_))
  }
  let parsed = request(["inspect", "--json", "--max-members", "2", "--", "-a"])
  assert_eq(parsed.command, Inspect("-a"))
  assert_true(parsed.json_output)
  assert_eq(parsed.max_members, 2)
}

///|
test "help and version do not read files" {
  let calls : Array[String] = []
  for args in [["--help"], ["--version"]] {
    let result = run(request(args), fn(path) {
      calls.push(path)
      Err("must not read")
    })
    assert_eq(result.exit_code, 0)
    assert_false(result.stdout.is_empty())
  }
  assert_eq(calls.length(), 0)
}

///|
test "check separates parse errors, I/O errors and successful reads" {
  let plain = request(["check", "file.a"])
  assert_eq(run(plain, fn(_) { Ok(b"!<arch>\n") }).exit_code, 0)
  let broken = run(plain, fn(_) { Ok(b"bad") })
  assert_eq(broken.exit_code, 1)
  assert_true(broken.stderr.has_prefix("AR001"))
  let io_error = run(plain, fn(_) { Err("not found\n\u001b[31m") })
  assert_eq(io_error.exit_code, 2)
  assert_false(io_error.stderr.contains("\u001b"))
}

///|
test "inspect JSON reports offsets and parser errors" {
  let json_request = request(["inspect", "file.a", "--json"])
  let good = run(json_request, fn(_) { Ok(b"!<arch>\n") })
  assert_true(
    @json.parse(good.stdout)
    is { "members": [], "byte_length": Number(8, ..), .. },
  )
  let bad = run(json_request, fn(_) { Ok(b"bad") })
  assert_true(
    @json.parse(bad.stdout)
    is { "error": { "code": String("AR001"), "offset": Number(0, ..), .. }, .. },
  )
  assert_eq(bad.stderr, "")
}

///|
test "CLI passes resource limits to the parser" {
  let result = run(request(["check", "a", "--max-bytes", "7"]), fn(_) {
    Ok(b"!<arch>\n")
  })
  assert_eq(result.exit_code, 1)
  assert_true(result.stderr.has_prefix("AR008"))
}
