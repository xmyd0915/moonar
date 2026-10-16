///|
test "inserting a same-name member preserves unchanged content identities" {
  let a = record("same.o/", b"one")
  let b = record("same.o/", b"two")
  let before = parsed(b"!<arch>\n" + a + b)
  let after = parsed(b"!<arch>\n" + record("same.o/", b"new") + a + b)
  let delta = compare(before, after)
  assert_eq(delta.changes.length(), 1)
  assert_eq(delta.changes[0].change, Added)
  assert_eq(delta.changes[0].after_index, Some(0))
  assert_false(delta.order_changed)
  assert_eq(delta.ambiguities, [])
  let reversed = compare(after, before)
  assert_eq(reversed.changes.length(), 1)
  assert_eq(reversed.changes[0].change, Removed)
}

///|
test "same-name member reorder is visible after content matching" {
  let a = record("same.o/", b"one")
  let b = record("same.o/", b"two")
  let delta = compare(
    parsed(b"!<arch>\n" + a + b),
    parsed(b"!<arch>\n" + b + a),
  )
  assert_true(delta.order_changed)
  assert_eq(delta.changes, [])
  assert_eq(delta.ambiguities, [])
}

///|
test "ambiguous duplicate identities are explicit and deterministic" {
  let before = parsed(
    b"!<arch>\n" + record("same/", b"a") + record("same/", b"b"),
  )
  let after = parsed(
    b"!<arch>\n" + record("same/", b"c") + record("same/", b"d"),
  )
  let delta = compare(before, after)
  assert_eq(delta.ambiguities.length(), 1)
  assert_eq(delta.ambiguities[0].before_indices, [0, 1])
  assert_eq(delta.ambiguities[0].after_indices, [0, 1])
  assert_eq(compare(before, after), delta)
  let identical = record("same/", b"a")
  let duplicate = compare(
    parsed(b"!<arch>\n" + identical),
    parsed(b"!<arch>\n" + identical + identical),
  )
  assert_eq(duplicate.ambiguities.length(), 1)
  assert_eq(compare(before, before).ambiguities, [])
}

///|
test "GNU and BSD long-name encodings have equal logical members" {
  let name = b"a_long_object_name.o"
  let gnu = parsed(
    b"!<arch>\n" + record("//", name + b"/\n") + record("/0", b"payload"),
  )
  let bsd = parsed(
    b"!<arch>\n" + record("#1/\{name.length()}", name + b"payload"),
  )
  assert_eq(compare(gnu, bsd).changes.length(), 1)
  let delta = compare_logical(gnu, bsd)
  assert_false(delta.bytes_equal)
  assert_true(delta.content_equal)
  assert_true(delta.symbols_equal)
  assert_false(delta.metadata_changed)
  assert_false(delta.order_changed)
  assert_eq(delta.changes, [])
}

///|
test "symbol mappings survive format, byte width, endianness and offset changes" {
  let gnu = parsed(indexed_archive(b"entry"))
  for width in [4, 8] {
    for little in [true, false] {
      let bsd = parsed(indexed_archive(b"entry", width~, little~, bsd=true))
      let delta = compare_logical(gnu, bsd)
      assert_true(delta.content_equal)
      assert_true(delta.symbols_equal)
      assert_false(delta.symbol_index_presence_changed)
      assert_eq(delta.changes, [])
    }
  }
  assert_false(
    compare_logical(gnu, parsed(indexed_archive(b"other"))).symbols_equal,
  )
  let unindexed = parsed(b"!<arch>\n" + record("a.o/", b"payload"))
  let removed = compare_logical(gnu, unindexed)
  assert_true(removed.content_equal)
  assert_false(removed.symbols_equal)
  assert_true(removed.symbol_index_presence_changed)
}

///|
test "logical order and metadata remain distinct from content equality" {
  let before = parsed(b"!<arch>\n" + record("a/", b"a") + record("b/", b"b"))
  let after = parsed(
    b"!<arch>\n" + record("b/", b"b", date="1") + record("a/", b"a"),
  )
  let delta = compare_logical(before, after)
  assert_true(delta.content_equal)
  assert_true(delta.order_changed)
  assert_true(delta.metadata_changed)
  assert_eq(delta.changes.length(), 1)
}

///|
test "Darwin payload padding is never removed by logical comparison" {
  let plain = parsed(b"!<arch>\n" + record("a/", b"x\n"))
  let padded = parsed(b"!<arch>\n" + record("#1/1", b"ax\n\n\n\n\n\n\n"))
  assert_false(compare_logical(plain, padded).content_equal)
}

///|
test "large duplicate groups match without a quadratic alignment matrix" {
  let repeated = record("same/", b"payload").repeat(2000)
  let before = parsed(b"!<arch>\n" + repeated)
  let after = parsed(b"!<arch>\n" + record("same/", b"new") + repeated)
  let delta = compare(before, after)
  assert_eq(delta.changes.length(), 1)
  assert_eq(delta.changes[0].after_index, Some(0))
  assert_eq(delta.ambiguities.length(), 1)
}

///|
test "logical symbol comparison preserves duplicate-symbol target precedence" {
  let first = record("a.o/", b"x")
  let second = record("b.o/", b"y")
  let body = word(2, 4, false) +
    word(84, 4, false) +
    word(146, 4, false) +
    b"e\x00e\x00"
  let other = word(2, 4, false) +
    word(146, 4, false) +
    word(84, 4, false) +
    b"e\x00e\x00"
  let before = parsed(b"!<arch>\n" + record("/", body) + first + second)
  let after = parsed(b"!<arch>\n" + record("/", other) + first + second)
  let delta = compare_logical(before, after)
  assert_true(delta.content_equal)
  assert_false(delta.order_changed)
  assert_false(delta.symbols_equal)
  assert_eq(delta.changes, [])
}

///|
test "different symbol name ordering preserves logical mappings" {
  let first = record("a.o/", b"x")
  let second = record("b.o/", b"y")
  let body = word(2, 4, false) +
    word(84, 4, false) +
    word(146, 4, false) +
    b"x\x00y\x00"
  let other = word(2, 4, false) +
    word(146, 4, false) +
    word(84, 4, false) +
    b"y\x00x\x00"
  let before = parsed(b"!<arch>\n" + record("/", body) + first + second)
  let after = parsed(b"!<arch>\n" + record("/", other) + first + second)
  assert_true(compare_logical(before, after).symbols_equal)
}
