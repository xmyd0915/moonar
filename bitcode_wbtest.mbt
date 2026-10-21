///|
priv struct BitcodeFixture {
  buffer : @buffer.Buffer
  mut byte : Int
  mut bits : Int
}

///|
fn BitcodeFixture::put(
  self : BitcodeFixture,
  value : UInt64,
  width : Int,
) -> Unit {
  for i in 0..<width {
    self.byte = self.byte | (((value >> i) & 1UL).to_int() << self.bits)
    self.bits += 1
    if self.bits == 8 {
      self.buffer.write_byte(self.byte.to_byte())
      self.bits = 0
      self.byte = 0
    }
  }
}

///|
fn BitcodeFixture::vbr(
  self : BitcodeFixture,
  input : UInt64,
  width : Int,
) -> Unit {
  let mut value = input
  let mask = (1UL << (width - 1)) - 1UL
  while value > mask {
    self.put((value & mask) | (1UL << (width - 1)), width)
    value = value >> (width - 1)
  }
  self.put(value, width)
}

///|
fn BitcodeFixture::align(self : BitcodeFixture) -> Unit {
  if self.bits > 0 {
    self.put(0UL, 8 - self.bits)
  }
  while self.buffer.length() % 4 != 0 {
    self.put(0UL, 8)
  }
}

///|
fn bc_fixture() -> BitcodeFixture {
  { buffer: @buffer.Buffer(), byte: 0, bits: 0, }
}

///|
fn bc_fixture_block(id : Int, body : Bytes) -> Bytes {
  let output = bc_fixture()
  output.put(1UL, 2)
  output.vbr(id.to_uint64(), 8)
  output.vbr(3UL, 4)
  output.align()
  output.put((body.length() / 4).to_uint64(), 32)
  output.buffer.write_bytes(body[:])
  output.buffer.to_bytes()
}

///|
fn bc_fixture_blob(blob : Bytes, code_encoding? : Int = 0) -> Bytes {
  let output = bc_fixture()
  output.put(2UL, 3)
  output.vbr(2UL, 5)
  if code_encoding == 0 {
    output.put(1UL, 1)
    output.vbr(1UL, 8)
  } else {
    output.put(0UL, 1)
    output.put(code_encoding.to_uint64(), 3)
    output.vbr(6UL, 5)
  }
  output.put(0UL, 1)
  output.put(5UL, 3)
  output.put(4UL, 3)
  if code_encoding == 1 {
    output.put(1UL, 6)
  } else if code_encoding == 2 {
    output.vbr(1UL, 6)
  }
  output.vbr(blob.length().to_uint64(), 6)
  output.align()
  output.buffer.write_bytes(blob[:])
  output.align()
  output.put(0UL, 3)
  output.align()
  output.buffer.to_bytes()
}

///|
fn bc_fixture_table(names : Array[Bytes], flags : Array[Int]) -> (Bytes, Bytes) {
  let strings = @buffer.Buffer()
  let symbols = @buffer.Buffer()
  let mut uncommon = 0
  for i, name in names {
    symbols.write_int_le(strings.length())
    symbols.write_int_le(name.length())
    symbols.write_int_le(strings.length())
    symbols.write_int_le(name.length())
    symbols.write_int_le(-1)
    symbols.write_int_le(flags[i])
    strings.write_bytes(name[:])
    if (flags[i] & 4) != 0 {
      uncommon += 1
    }
  }
  let mut header = Bytes::make(76, b'\x00')
  header = object_fixture_put(header, 0, word(3, 4, true))
  header = object_fixture_put(header, 12, word(76, 4, true) + word(1, 4, true))
  header = object_fixture_put(header, 20, word(88, 4, true))
  header = object_fixture_put(
    header,
    28,
    word(88, 4, true) + word(names.length(), 4, true),
  )
  header = object_fixture_put(
    header,
    36,
    word(88 + names.length() * 24, 4, true) + word(uncommon, 4, true),
  )
  let modules = word(0, 4, true) +
    word(names.length(), 4, true) +
    word(0, 4, true)
  (
    header + modules + symbols.to_bytes() + Bytes::make(uncommon * 24, b'\x00'),
    strings.to_bytes(),
  )
}

///|
fn bc_fixture_file(
  table : Bytes,
  strings : Bytes,
  code_encoding? : Int = 0,
) -> Bytes {
  b"BC\xc0\xde" +
  bc_fixture_block(8, b"\x00\x00\x00\x00") +
  bc_fixture_block(25, bc_fixture_blob(table, code_encoding~)) +
  bc_fixture_block(23, bc_fixture_blob(strings, code_encoding~))
}

///|
test "LLVM summary definitions include weak common and aliases while filtering local and undefined symbols" {
  let (table, strings) = bc_fixture_table(
    [
      b"entry", b"undefined", b"weak", b"common", b"local", b"format", b"entry",
      b"alias",
    ],
    [1024, 1032, 16, 1060, 0, 3072, 1024, 1088],
  )
  for code_encoding in [0, 1, 2] {
    let data = bc_fixture_file(table, strings, code_encoding~)
    assert_eq(object_names(data), [b"entry", b"weak", b"common", b"alias"])
    assert_true(
      symbols_from_object(data, max_symbols=7) is Err({ code: "OB003", .. }),
    )
    assert_true(
      symbols_from_object(data, max_symbol_name_bytes=24)
      is Err({ code: "OB003", .. }),
    )
    assert_true(
      symbols_from_object(data, max_symbols=8, max_symbol_name_bytes=25)
      is Ok(_),
    )
  }
}

///|
test "LLVM wrapper offsets and concatenated module groups preserve full names and shared budgets" {
  let (table, strings) = bc_fixture_table([b"entry"], [1024])
  let data = bc_fixture_file(table, strings)
  for offset in [20, 21, 24] {
    let wrapper = b"\xde\xc0\x17\x0b" +
      word(0, 4, true) +
      word(offset, 4, true) +
      word(data.length(), 4, true) +
      word(7, 4, true)
    let wrapped = wrapper +
      Bytes::make(offset - 20, b'\x00') +
      data +
      Bytes::make(11, b'\x00')
    assert_eq(object_names(wrapped), [b"entry"])
  }
  let combined = data + data[4:].to_owned()
  assert_eq(object_names(combined), [b"entry"])
  assert_true(
    symbols_from_object(combined, max_symbols=1) is Err({ code: "OB003", .. }),
  )
  assert_true(
    symbols_from_object(combined, max_symbol_name_bytes=9)
    is Err({ code: "OB003", .. }),
  )
  assert_eq(object_names(data + b"\n\n\n\n"), [b"entry"])
}

///|
test "LLVM summary references flags and partitions must be internally consistent" {
  let (table, strings) = bc_fixture_table([b"entry"], [1024])
  for
    (field, value) in [
      (12, 0),
      (16, 2),
      (28, 84),
      (32, 1000),
      (76, 1),
      (80, 0),
      (84, 1),
      (88, 100),
      (92, 100),
      (104, 0),
      (108, 1027),
    ] {
    let altered = object_fixture_put(table, field, word(value, 4, true))
    assert_true(
      symbols_from_object(bc_fixture_file(altered, strings)) is Err(_),
    )
  }
  let extra_flags = object_fixture_put(table, 108, word(16384, 4, true))
  assert_true(
    symbols_from_object(bc_fixture_file(extra_flags, strings))
    is Err({ code: "OB002", .. }),
  )
  assert_true(
    symbols_from_object(bc_fixture_file(table, b"en\x00ry"))
    is Err({ code: "OB001", .. }),
  )
  let version = object_fixture_put(table, 0, word(4, 4, true))
  assert_true(
    symbols_from_object(bc_fixture_file(version, strings))
    is Err({ code: "OB002", .. }),
  )
}

///|
test "LLVM containers reject truncation missing summaries and malformed wrapper envelopes" {
  let (table, strings) = bc_fixture_table([b"entry"], [1024])
  let data = bc_fixture_file(table, strings)
  for end in 4..<data.length() {
    assert_true(symbols_from_object(data[:end].to_owned()) is Err(_))
  }
  assert_true(
    symbols_from_object(
      b"BC\xc0\xde" + bc_fixture_block(8, b"\x00\x00\x00\x00"),
    )
    is Err({ code: "OB002", .. }),
  )
  for
    bytes in [
      b"\xde\xc0\x17\x0b",
      b"\xde\xc0\x17\x0b" + Bytes::make(16, b'\x00'),
    ] {
    assert_true(symbols_from_object(bytes) is Err({ code: "OB001", .. }))
  }
  for i in 0..<data.length() {
    let altered = Bytes::makei(data.length(), fn(j) {
      if i == j {
        b'\xff'
      } else {
        data[j]
      }
    })
    ignore(
      symbols_from_object(
        altered,
        max_symbols=1000,
        max_symbol_name_bytes=10000,
      ),
    )
  }
}

///|
test "bitcode cursor validates wide integers arrays and hostile abbreviations without expansion" {
  let output = bc_fixture()
  output.vbr(0xffffffffffffffffUL, 6)
  output.align()
  let data = output.buffer.to_bytes()
  let cursor : BitcodeCursor = {
    data,
    origin: 0,
    end: data.length(),
    byte: 0,
    bit: 0,
  }
  assert_eq(cursor.vbr(6), 0xffffffffffffffffUL)
  let bad : BitcodeCursor = {
    data: Bytes::make(16, b'\xff'),
    origin: 0,
    end: 16,
    byte: 0,
    bit: 0,
  }
  try {
    ignore(bad.vbr(6))
    fail("expected VBR overflow")
  } catch {
    InvalidObject(_) => ()
    error => raise error
  }
  let output = bc_fixture()
  output.vbr(2147483647UL, 6)
  output.align()
  let data = output.buffer.to_bytes()
  let cursor : BitcodeCursor = {
    data,
    origin: 0,
    end: data.length(),
    byte: 0,
    bit: 0,
  }
  assert_eq(cursor.record([Literal(2UL), ArrayField, Fixed(0)]), (2UL, None))
  let cursor : BitcodeCursor = {
    data,
    origin: 0,
    end: data.length(),
    byte: 0,
    bit: 0,
  }
  try {
    ignore(cursor.record([Literal(2UL), ArrayField, Char6]))
    fail("expected array bounds error")
  } catch {
    InvalidObject(_) => ()
    error => raise error
  }
}

///|
test "bitcode summaries bound abbreviation definitions before allocating expanded records" {
  for count in [0, 65] {
    let output = bc_fixture()
    output.vbr(count.to_uint64(), 5)
    output.align()
    let data = output.buffer.to_bytes()
    let cursor : BitcodeCursor = {
      data,
      origin: 0,
      byte: 0,
      bit: 0,
      end: data.length(),
    }
    try {
      ignore(cursor.abbreviation())
      fail("expected abbreviation error")
    } catch {
      InvalidObject(_) => ()
      error => raise error
    }
  }
  let output = bc_fixture()
  for _ in 0..<257 {
    output.put(2UL, 3)
    output.vbr(2UL, 5)
    output.put(1UL, 1)
    output.vbr(1UL, 8)
    output.put(0UL, 1)
    output.put(5UL, 3)
  }
  output.align()
  let data = output.buffer.to_bytes()
  try {
    ignore(bitcode_blob(data, 0, 0, data.length(), 3))
    fail("expected abbreviation count error")
  } catch {
    InvalidObject({ code: "OB003", .. }) => ()
    error => raise error
  }
}

///|
test "bitcode uncommon entries check flags alignment and string ranges" {
  let (table, strings) = bc_fixture_table([b"common"], [1060])
  for (field, value) in [(116, 3), (120, 100), (132, 100), (108, 1024)] {
    let broken = object_fixture_put(table, field, word(value, 4, true))
    assert_true(
      symbols_from_object(bc_fixture_file(broken, strings))
      is Err({ code: "OB001", .. }),
    )
  }
  let unknown = object_fixture_put(table, 40, word(0, 4, true))
  assert_true(
    symbols_from_object(bc_fixture_file(unknown, strings))
    is Err({ code: "OB001", .. }),
  )
}
