///|
test "identical archives and metadata-only differences" {
  let a = parsed(b"!<arch>\n" + record("a/", b"same", date="1"))
  let b = parsed(b"!<arch>\n" + record("a/", b"same", date="2"))
  assert_eq(compare(a, a), {
    bytes_equal: true,
    order_changed: false,
    changes: [],
  })
  let difference = compare(a, b)
  assert_false(difference.bytes_equal)
  assert_false(difference.order_changed)
  assert_eq(difference.changes.length(), 1)
  assert_eq(difference.changes[0].change, Modified)
  assert_false(difference.changes[0].payload_changed)
  assert_true(difference.changes[0].metadata_changed)
}

///|
test "duplicate names match by occurrence without collapsing records" {
  let a = parsed(b"!<arch>\n" + record("a/", b"one") + record("a/", b"two"))
  let b = parsed(
    b"!<arch>\n" +
    record("a/", b"one") +
    record("a/", b"new") +
    record("a/", b"three"),
  )
  let delta = compare(a, b)
  assert_eq(delta.changes.length(), 2)
  assert_eq(delta.changes[0].occurrence, 2)
  assert_true(delta.changes[0].payload_changed)
  assert_eq(delta.changes[1].occurrence, 3)
  assert_eq(delta.changes[1].change, Added)
  assert_eq(compare(b, a).changes[1].change, Removed)
}

///|
test "insertion is not reorder, but common records swapping is" {
  let a = record("a/", b"a")
  let b = record("b/", b"b")
  let c = record("c/", b"c")
  let original = parsed(b"!<arch>\n" + a + b)
  let inserted = compare(original, parsed(b"!<arch>\n" + c + a + b))
  assert_false(inserted.order_changed)
  assert_eq(inserted.changes.length(), 1)
  let swapped = compare(original, parsed(b"!<arch>\n" + b + a))
  assert_true(swapped.order_changed)
  assert_eq(swapped.changes.length(), 0)
}

///|
test "opaque symbol tables cannot disappear from comparison" {
  let a = parsed(b"!<arch>\n" + record("/", b"one") + record("a/", b"same"))
  let b = parsed(b"!<arch>\n" + record("/", b"two") + record("a/", b"same"))
  let delta = compare(a, b)
  assert_eq(delta.changes.length(), 1)
  assert_eq(delta.changes[0].member_kind, SymbolTable)
  assert_true(delta.changes[0].payload_changed)
}

///|
test "raw-byte equality also notices container spelling" {
  let a = parsed(b"!<arch>\n" + record("a/", b"same"))
  let b = parsed(b"!<arch>\n" + record("a", b"same"))
  let delta = compare(a, b)
  assert_false(delta.bytes_equal)
  assert_false(delta.order_changed)
  assert_eq(delta.changes.length(), 0)
}
