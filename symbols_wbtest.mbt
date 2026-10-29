///|
fn word(value : Int32, width : Int32, little : Bool) -> Bytes {
  Bytes::makei(width, fn(n) {
    let shift = (if little { n } else { width - 1 - n }) * 8
    (if shift >= 32 { 0 } else { (value >> shift) & 255 }).to_byte()
  })
}

///|
fn indexed_archive(
  symbol : Bytes,
  width~ : Int32 = 4,
  little~ : Bool = false,
  bsd~ : Bool = false,
  target_delta~ : Int32 = 0,
) -> Bytes {
  let name = if bsd {
    if width == 4 {
      "__.SYMDEF"
    } else {
      "__.SYMDEF_64"
    }
  } else if width == 4 {
    "/"
  } else {
    "/SYM64/"
  }
  let size = (if bsd { width * 4 } else { width * 2 }) + symbol.length() + 1
  let header_name = if bsd { "#1/\{name.length()}" } else { name }
  let prefix = if bsd { @utf8.encode(name) } else { b"" }
  let target = 8 +
    record(header_name, prefix + Bytes::make(size, b'\x00')).length() +
    target_delta
  let body = if bsd {
    word(width * 2, width, little) +
    word(0, width, little) +
    word(target, width, little) +
    word(symbol.length() + 1, width, little)
  } else {
    word(1, width, false) + word(target, width, false)
  }
  b"!<arch>\n" +
  record(header_name, prefix + body + symbol + b"\x00") +
  record("a.o/", b"payload")
}

///|
test "GNU 32 and 64 bit symbol indexes resolve exact header targets" {
  for width in [4, 8] {
    let archive = parsed(indexed_archive(b"entry\xff", width~))
    let index = archive.symbol_indexes()[0]
    assert_eq(index.format, if width == 4 { "gnu32" } else { "gnu64" })
    assert_eq(index.symbols[0].name, b"entry\xff")
    assert_eq(index.symbols[0].member_index, 1)
    let symbol = index.symbols[0]
    assert_eq(
      archive.data[symbol.name_offset:symbol.name_offset + symbol.name.length()].to_owned(),
      symbol.name,
    )
  }
}

///|
test "BSD ranlib handles both widths and byte orders" {
  for width in [4, 8] {
    for little in [true, false] {
      let archive = parsed(indexed_archive(b"entry", width~, little~, bsd=true))
      let table = archive.symbol_indexes()[0]
      assert_eq(
        table.format,
        "bsd\{width * 8}-\{if little { "le" } else { "be" }}",
      )
      assert_eq(table.symbols[0].name, b"entry")
      assert_eq(table.symbols[0].member_index, 1)
    }
  }
}

///|
test "invalid index targets include header interior, EOF and special records" {
  for bsd in [true, false] {
    for width in [4, 8] {
      assert_eq(
        error_code(indexed_archive(b"entry", width~, bsd~, target_delta=1)),
        "AR009",
      )
      assert_eq(
        error_code(indexed_archive(b"entry", width~, bsd~, target_delta=100)),
        "AR009",
      )
    }
  }
  assert_eq(
    error_code(
      b"!<arch>\n" +
      record("/", word(1, 4, false) + word(8, 4, false) + b"entry\x00"),
    ),
    "AR009",
  )
}

///|
test "symbol count and expanded name limits are enforced" {
  for bsd in [true, false] {
    let input = indexed_archive(b"entry", bsd~)
    assert_true(parse(input, max_symbols=0) is Err({ code: "AR008", .. }))
    assert_true(
      parse(input, max_symbol_name_bytes=4) is Err({ code: "AR008", .. }),
    )
    assert_true(parse(input, max_symbols=1, max_symbol_name_bytes=5) is Ok(_))
  }
  assert_true(parse(b"!<arch>\n", max_symbols=-1) is Err({ code: "AR008", .. }))
}

///|
test "counts, strings, overflow and trailing padding are validated" {
  for
    body in [
      b"",
      b"\xff".repeat(8),
      word(1, 4, false),
      word(0, 4, false) + b"x",
      word(0, 4, false) + b"\x00\x00",
    ] {
    assert_eq(error_code(b"!<arch>\n" + record("/", body)), "AR009")
  }
  let good = indexed_archive(b"entry")
  for cut = 0; cut < good.length(); cut = cut + 1 {
    match parse(good[:cut].to_owned()) {
      Ok(archive) => assert_eq(archive.member_count(), 0)
      Err(error) => assert_true(error.offset >= 0 && error.offset <= cut)
    }
  }
  assert_eq(
    error_code(
      b"!<arch>\n" +
      record("/", word(0, 4, false)) +
      record("/", word(0, 4, false)),
    ),
    "AR010",
  )
}

///|
test "returned symbol arrays cannot mutate the validated archive" {
  let archive = parsed(indexed_archive(b"entry"))
  let indexes = archive.symbol_indexes()
  indexes[0].symbols.clear()
  indexes.clear()
  assert_eq(archive.symbol_indexes()[0].symbols.length(), 1)
}

///|
test "BSD string references require entry boundaries and names are terminated" {
  // table header 8 + member header 60 + embedded name 9 + index payload 20 = 97,
  // odd stored size adds one outer padding byte: regular header starts at 98.
  let prefix = b"!<arch>\n"
  let suffix = record("a.o/", b"x")
  for name_index in [1, 4] {
    let body = word(8, 4, true) +
      word(name_index, 4, true) +
      word(98, 4, true) +
      word(4, 4, true) +
      b"abc\x00"
    assert_eq(
      error_code(prefix + record("#1/9", b"__.SYMDEF" + body) + suffix),
      "AR009",
    )
  }
  let body = word(8, 4, true) +
    word(0, 4, true) +
    word(98, 4, true) +
    word(4, 4, true) +
    b"abcd"
  assert_eq(
    error_code(prefix + record("#1/9", b"__.SYMDEF" + body) + suffix),
    "AR009",
  )
}

///|
test "repeated BSD symbol names count towards expanded name limits" {
  let body = word(16, 4, true) +
    (word(0, 4, true) + word(106, 4, true)).repeat(2) +
    word(4, 4, true) +
    b"abc\x00"
  let input = b"!<arch>\n" +
    record("#1/9", b"__.SYMDEF" + body) +
    record("a.o/", b"x")
  assert_true(
    parse(input, max_symbol_name_bytes=5) is Err({ code: "AR008", .. }),
  )
  assert_eq(parsed(input).symbol_indexes()[0].symbols.length(), 2)
}

///|
test "ambiguous BSD byte order is rejected instead of guessed" {
  // Palindromic size fields are valid in both byte orders; target fields point
  // to two different regular headers. Both interpretations are structurally valid.
  let table_bytes = 65792
  let body = word(table_bytes, 4, true) +
    (word(0, 4, true) + word(131840, 4, true)).repeat(table_bytes / 8) +
    word(65792, 4, true) +
    b"x\x00" +
    b"\x00".repeat(65790)
  let prefix = b"!<arch>\n" + record("#1/9", b"__.SYMDEF" + body)
  let input = prefix +
    record("gap/", b"\x00".repeat(131840 - prefix.length() - 60)) +
    record("first/", b"\x00".repeat(197120 - 131840 - 60)) +
    record("second/", b"")
  assert_eq(error_code(input), "AR010")
}

///|
test "mutating every byte of valid indexes never panics" {
  for bsd in [true, false] {
    let input = indexed_archive(b"entry", width=8, bsd~)
    for index = 0; index < input.length(); index = index + 1 {
      for replacement in [b'\x00', b'\xff'] {
        let changed = Bytes::makei(input.length(), fn(i) {
          if i == index {
            replacement
          } else {
            input[i]
          }
        })
        match parse(changed) {
          Ok(archive) =>
            for table in archive.symbol_indexes() {
              for symbol in table.symbols {
                assert_eq(archive.records[symbol.member_index].kind, Regular)
              }
            }
          Err(error) =>
            assert_true(error.offset >= 0 && error.offset <= input.length())
        }
      }
    }
  }
}

///|
test "SORTED indexes check name ordering in both widths" {
  for width in [4, 8] {
    let name = if width == 4 {
      "__.SYMDEF SORTED"
    } else {
      "__.SYMDEF_64 SORTED"
    }
    let header = "#1/\{name.length()}"
    let prefix = @utf8.encode(name)
    let target = 8 +
      record(header, prefix + b"\x00".repeat(width * 6 + 4)).length()
    let body = word(width * 4, width, true) +
      word(0, width, true) +
      word(target, width, true) +
      word(2, width, true) +
      word(target, width, true) +
      word(4, width, true)
    let bad = b"!<arch>\n" +
      record(header, prefix + body + b"z\x00a\x00") +
      record("a.o/", b"x")
    let good = b"!<arch>\n" +
      record(header, prefix + body + b"a\x00z\x00") +
      record("a.o/", b"x")
    assert_eq(error_code(bad), "AR009")
    assert_eq(parsed(good).symbol_indexes()[0].symbols.length(), 2)
  }
}

///|
test "BSD sorted indexes use unsigned byte lexical order across different name lengths" {
  for width in [4, 8] {
    for little in [false, true] {
      let name = if width == 4 {
        b"__.SYMDEF SORTED"
      } else {
        b"__.SYMDEF_64 SORTED"
      }
      let header = "#1/\{name.length()}"
      for
        (strings, second_name, valid) in [
          (b"aaaa\x00z\x00", 5, true),
          (b"z\x00aaaa\x00", 2, false),
        ] {
        let target = 8 +
          record(
            header,
            name + Bytes::make(width * 6 + strings.length(), b'\x00'),
          ).length()
        let body = word(width * 4, width, little) +
          word(0, width, little) +
          word(target, width, little) +
          word(second_name, width, little) +
          word(target, width, little) +
          word(strings.length(), width, little) +
          strings
        let input = b"!<arch>\n" +
          record(header, name + body) +
          record("a.o/", b"x")
        if valid {
          assert_true(parse(input) is Ok(_))
        } else {
          assert_true(parse(input) is Err({ code: "AR009", .. }))
        }
      }
    }
  }
}
