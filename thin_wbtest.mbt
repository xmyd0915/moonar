///|
fn thin_header(name : String, size : Int) -> Bytes {
  @utf8.encode(
    field(name, 16) +
    field("0", 12) +
    field("0", 6) +
    field("0", 6) +
    field("644", 8) +
    field(size.to_string(), 10) +
    "`\n",
  )
}

///|
fn thin_parsed(input : Bytes) -> ThinArchive raise {
  match parse_thin(input) {
    Ok(archive) => archive
    Err(error) => fail("\{error.code} at \{error.offset}: \{error.message}")
  }
}

///|
fn thin_with_path(path : Bytes, size? : Int = 3) -> ThinArchive raise {
  thin_parsed(
    b"!<thin>\n" + record("//", path + b"/\n") + thin_header("/0", size),
  )
}

///|
fn thin_indexed(width : Int, delta? : Int = 0) -> Bytes {
  let index_name = if width == 4 { "/" } else { "/SYM64/" }
  let names = record("//", b"directory/long_member.o/\n")
  let index_size = width * 2 + 6
  let target = 8 +
    record(index_name, Bytes::make(index_size, b'\x00')).length() +
    names.length() +
    delta
  b"!<thin>\n" +
  record(
    index_name,
    word(1, width, false) + word(target, width, false) + b"entry\x00",
  ) +
  names +
  thin_header("/0", 17)
}

///|
test "thin archives retain external headers without advancing over payloads" {
  let input = b"!<thin>\n" + thin_header("a.o/", 3) + thin_header("b.o/", 200)
  let archive = thin_parsed(input)
  assert_eq(archive.byte_length(), 128)
  assert_eq(archive.member_count(), 2)
  assert_eq(archive.get_member(0).unwrap().name, b"a.o")
  assert_eq(archive.get_member(0).unwrap().size, 3)
  assert_eq(archive.get_member(1).unwrap().header_offset, 68)
  assert_eq(archive.get_member(1).unwrap().size, 200)
  assert_eq(archive.inline_bytes(0), None)
  assert_eq(archive.get_member(-1), None)
  assert_eq(archive.inline_bytes(4), None)
  assert_true(parse(input) is Err({ code: "AR007", .. }))
  assert_true(parse_thin(b"!<arch>\n") is Err({ code: "AR001", .. }))
  assert_eq(thin_parsed(b"!<thin>\n").member_count(), 0)
}

///|
test "thin GNU32 and GNU64 indexes target physical external member records" {
  for width in [4, 8] {
    let archive = thin_parsed(thin_indexed(width))
    let index = archive.symbol_indexes()[0]
    assert_eq(index.format, if width == 4 { "gnu32" } else { "gnu64" })
    assert_eq(index.symbols[0].name, b"entry")
    assert_eq(index.symbols[0].member_index, 2)
    assert_eq(archive.get_member(2).unwrap().name, b"directory/long_member.o")
    assert_eq(archive.get_member(2).unwrap().kind, Regular)
    assert_eq(archive.inline_bytes(1), Some(b"directory/long_member.o/\n"))
    index.symbols.clear()
    assert_eq(archive.symbol_indexes()[0].symbols.length(), 1)
    assert_true(
      parse_thin(thin_indexed(width, delta=1)) is Err({ code: "AR009", .. }),
    )
    assert_true(
      parse_thin(thin_indexed(width, delta=60)) is Err({ code: "AR009", .. }),
    )
    assert_true(
      parse_thin(thin_indexed(width), max_symbols=0)
      is Err({ code: "AR008", .. }),
    )
    assert_true(
      parse_thin(thin_indexed(width), max_symbol_name_bytes=4)
      is Err({ code: "AR008", .. }),
    )
  }
}

///|
test "thin references resolve name boundaries and retain external special-looking names" {
  let archive = thin_with_path(b"__.SYMDEF")
  assert_eq(archive.get_member(1).unwrap().kind, Regular)
  assert_eq(archive.symbol_indexes().length(), 0)
  assert_eq(archive.member_path(1), Ok(b"__.SYMDEF"))
  let forward = thin_parsed(
    b"!<thin>\n" + thin_header("/0", 0) + record("//", b"a/\n"),
  )
  assert_eq(forward.get_member(0).unwrap().name, b"a")
  for reference in ["/1", "/100", "/ 0", "/x"] {
    assert_true(
      parse_thin(
        b"!<thin>\n" + record("//", b"abc/\n") + thin_header(reference, 0),
      )
      is Err({ code: "AR006", .. }),
    )
  }
  assert_true(
    parse_thin(b"!<thin>\n" + thin_header("/0", 0))
    is Err({ code: "AR006", .. }),
  )
  assert_true(
    parse_thin(b"!<thin>\n" + record("//", b"a/\n") + record("//", b"b/\n"))
    is Err({ code: "AR006", .. }),
  )
}

///|
test "thin unsupported encodings and malformed inline data fail explicitly" {
  for name in ["#1/8"] {
    assert_true(
      parse_thin(b"!<thin>\n" + thin_header(name, 20))
      is Err({ code: "AR011", .. }),
    )
  }
  assert_true(parse_thin(b"!<thin>\npartial") is Err({ code: "AR002", .. }))
  assert_true(
    parse_thin(b"!<thin>\n" + thin_header("//", 100) + b"x")
    is Err({ code: "AR002", .. }),
  )
  let odd_table = b"!<thin>\n" + record("//", b"a/\n")
  assert_true(
    parse_thin(odd_table[:odd_table.length() - 1].to_owned())
    is Err({ code: "AR003", .. }),
  )
  assert_true(
    parse_thin(
      b"!<thin>\n" +
      record("/", word(0, 4, false)) +
      record("/", word(0, 4, false)),
    )
    is Err({ code: "AR010", .. }),
  )
}

///|
test "thin parse budgets include special records and expanded path bytes" {
  let input = b"!<thin>\n" +
    record("//", b"long/path.o/\n") +
    thin_header("/0", 99999999) +
    thin_header("/0", 99999999)
  assert_true(parse_thin(input, max_members=2) is Err({ code: "AR008", .. }))
  assert_true(
    parse_thin(input, max_name_bytes=23) is Err({ code: "AR008", .. }),
  )
  assert_true(
    parse_thin(input, max_name_bytes=24, max_bytes=input.length()) is Ok(_),
  )
  assert_true(
    parse_thin(input, max_bytes=input.length() - 1)
    is Err({ code: "AR008", .. }),
  )
  assert_true(
    parse_thin(input, max_name_bytes=-1) is Err({ code: "AR008", .. }),
  )
}

///|
test "thin loading normalizes relative paths and validates callback data" {
  let archive = thin_with_path(b"./objects//a.o")
  assert_eq(archive.member_path(1), Ok(b"objects/a.o"))
  let calls : Array[(Bytes, Int)] = []
  let loaded = archive.load_member(1, fn(path, limit) {
    calls.push((path, limit))
    Ok(b"abc")
  })
  assert_eq(loaded, Ok(b"abc"))
  assert_eq(calls, [(b"objects/a.o", 3)])
  assert_true(
    archive.load_member(1, (_, _) => Err("missing file"))
    is Err({ code: "AR013", .. }),
  )
  assert_true(
    archive.load_member(1, (_, _) => Ok(b"ab")) is Err({ code: "AR014", .. }),
  )
  assert_true(
    archive.load_member(1, (_, _) => Ok(b"abcd")) is Err({ code: "AR014", .. }),
  )
  assert_true(
    archive.load_member(1, (_, _) => Ok(b"abcd"), max_bytes=3)
    is Err({ code: "AR008", .. }),
  )
  assert_true(
    archive.load_member(1, (_, _) => Ok(b""), max_bytes=-1)
    is Err({ code: "AR008", .. }),
  )
  assert_true(archive.member_path(0) is Err({ code: "AR011", .. }))
  assert_true(archive.member_path(-1) is Err({ code: "AR011", .. }))
  assert_eq(
    thin_with_path(b"empty", size=0).load_member(
      1,
      (_, _) => Ok(b""),
      max_bytes=0,
    ),
    Ok(b""),
  )
}

///|
test "thin unsafe paths and oversized declarations never reach the loader" {
  let calls : Array[Unit] = []
  let loader = fn(_path : Bytes, _limit : Int) -> Result[Bytes, String] {
    calls.push(())
    Ok(b"abc")
  }
  for
    path in [
      b"../a.o", b"a/../b.o", b"/absolute/a.o", b"C:/a.o", b"//server/share/a.o",
      b"a\\b.o", b"a.o:stream", b"./", b"objects/a.o/", b"objects/a.o/.",
    ] {
    let archive = thin_with_path(path)
    assert_true(archive.load_member(1, loader) is Err({ code: "AR012", .. }))
    assert_eq(archive.get_member(1).unwrap().name, path)
  }
  let archive = thin_with_path(b"huge.o", size=99999999)
  assert_true(archive.load_member(1, loader) is Err({ code: "AR008", .. }))
  assert_eq(calls.length(), 0)
}
