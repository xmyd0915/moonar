///|
test "diff returns zero for identical bytes and one for differences" {
  let one = b"!<arch>\na/              0           0     0     644     1         `\nx\n"
  let different = b"!<arch>\na/              1           0     0     644     1         `\nx\n"
  let args = request(["diff", "before.a", "after.a", "--json"])
  assert_eq(run(args, fn(_) { Ok(one) }).exit_code, 0)
  let delta = run(args, fn(path) {
    Ok(if path == "before.a" { one } else { different })
  })
  assert_eq(delta.exit_code, 1)
  assert_true(
    @json.parse(delta.stdout)
    is {
      "changes": [{ "payload_changed": False, "metadata_changed": True, .. }],
      ..
    },
  )
}

///|
test "diff errors name the failing input and stop before another read" {
  let calls : Array[String] = []
  let result = run(request(["diff", "bad.a", "other.a", "--json"]), fn(path) {
    calls.push(path)
    Ok(b"bad")
  })
  assert_eq(result.exit_code, 2)
  assert_eq(calls, ["bad.a"])
  assert_true(
    @json.parse(result.stdout)
    is {
      "input": String("bad.a"),
      "error": { "code": String("AR001"), .. },
      ..
    },
  )
  assert_true(parse_args(["diff", "only-one.a"]) is Err(_))
}

///|
test "diff plain output escapes names and reports container-only differences" {
  let a = b"!<arch>\na/              0           0     0     644     1         `\nx\n"
  let b = b"!<arch>\na               0           0     0     644     1         `\nx\n"
  let result = run(request(["diff", "a", "b"]), fn(path) {
    Ok(if path == "a" { a } else { b })
  })
  assert_eq(result.exit_code, 1)
  assert_true(result.stdout.contains("header spelling differs"))
  let delta : @ar.Comparison = {
    bytes_equal: false,
    order_changed: false,
    changes: [
      {
        change: @ar.Added,
        name: b"\x1b\n",
        member_kind: @ar.Regular,
        occurrence: 1,
        before_index: None,
        after_index: Some(0),
        payload_changed: false,
        metadata_changed: false,
      },
    ],
  }
  assert_false(diff_text(delta).contains("\u001b"))
}
