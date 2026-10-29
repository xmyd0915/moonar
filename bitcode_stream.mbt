///|
// Only top-level block envelopes and summary blobs are decoded. IR bodies are
// skipped by their declared word length, so discovery does not construct IR.
priv struct BitcodeCursor {
  data : Bytes
  end : Int32
  origin : Int32
  mut byte : Int32
  mut bit : Int32
}

///|
fn BitcodeCursor::fixed(
  self : BitcodeCursor,
  width : Int32,
) -> UInt64 raise InvalidObject {
  let mut value = 0UL
  for i in 0..<width {
    if self.byte >= self.end {
      object_reject("OB001", self.byte, "truncated bitcode field")
    }
    value = value |
      (((self.data[self.byte].to_uint64() >> self.bit) & 1UL) << i)
    self.bit += 1
    if self.bit == 8 {
      self.bit = 0
      self.byte += 1
    }
  }
  value
}

///|
fn BitcodeCursor::vbr(
  self : BitcodeCursor,
  width : Int32,
) -> UInt64 raise InvalidObject {
  let start = self.byte
  let mut value = 0UL
  let mut shift = 0
  let mask = (1UL << (width - 1)) - 1UL
  while shift < 64 {
    let group = self.fixed(width)
    let payload = group & mask
    if payload > 0xffffffffffffffffUL >> shift {
      object_reject("OB001", start, "bitcode VBR integer overflow")
    }
    value = value | (payload << shift)
    if group >> (width - 1) == 0UL {
      return value
    }
    shift += width - 1
  }
  object_reject("OB001", start, "unterminated bitcode VBR integer")
}

///|
fn BitcodeCursor::number(
  self : BitcodeCursor,
  width : Int32,
  maximum : Int32,
) -> Int32 raise InvalidObject {
  let start = self.byte
  let value = self.vbr(width)
  if value > maximum.to_uint64() {
    object_reject("OB001", start, "bitcode integer exceeds its permitted range")
  }
  value.to_int()
}

///|
fn BitcodeCursor::align(self : BitcodeCursor) -> Unit raise InvalidObject {
  if self.bit != 0 {
    if self.byte >= self.end ||
      self.data[self.byte].to_uint64() >> self.bit != 0UL {
      object_reject("OB001", self.byte, "invalid bitcode alignment bits")
    }
    self.bit = 0
    self.byte += 1
  }
  while (self.byte - self.origin) % 4 != 0 {
    if self.byte >= self.end || self.data[self.byte] != b'\x00' {
      object_reject("OB001", self.byte, "invalid bitcode alignment bytes")
    }
    self.byte += 1
  }
}

///|
fn BitcodeCursor::skip(
  self : BitcodeCursor,
  count : Int32,
  width : Int32,
) -> Unit raise InvalidObject {
  let bits = count.to_uint64() * width.to_uint64()
  let available = (self.end - self.byte).to_uint64() * 8UL -
    self.bit.to_uint64()
  if bits > available {
    object_reject("OB001", self.byte, "bitcode field extends beyond its block")
  }
  let position = self.bit.to_uint64() + bits
  self.byte += (position >> 3).to_int()
  self.bit = (position & 7UL).to_int()
}

///|
fn BitcodeCursor::block(
  self : BitcodeCursor,
) -> (Int32, Int32, Int32) raise InvalidObject {
  let id = self.number(8, 2147483647)
  let width = self.number(4, 32)
  if width < 2 {
    object_reject(
      "OB001",
      self.byte,
      "bitcode block code width must be between 2 and 32",
    )
  }
  self.align()
  let length = self.fixed(32)
  if length > ((self.end - self.byte) / 4).to_uint64() {
    object_reject(
      "OB001",
      self.byte,
      "bitcode block extends beyond its container",
    )
  }
  (id, width, self.byte + length.to_int() * 4)
}

///|
priv enum BitcodeOperand {
  Literal(UInt64)
  Fixed(Int32)
  Vbr(Int32)
  ArrayField
  Char6
  Blob
}

///|
fn BitcodeCursor::abbreviation(
  self : BitcodeCursor,
) -> Array[BitcodeOperand] raise InvalidObject {
  let count = self.number(5, 2147483647)
  if count == 0 {
    object_reject("OB001", self.byte, "empty bitcode abbreviation")
  }
  if count > 64 {
    object_reject(
      "OB003",
      self.byte,
      "bitcode summary abbreviation operand limit exceeded",
    )
  }
  let result : Array[BitcodeOperand] = []
  for _ in 0..<count {
    if self.fixed(1) == 1UL {
      result.push(Literal(self.vbr(8)))
      continue
    }
    let kind = self.fixed(3).to_int()
    result.push(
      match kind {
        1 => Fixed(self.number(5, 32))
        2 => {
          let width = self.number(5, 32)
          if width < 2 {
            object_reject("OB001", self.byte, "invalid bitcode VBR width")
          }
          Vbr(width)
        }
        3 => ArrayField
        4 => Char6
        5 => Blob
        _ =>
          object_reject(
            "OB001",
            self.byte,
            "unknown bitcode abbreviation encoding",
          )
      },
    )
  }
  if result[0] is (ArrayField | Char6 | Blob) {
    object_reject("OB001", self.byte, "invalid bitcode record-code encoding")
  }
  for i, operand in result {
    match operand {
      Blob =>
        if i != count - 1 {
          object_reject(
            "OB001",
            self.byte,
            "bitcode blob must end an abbreviation",
          )
        }
      ArrayField => {
        if i != count - 2 {
          object_reject(
            "OB001",
            self.byte,
            "bitcode array must end an abbreviation",
          )
        }
        if !(result[i + 1] is (Fixed(_) | Vbr(_) | Char6)) {
          object_reject(
            "OB001",
            self.byte,
            "invalid bitcode array element encoding",
          )
        }
      }
      _ => ()
    }
  }
  result
}

///|
fn BitcodeCursor::scalar(
  self : BitcodeCursor,
  operand : BitcodeOperand,
) -> UInt64 raise InvalidObject {
  match operand {
    Literal(value) => value
    Fixed(width) => self.fixed(width)
    Vbr(width) => self.vbr(width)
    Char6 => self.fixed(6)
    _ => object_reject("OB001", self.byte, "invalid scalar bitcode operand")
  }
}

///|
fn BitcodeCursor::record(
  self : BitcodeCursor,
  definition : Array[BitcodeOperand],
) -> (UInt64, (Int32, Int32)?) raise InvalidObject {
  let code = self.scalar(definition[0])
  let mut blob : (Int32, Int32)? = None
  let mut i = 1
  while i < definition.length() {
    match definition[i] {
      Blob => {
        let size = self.number(6, self.end - self.byte)
        self.align()
        if size > self.end - self.byte {
          object_reject("OB001", self.byte, "truncated bitcode blob")
        }
        blob = Some((self.byte, size))
        self.byte += size
        self.align()
      }
      ArrayField => {
        let count = self.number(6, 2147483647)
        match definition[i + 1] {
          Fixed(width) => self.skip(count, width)
          Char6 => self.skip(count, 6)
          Vbr(width) => {
            // Each value consumes at least width bits, even when it is zero.
            if count.to_uint64() * width.to_uint64() >
              (self.end - self.byte).to_uint64() * 8UL - self.bit.to_uint64() {
              object_reject(
                "OB001",
                self.byte,
                "bitcode array exceeds its block",
              )
            }
            for _ in 0..<count {
              ignore(self.vbr(width))
            }
          }
          _ =>
            object_reject("OB001", self.byte, "invalid bitcode array encoding")
        }
        i += 1
      }
      operand => ignore(self.scalar(operand))
    }
    i += 1
  }
  (code, blob)
}

///|
fn BitcodeCursor::unabbreviated(
  self : BitcodeCursor,
) -> UInt64 raise InvalidObject {
  let code = self.vbr(6)
  let count = self.number(6, 2147483647)
  if count.to_uint64() * 6UL >
    (self.end - self.byte).to_uint64() * 8UL - self.bit.to_uint64() {
    object_reject("OB001", self.byte, "bitcode record exceeds its block")
  }
  for _ in 0..<count {
    ignore(self.vbr(6))
  }
  code
}

///|
fn bitcode_blob(
  data : Bytes,
  origin : Int32,
  start : Int32,
  end : Int32,
  width : Int32,
) -> (Int32, Int32) raise InvalidObject {
  let cursor : BitcodeCursor = { data, origin, byte: start, bit: 0, end, }
  let definitions : Array[Array[BitcodeOperand]] = []
  let mut blob : (Int32, Int32)? = None
  while cursor.byte < end {
    match cursor.fixed(width).to_int() {
      0 => {
        cursor.align()
        if cursor.byte != end {
          object_reject(
            "OB001",
            cursor.byte,
            "bitcode block ended before its declared length",
          )
        }
        guard blob is Some(value) else {
          object_reject("OB001", start, "bitcode summary block has no blob")
        }
        return value
      }
      1 => {
        let (_, _, child_end) = cursor.block()
        cursor.byte = child_end
      }
      2 => {
        if definitions.length() == 256 {
          object_reject(
            "OB003",
            cursor.byte,
            "bitcode summary abbreviation count limit exceeded",
          )
        }
        definitions.push(cursor.abbreviation())
      }
      3 =>
        if cursor.unabbreviated() == 1UL {
          object_reject(
            "OB001",
            cursor.byte,
            "bitcode summary requires a blob record",
          )
        }
      id => {
        guard definitions.get(id - 4) is Some(definition) else {
          object_reject(
            "OB002",
            cursor.byte,
            "bitcode summary uses an unavailable abbreviation",
          )
        }
        let (code, value) = cursor.record(definition)
        if code == 1UL {
          if blob is Some(_) || value is None {
            object_reject(
              "OB001",
              cursor.byte,
              "missing or duplicate bitcode summary blob",
            )
          }
          blob = value
        }
      }
    }
  }
  object_reject("OB001", end, "bitcode summary block has no end marker")
}
