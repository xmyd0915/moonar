///|
fn object_fixture_put(data : Bytes, offset : Int, value : Bytes) -> Bytes {
  data[:offset].to_owned() + value + data[offset + value.length():].to_owned()
}

///|
fn object_fixture_elf(
  wide : Bool,
  little : Bool,
  extended? : Bool = false,
  second_table? : Bool = false,
) -> Bytes {
  let header_size = if wide { 64 } else { 52 }
  let section_size = if wide { 64 } else { 40 }
  let symbol_size = if wide { 24 } else { 16 }
  let width = if wide { 8 } else { 4 }
  let strings = b"\x00local\x00file\x00section\x00global\x00weak\x00common\x00absolute\x00undefined\x00"
  let string_offset = header_size + 1
  let symbol_offset = string_offset + strings.length()
  let specs = [
    (0, 0, 0),
    (1, 2, 1),
    (7, 4, 65521),
    (12, 3, 1),
    (20, 18, if extended { 65535 } else { 1 }),
    (27, 34, 1),
    (32, 17, 65522),
    (39, 16, 65521),
    (48, 18, 0),
  ]
  let mut symbols = b""
  for (name, info, section) in specs {
    let mut sym = Bytes::make(symbol_size, b'\x00')
    sym = object_fixture_put(sym, 0, word(name, 4, little))
    sym = object_fixture_put(
      sym,
      if wide {
        4
      } else {
        12
      },
      word(info, 1, little),
    )
    sym = object_fixture_put(
      sym,
      if wide {
        6
      } else {
        14
      },
      word(section, 2, little),
    )
    symbols += sym
  }
  let extra_offset = symbol_offset + symbols.length()
  let extra = if extended {
    Bytes::make(4 * 4, b'\x00') +
    word(1, 4, little) +
    Bytes::make(4 * 4, b'\x00')
  } else {
    b""
  }
  let section_offset = extra_offset + extra.length()
  let count = 4 +
    (if extended { 1 } else { 0 }) +
    (if second_table { 1 } else { 0 })
  let mut header = Bytes::make(header_size, b'\x00')
  header = object_fixture_put(header, 0, b"\x7fELF")
  header = object_fixture_put(
    header,
    4,
    word(if wide { 2 } else { 1 }, 1, little),
  )
  header = object_fixture_put(
    header,
    5,
    word(if little { 1 } else { 2 }, 1, little),
  )
  header = object_fixture_put(header, 6, b"\x01")
  header = object_fixture_put(header, 16, word(1, 2, little))
  header = object_fixture_put(
    header,
    18,
    word(if wide { 62 } else { 3 }, 2, little),
  )
  header = object_fixture_put(header, 20, word(1, 4, little))
  header = object_fixture_put(
    header,
    if wide {
      40
    } else {
      32
    },
    word(section_offset, width, little),
  )
  header = object_fixture_put(
    header,
    if wide {
      52
    } else {
      40
    },
    word(header_size, 2, little),
  )
  header = object_fixture_put(
    header,
    if wide {
      58
    } else {
      46
    },
    word(section_size, 2, little),
  )
  header = object_fixture_put(
    header,
    if wide {
      60
    } else {
      48
    },
    word(if extended { 0 } else { count }, 2, little),
  )
  let mut sections = b""
  let specs = [
    (0, 0, if extended { count } else { 0 }, 0, 0, 0),
    (1, header_size, 1, 0, 0, 0),
    (3, string_offset, strings.length(), 0, 0, 0),
    (2, symbol_offset, symbols.length(), 2, 4, symbol_size),
  ]
  let all_specs = specs.copy()
  if extended {
    all_specs.push((18, extra_offset, extra.length(), 3, 0, 4))
  }
  if second_table {
    all_specs.push((2, symbol_offset, symbols.length(), 2, 4, symbol_size))
  }
  for (kind, offset, size, link, info, stride) in all_specs {
    let mut section = Bytes::make(section_size, b'\x00')
    section = object_fixture_put(section, 4, word(kind, 4, little))
    section = object_fixture_put(
      section,
      if wide {
        24
      } else {
        16
      },
      word(offset, width, little),
    )
    section = object_fixture_put(
      section,
      if wide {
        32
      } else {
        20
      },
      word(size, width, little),
    )
    section = object_fixture_put(
      section,
      if wide {
        40
      } else {
        24
      },
      word(link, 4, little),
    )
    section = object_fixture_put(
      section,
      if wide {
        44
      } else {
        28
      },
      word(info, 4, little),
    )
    section = object_fixture_put(
      section,
      if wide {
        56
      } else {
        36
      },
      word(stride, width, little),
    )
    sections += section
  }
  header + b"\xc3" + strings + symbols + extra + sections
}

///|
fn object_fixture_macho(wide : Bool, little : Bool) -> Bytes {
  let header_size = if wide { 32 } else { 28 }
  let base = if wide { 72 } else { 56 }
  let section_size = if wide { 80 } else { 68 }
  let symbol_size = if wide { 16 } else { 12 }
  let width = if wide { 8 } else { 4 }
  let commands_size = base + section_size + 24
  let data_offset = header_size + commands_size
  let symbol_offset = data_offset + 1
  let specs = [
    (1, 14, 1, 0),
    (8, 15, 1, 0),
    (16, 15, 1, 0),
    (22, 1, 0, 4),
    (30, 3, 0, 42),
    (40, 1, 0, 0),
    (51, 11, 0, 8),
    (58, 225, 0, 0),
  ]
  let strings = b"\x00_local\x00_global\x00_weak\x00_common\x00_absolute\x00_undefined\x00_alias\x00_debug\x00"
  let mut symbols = b""
  for (name, kind, section, value) in specs {
    let mut sym = Bytes::make(symbol_size, b'\x00')
    sym = object_fixture_put(sym, 0, word(name, 4, little))
    sym = object_fixture_put(sym, 4, word(kind, 1, little))
    sym = object_fixture_put(sym, 5, word(section, 1, little))
    sym = object_fixture_put(sym, 8, word(value, width, little))
    if name == 16 {
      sym = object_fixture_put(sym, 6, word(128, 2, little))
    }
    symbols += sym
  }
  let mut header = Bytes::make(header_size, b'\x00')
  let magic = if wide {
    if little {
      b"\xcf\xfa\xed\xfe"
    } else {
      b"\xfe\xed\xfa\xcf"
    }
  } else if little {
    b"\xce\xfa\xed\xfe"
  } else {
    b"\xfe\xed\xfa\xce"
  }
  header = object_fixture_put(header, 0, magic)
  header = object_fixture_put(header, 12, word(1, 4, little))
  header = object_fixture_put(header, 16, word(2, 4, little))
  header = object_fixture_put(header, 20, word(commands_size, 4, little))
  let mut segment = Bytes::make(base + section_size, b'\x00')
  segment = object_fixture_put(
    segment,
    0,
    word(if wide { 25 } else { 1 }, 4, little),
  )
  segment = object_fixture_put(segment, 4, word(base + section_size, 4, little))
  segment = object_fixture_put(
    segment,
    if wide {
      40
    } else {
      32
    },
    word(data_offset, width, little),
  )
  segment = object_fixture_put(
    segment,
    if wide {
      48
    } else {
      36
    },
    word(1, width, little),
  )
  segment = object_fixture_put(
    segment,
    if wide {
      64
    } else {
      48
    },
    word(1, 4, little),
  )
  segment = object_fixture_put(
    segment,
    base + (if wide { 40 } else { 36 }),
    word(1, width, little),
  )
  segment = object_fixture_put(
    segment,
    base + (if wide { 48 } else { 40 }),
    word(data_offset, 4, little),
  )
  let symtab = word(2, 4, little) +
    word(24, 4, little) +
    word(symbol_offset, 4, little) +
    word(specs.length(), 4, little) +
    word(symbol_offset + symbols.length(), 4, little) +
    word(strings.length(), 4, little)
  header + segment + symtab + b"\xc3" + symbols + strings
}

///|
fn object_names(data : Bytes) -> Array[Bytes] raise {
  match symbols_from_object(data) {
    Ok(names) => names
    Err(error) => fail("\{error.code} at \{error.offset}: \{error.message}")
  }
}

///|
test "ELF symbol discovery handles both classes and endiannesses with external definition semantics" {
  for wide in [false, true] {
    for little in [false, true] {
      assert_eq(object_names(object_fixture_elf(wide, little)), [
        b"global", b"weak", b"common", b"absolute",
      ])
      assert_eq(object_names(object_fixture_elf(wide, little, extended=true)), [
        b"global", b"weak", b"common", b"absolute",
      ])
      assert_eq(
        object_names(object_fixture_elf(wide, little, second_table=true)),
        [b"global", b"weak", b"common", b"absolute"],
      )
    }
  }
}

///|
test "ELF symbol discovery validates linkage indices and strings before indexing" {
  let data = object_fixture_elf(true, true)
  let shoff = 64 + 1 + 58 + 9 * 24
  let symoff = 64 + 1 + 58
  for
    (pos, bytes) in [
      (40, b"\xff\xff\xff\xff\xff\xff\xff\xff"),
      (shoff + 3 * 64 + 40, word(1, 4, true)),
      (shoff + 3 * 64 + 56, word(0, 8, true)),
      (shoff + 3 * 64 + 44, word(6, 4, true)),
      (symoff + 4 * 24 + 6, word(99, 2, true)),
      (symoff + 4 * 24 + 6, word(65535, 2, true)),
      (symoff + 4 * 24, word(58, 4, true)),
      (64 + 58, b"x"),
    ] {
    assert_true(
      symbols_from_object(object_fixture_put(data, pos, bytes))
      is Err({ code: "OB001", .. }),
    )
  }
}

///|
test "ELF extended counts and SHN_XINDEX resolve actual sections beyond the 16-bit range" {
  let data = object_fixture_elf(true, true, extended=true)
  let shoff = 64 + 1 + 58 + 9 * 24 + 9 * 4
  let count = 65537
  let expanded = data +
    Bytes::make((count - 6) * 64, b'\x00') +
    data[shoff + 64:shoff + 128].to_owned()
  let expanded = object_fixture_put(expanded, shoff + 32, word(count, 8, true))
  let expanded = object_fixture_put(expanded, 62, word(65535, 2, true))
  let expanded = object_fixture_put(expanded, shoff + 40, word(2, 4, true))
  let expanded = object_fixture_put(
    expanded,
    64 + 1 + 58 + 9 * 24 + 4 * 4,
    word(65536, 4, true),
  )
  assert_eq(object_names(expanded), [b"global", b"weak", b"common", b"absolute"])
  let out_of_range = object_fixture_put(
    expanded,
    64 + 1 + 58 + 9 * 24 + 4 * 4,
    word(65537, 4, true),
  )
  assert_true(symbols_from_object(out_of_range) is Err({ code: "OB001", .. }))
}

///|
test "object discovery retains GNU unique hidden and suffix ELF names and private Mach-O definitions" {
  let elf = object_fixture_elf(true, true)
  let symoff = 64 + 1 + 58
  let unique = object_fixture_put(elf, symoff + 4 * 24 + 4, b"\xa1")
  let hidden = object_fixture_put(unique, symoff + 4 * 24 + 5, b"\x02")
  let suffix = object_fixture_put(hidden, symoff + 4 * 24, word(21, 4, true))
  assert_eq(object_names(suffix), [b"lobal", b"weak", b"common", b"absolute"])
  let macho = object_fixture_macho(true, true)
  let macho_symoff = 32 + 72 + 80 + 24 + 1
  assert_eq(
    object_names(object_fixture_put(macho, macho_symoff + 16 + 4, b"\x1f")),
    [b"_global", b"_weak", b"_common", b"_absolute", b"_alias"],
  )
}

///|
test "virtual uninitialized sections do not allocate or require bytes for their declared memory size" {
  let elf = object_fixture_elf(true, true)
  let shoff = 64 + 1 + 58 + 9 * 24
  let elf_bss = object_fixture_put(elf, shoff + 64 + 4, word(8, 4, true))
  let elf_bss = object_fixture_put(
    elf_bss,
    shoff + 64 + 32,
    b"\xff\xff\xff\xff\xff\xff\xff\xff",
  )
  assert_eq(object_names(elf_bss), [b"global", b"weak", b"common", b"absolute"])
  let macho = object_fixture_macho(true, true)
  let macho_bss = object_fixture_put(macho, 32 + 72 + 64, word(1, 4, true))
  let macho_bss = object_fixture_put(
    macho_bss,
    32 + 72 + 40,
    b"\xff\xff\xff\xff\xff\xff\xff\xff",
  )
  assert_eq(object_names(macho_bss), [
    b"_global", b"_weak", b"_common", b"_absolute", b"_alias",
  ])
  let coff = object_fixture_coff()
  let coff_bss = object_fixture_put(coff, 20 + 36, word(128, 4, true))
  let coff_bss = object_fixture_put(coff_bss, 20 + 20, word(0, 4, true))
  let coff_bss = object_fixture_put(coff_bss, 20 + 16, b"\xff\xff\xff\xff")
  assert_eq(object_names(coff_bss), [
    b"eightbyt", b"long_external_name", b"common", b"absolute", b"alias",
  ])
}

///|
test "Mach-O discovery includes defined weak common absolute and indirect exports" {
  for wide in [false, true] {
    for little in [false, true] {
      assert_eq(object_names(object_fixture_macho(wide, little)), [
        b"_global", b"_weak", b"_common", b"_absolute", b"_alias",
      ])
    }
  }
}

///|
test "Mach-O discovery honors section exclusion and rejects missing section and indirect names" {
  let data = object_fixture_macho(true, true)
  let symoff = 32 + 72 + 80 + 24 + 1
  assert_eq(
    object_names(object_fixture_put(data, 32 + 72 + 64, b"\x00\x00\x00\x40")),
    [b"_common", b"_absolute", b"_alias"],
  )
  for
    (pos, bytes) in [
      (32 + 4, word(8, 4, true)),
      (32 + 72 + 80, word(25, 4, true)),
      (symoff + 16 + 5, b"\x02"),
      (symoff + 6 * 16 + 8, word(0, 8, true)),
      (data.length() - 1, b"x"),
    ] {
    assert_true(
      symbols_from_object(object_fixture_put(data, pos, bytes))
      is Err({ code: "OB001", .. }),
    )
  }
}

///|
test "object discovery budgets bound filtered entries expanded names and complete builder" {
  let data = object_fixture_elf(true, true)
  assert_true(
    symbols_from_object(data, max_symbols=8) is Err({ code: "OB003", .. }),
  )
  assert_true(
    symbols_from_object(data, max_symbol_name_bytes=23)
    is Err({ code: "OB003", .. }),
  )
  assert_eq(
    symbols_from_object(data, max_symbols=9, max_symbol_name_bytes=24),
    Ok([b"global", b"weak", b"common", b"absolute"]),
  )
  let builder = writer_plan([
    WriteMember::new(b"readme", b"ordinary data"),
    WriteMember::new(b"first.o", data),
    WriteMember::new(b"second.o", data),
  ])
  let symbols = writer_ok(
    builder.discover_symbols(max_symbols=18, max_symbol_name_bytes=48),
  )
  assert_eq(symbols.length(), 8)
  assert_eq(symbols[0], { name: b"global", member_index: 1, })
  assert_eq(symbols[4], { name: b"global", member_index: 2, })
  assert_true(
    builder.discover_symbols(max_symbols=17)
    is Err({ code: "WR003", member_index: Some(2), .. }),
  )
  assert_true(
    builder.discover_symbols(max_symbol_name_bytes=47)
    is Err({ code: "WR003", member_index: Some(2), .. }),
  )
}

///|
test "recognized unsupported formats and broken object signatures cannot become an empty index" {
  for
    data in [
      b"BC\xc0\xde", b"\xde\xc0\x17\x0b", b"\xca\xfe\xba\xbe", b"\x00asm", b"!<arch>\n",
      b"!<thin>\n", b"\x00\x00\xff\xff",
    ] {
    assert_true(symbols_from_object(data) is Err({ code: "OB002", .. }))
  }
  assert_eq(object_names(b"ordinary text"), [])
  assert_eq(object_names(b""), [])
  assert_true(symbols_from_object(b"\x7fELF") is Err({ code: "OB001", .. }))
  assert_true(
    symbols_from_object(b"", max_symbols=-1) is Err({ code: "OB003", .. }),
  )
  let builder = writer_plan([WriteMember::new(b"broken.o", b"\x7fELF")])
  assert_true(
    builder.discover_symbols()
    is Err({ code: "WR006", member_index: Some(0), .. }),
  )
}

///|
fn object_fixture_coff() -> Bytes {
  let symbols : Array[Bytes] = []
  for
    (name, section, storage, value, auxiliary_count) in [
      (b".file\x00\x00\x00", 65534, 103, 0, 1),
      (b".text\x00\x00\x00", 1, 3, 0, 1),
      (b"eightbyt", 1, 2, 0, 0),
      (b"\x00\x00\x00\x00\x04\x00\x00\x00", 1, 2, 0, 0),
      (b"common\x00\x00", 0, 2, 4, 0),
      (b"absolute", 65535, 2, 23, 0),
      (b"undef\x00\x00\x00", 0, 2, 0, 0),
      (b"weakref\x00", 0, 105, 0, 1),
      (b"alias\x00\x00\x00", 0, 105, 0, 1),
    ] {
    symbols.push(
      name +
      word(value, 4, true) +
      word(section, 2, true) +
      word(0, 2, true) +
      word(storage, 1, true) +
      word(auxiliary_count, 1, true),
    )
    if auxiliary_count > 0 {
      symbols.push(
        if storage == 105 {
          word(4, 4, true) +
          word(if name == b"alias\x00\x00\x00" { 3 } else { 1 }, 4, true) +
          Bytes::make(10, b'\x00')
        } else {
          // Auxiliary bytes deliberately resemble an external definition.
          b"notasym\x00" +
          word(0, 4, true) +
          word(1, 2, true) +
          word(0, 2, true) +
          b"\x02\x00"
        },
      )
    }
  }
  let header = word(0x8664, 2, true) +
    word(1, 2, true) +
    word(0, 4, true) +
    word(61, 4, true) +
    word(symbols.length(), 4, true) +
    word(0, 2, true) +
    word(0, 2, true)
  let mut section = Bytes::make(40, b'\x00')
  section = object_fixture_put(section, 0, b".text")
  section = object_fixture_put(section, 16, word(1, 4, true))
  section = object_fixture_put(section, 20, word(60, 4, true))
  section = object_fixture_put(section, 36, word(0x20, 4, true))
  let names = b"long_external_name\x00"
  let mut bytes = header + section + b"\xc3"
  for symbol in symbols {
    bytes += symbol
  }
  bytes + word(4 + names.length(), 4, true) + names
}

///|
test "COFF discovery finds short long common absolute and alias names without exposing auxiliary records" {
  for machine in [0x014c, 0x8664, 0x01c4, 0xaa64, 0x5064] {
    let data = object_fixture_put(
      object_fixture_coff(),
      0,
      word(machine, 2, true),
    )
    assert_eq(object_names(data), [
      b"eightbyt", b"long_external_name", b"common", b"absolute", b"alias",
    ])
  }
}

///|
test "COFF discovery rejects truncated tables invalid auxiliary references and unknown object variants" {
  let data = object_fixture_coff()
  for
    (pos, bytes) in [
      (8, word(20, 4, true)),
      (12, b"\xff\xff\xff\xff"),
      (61 + 17, b"\xff"),
      (61 + 5 * 18 + 4, word(1, 4, true)),
      (61 + 4 * 18 + 12, word(2, 2, true)),
      (61 + 10 * 18, word(1, 4, true)),
      (data.length() - 1, b"x"),
    ] {
    assert_true(
      symbols_from_object(object_fixture_put(data, pos, bytes))
      is Err({ code: "OB001", .. }),
    )
  }
  assert_true(
    symbols_from_object(data, max_symbols=12) is Err({ code: "OB003", .. }),
  )
  assert_true(
    symbols_from_object(data, max_symbol_name_bytes=43)
    is Err({ code: "OB003", .. }),
  )
  assert_true(
    symbols_from_object(object_fixture_put(data, 16, word(224, 2, true)))
    is Err({ code: "OB002", .. }),
  )
  for cut = 4; cut < data.length(); cut = cut + 1 {
    assert_true(symbols_from_object(data[:cut].to_owned()) is Err(_))
  }
  for pos = 4; pos < data.length(); pos = pos + 1 {
    match symbols_from_object(object_fixture_put(data, pos, b"\xff")) {
      Ok(names) => assert_true(names.length() <= 13)
      Err(error) => assert_true(error.code == "OB001" || error.code == "OB002")
    }
  }
}

///|
test "object discovery remains bounded for truncated and byte-mutated ELF and Mach-O inputs" {
  for wide in [false, true] {
    for little in [false, true] {
      for
        input in [
          object_fixture_elf(wide, little),
          object_fixture_macho(wide, little),
        ] {
        for cut = 4; cut < input.length(); cut = cut + 1 {
          assert_true(symbols_from_object(input[:cut].to_owned()) is Err(_))
        }
        for pos = 4; pos < input.length(); pos = pos + 1 {
          let changed = object_fixture_put(input, pos, b"\xff")
          match
            symbols_from_object(
              changed,
              max_symbols=100,
              max_symbol_name_bytes=1024,
            ) {
            Ok(names) => assert_true(names.length() <= 100)
            Err(error) =>
              assert_true(
                error.code == "OB001" ||
                error.code == "OB002" ||
                error.code == "OB003",
              )
          }
        }
      }
    }
  }
}
