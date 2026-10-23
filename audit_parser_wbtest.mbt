///|
test "BSD byte-order probing rejects invalid envelopes before symbol budgets" {
  // The reverse-endian interpretation sees 65,536 ranlib bytes instead of
  // 256. Its apparent table fits in the payload, but its string-table size
  // and padding do not form a valid envelope.
  for little in [false, true] {
    let strings = b"entry\x00" + Bytes::make(65530, b'\x00')
    let body_size = 4 + 256 + 4 + strings.length()
    let target = 8 +
      record("#1/9", b"__.SYMDEF" + Bytes::make(body_size, b'\x00')).length()
    let body = word(256, 4, little) +
      (word(0, 4, little) + word(target, 4, little)).repeat(32) +
      word(strings.length(), 4, little) +
      strings
    let bytes = b"!<arch>\n" +
      record("#1/9", b"__.SYMDEF" + body) +
      record("entry.o/", b"payload")
    let expected = parsed(bytes).symbol_indexes()[0]
    assert_eq(expected.symbols.length(), 32)
    match parse(bytes, max_symbols=32, max_symbol_name_bytes=160) {
      Ok(archive) => assert_eq(archive.symbol_indexes()[0], expected)
      Err(error) => fail(error.to_repr().to_string())
    }
    assert_true(parse(bytes, max_symbols=31) is Err({ code: "AR008", .. }))
    assert_true(
      parse(bytes, max_symbols=32, max_symbol_name_bytes=159)
      is Err({ code: "AR008", .. }),
    )
  }
}
