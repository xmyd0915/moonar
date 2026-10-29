///|
fn bitcode_table_range(
  data : Bytes,
  start : Int32,
  size : Int32,
  field : Int32,
  stride : Int32,
) -> (Int32, Int32) raise InvalidObject {
  let offset = object_number(data, start + field, 4, true, size)
  let count = object_number(
    data,
    start + field + 4,
    4,
    true,
    (size - offset) / stride,
  )
  if count > 0 && (offset < 76 || offset % 4 != 0) {
    object_reject("OB001", start + field, "invalid bitcode symbol-table range")
  }
  (start + offset, count)
}

///|
fn bitcode_string(
  data : Bytes,
  field : Int32,
  strings : Int32,
  size : Int32,
) -> (Int32, Int32) raise InvalidObject {
  let offset = object_number(data, field, 4, true, size)
  let length = object_number(data, field + 4, 4, true, size - offset)
  (strings + offset, length)
}

///|
fn bitcode_symbols(
  data : Bytes,
  table : (Int32, Int32),
  strings : (Int32, Int32),
  module_count : Int32,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  let (start, size) = table
  let (str_start, str_size) = strings
  if size < 4 {
    object_reject("OB001", start, "truncated bitcode symbol-table version")
  }
  if object_number(data, start, 4, true, 2147483647) != 3 {
    object_reject("OB002", start, "unsupported bitcode symbol-table version")
  }
  if size < 76 {
    object_reject("OB001", start, "truncated bitcode symbol-table header")
  }
  let ranges = [
    bitcode_table_range(data, start, size, 12, 12),
    bitcode_table_range(data, start, size, 20, 12),
    bitcode_table_range(data, start, size, 28, 24),
    bitcode_table_range(data, start, size, 36, 24),
    bitcode_table_range(data, start, size, 68, 8),
  ]
  let strides = [12, 12, 24, 24, 8]
  for i in 0..<ranges.length() {
    let (first, count) = ranges[i]
    for j in 0..<i {
      let (other, other_count) = ranges[j]
      if count > 0 &&
        other_count > 0 &&
        first < other + other_count * strides[j] &&
        other < first + count * strides[i] {
        object_reject("OB001", first, "overlapping bitcode symbol-table ranges")
      }
    }
  }
  let (modules, modules_count) = ranges[0]
  let (comdats, comdat_count) = ranges[1]
  let (symbols, count) = ranges[2]
  let (uncommon, uncommon_count) = ranges[3]
  let (libraries, library_count) = ranges[4]
  if modules_count != module_count {
    object_reject(
      "OB002",
      start + 12,
      "bitcode symbol table does not cover its module group",
    )
  }
  object_charge_symbols(budget, count, start + 32)
  for field in [4, 44, 52, 60] {
    ignore(bitcode_string(data, start + field, str_start, str_size))
  }
  let mut next_symbol = 0
  for i in 0..<modules_count {
    let field = modules + i * 12
    let begin = object_number(data, field, 4, true, count)
    let end = object_number(data, field + 4, 4, true, count)
    ignore(object_number(data, field + 8, 4, true, uncommon_count))
    if begin != next_symbol || end < begin {
      object_reject(
        "OB001", field, "bitcode module symbol ranges do not form a partition",
      )
    }
    next_symbol = end
  }
  if next_symbol != count {
    object_reject(
      "OB001",
      start + 12,
      "bitcode module ranges omit symbol records",
    )
  }
  for i in 0..<comdat_count {
    let field = comdats + i * 12
    ignore(bitcode_string(data, field, str_start, str_size))
    ignore(object_number(data, field + 8, 4, true, 4))
  }
  for i in 0..<uncommon_count {
    let field = uncommon + i * 24
    let alignment = object_tag(data, field + 4, true)
    if alignment != 0U && (alignment & (alignment - 1U)) != 0U {
      object_reject("OB001", field + 4, "invalid bitcode common alignment")
    }
    ignore(bitcode_string(data, field + 8, str_start, str_size))
    ignore(bitcode_string(data, field + 16, str_start, str_size))
  }
  for i in 0..<library_count {
    ignore(bitcode_string(data, libraries + i * 8, str_start, str_size))
  }
  let result : Array[Bytes] = []
  let seen : Map[Bytes, Unit] = Map([])
  let mut used_uncommon = 0
  let mut next_module = 0
  for i = 0; i <= count; i = i + 1 {
    while next_module < modules_count &&
          object_number(data, modules + next_module * 12, 4, true, count) == i {
      if object_number(
          data,
          modules + next_module * 12 + 8,
          4,
          true,
          uncommon_count,
        ) !=
        used_uncommon {
        object_reject(
          "OB001",
          modules + next_module * 12 + 8,
          "inconsistent bitcode uncommon-record position",
        )
      }
      next_module += 1
    }
    if i == count {
      break
    }
    let field = symbols + i * 24
    let (name, length) = bitcode_string(data, field, str_start, str_size)
    ignore(bitcode_string(data, field + 8, str_start, str_size))
    let comdat = object_tag(data, field + 16, true)
    if comdat != 0xffffffffU && comdat >= comdat_count.reinterpret_as_uint() {
      object_reject(
        "OB001",
        field + 16,
        "bitcode symbol refers outside its comdat table",
      )
    }
    let flags = object_tag(data, field + 20, true)
    if flags >> 14 != 0U {
      object_reject("OB002", field + 20, "unsupported bitcode symbol flags")
    }
    if (flags & 3U) == 3U {
      object_reject("OB001", field + 20, "invalid bitcode symbol visibility")
    }
    if (flags & 4U) != 0U {
      used_uncommon += 1
    }
    if used_uncommon > uncommon_count {
      object_reject(
        "OB001",
        field + 20,
        "bitcode symbol lacks an uncommon record",
      )
    }
    if (flags & 8U) != 0U || (flags & 2048U) != 0U || (flags & 1040U) == 0U {
      continue
    }
    if length == 0 {
      object_reject("OB001", field, "empty defined bitcode symbol name")
    }
    if length > budget.names_left {
      object_reject("OB003", field, "expanded symbol-name byte limit exceeded")
    }
    budget.names_left -= length
    for j in name..<(name + length) {
      if data[j] == b'\x00' {
        object_reject("OB001", j, "NUL inside bitcode symbol name")
      }
    }
    let value = data[name:name + length].to_owned()
    if seen.get(value) is None {
      seen[value] = ()
      result.push(value)
    }
  }
  if used_uncommon != uncommon_count {
    object_reject("OB001", start + 36, "unreferenced bitcode uncommon records")
  }
  result
}

///|
fn object_bitcode(
  data : Bytes,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  let wrapped = data.has_prefix(b"\xde\xc0\x17\x0b"[:])
  let (start, end) = if wrapped {
    object_range(data, 0, 20)
    if object_number(data, 4, 4, true, 2147483647) != 0 {
      object_reject("OB002", 4, "unsupported bitcode wrapper version")
    }
    let start = object_number(data, 8, 4, true, data.length())
    let length = object_number(data, 12, 4, true, data.length() - start)
    if start < 20 {
      object_reject("OB001", 8, "bitcode wrapper payload overlaps its header")
    }
    (start, start + length)
  } else {
    (0, data.length())
  }
  if end - start < 4 || data[start:start + 4] != b"BC\xc0\xde"[:] {
    object_reject("OB001", start, "missing bitcode magic")
  }
  let cursor : BitcodeCursor = {
    data,
    origin: start,
    byte: start + 4,
    bit: 0,
    end,
  }
  let mut modules = 0
  let mut groups = 0
  let mut pending : (Int32, Int32)? = None
  let result : Array[Bytes] = []
  let seen : Map[Bytes, Unit] = Map([])
  while cursor.byte < end {
    if cursor.bit == 0 && end - cursor.byte <= 7 {
      let mut padding = true
      for i in cursor.byte..<end {
        if data[i] != b'\x00' && data[i] != b'\n' {
          padding = false
        }
      }
      if padding {
        cursor.byte = end
        break
      }
    }
    if cursor.fixed(2) != 1UL {
      object_reject("OB001", cursor.byte, "expected top-level bitcode block")
    }
    let (id, width, block_end) = cursor.block()
    if id == 8 {
      modules += 1
    }
    if id == 25 {
      if pending is Some(_) {
        object_reject(
          "OB002",
          cursor.byte,
          "multiple bitcode symbol tables without a string table",
        )
      }
      pending = Some(bitcode_blob(data, start, cursor.byte, block_end, width))
    } else if id == 23 {
      let strings = bitcode_blob(data, start, cursor.byte, block_end, width)
      guard pending is Some(table) && modules > 0 else {
        object_reject(
          "OB002",
          cursor.byte,
          "bitcode lacks a symbol table for its module group",
        )
      }
      for name in bitcode_symbols(data, table, strings, modules, budget) {
        if seen.get(name) is None {
          seen[name] = ()
          result.push(name)
        }
      }
      groups += 1
      modules = 0
      pending = None
    }
    cursor.byte = block_end
    cursor.bit = 0
  }
  if groups == 0 || modules != 0 || pending is Some(_) {
    object_reject(
      "OB002", start, "bitcode requires an embedded version-3 symbol table and string table",
    )
  }
  result
}
