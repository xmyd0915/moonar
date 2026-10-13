///|
test "JSON preserves raw names and escapes terminal control characters" {
  let archive = parsed(b"!<arch>\n" + record("#1/4", b"\xff\n\"\\x"))
  let text = archive.to_json().stringify()
  let decoded = @json.parse(text)
  assert_true(
    decoded
    is {
      "schema_version": Number(1, ..),
      "members": [{ "name_hex": String("ff0a225c"), "size": Number(1, ..), .. }],
      ..
    },
  )
  assert_false(text.contains("\n"))
}

///|
test "JSON metadata uses strings and blank fields use null" {
  let entry : Member = {
    name: b"a",
    kind: Regular,
    header_offset: 8,
    data_offset: 68,
    size: 0,
    stored_size: 0,
    metadata: {
      timestamp: Some(9007199254740993L),
      uid: None,
      gid: Some(0L),
      mode: Some(420L),
    },
  }
  assert_true(
    member_json(entry, 0)
    is {
      "metadata": {
        "timestamp": String("9007199254740993"),
        "uid": Null,
        "gid": String("0"),
        "mode": String("420"),
        ..
      },
      ..
    },
  )
}

///|
test "comparison and parser errors have explicit machine-readable fields" {
  let a = parsed(b"!<arch>\n")
  let b = parsed(b"!<arch>\n" + record("a/", b"x"))
  assert_true(
    compare(a, b).to_json()
    is {
      "changes": [
        {
          "change": String("added"),
          "before_index": Null,
          "after_index": Number(0, ..),
          "occurrence": Number(1, ..),
          ..
        },
      ],
      ..
    },
  )
  guard parse(b"bad") is Err(error) else { fail("expected an error") }
  assert_true(
    error.to_json()
    is { "error": { "code": String("AR001"), "offset": Number(0, ..), .. }, .. },
  )
}
