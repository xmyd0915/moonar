///|
fn object_coff_anonymous(
  data : Bytes,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  object_range(data, 0, 8)
  let version = object_number(data, 4, 2, true, 65535)
  let machine = object_number(data, 6, 2, true, 65535)
  if !object_coff_machine(machine) {
    object_reject("OB002", 6, "unsupported COFF machine")
  }
  if version == 0 {
    return object_import(data, budget)
  }
  if version < 2 {
    object_reject("OB002", 4, "unsupported anonymous COFF version")
  }
  object_range(data, 0, 56)
  if data[12:28] !=
    b"\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"[:] {
    object_reject("OB002", 12, "unsupported anonymous COFF class identifier")
  }
  object_coff(data, budget, big=true)
}

///|
fn object_import(
  data : Bytes,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  object_range(data, 0, 20)
  let size = object_number(data, 12, 4, true, data.length() - 20)
  if size != data.length() - 20 {
    object_reject("OB001", 12, "import object size does not match its payload")
  }
  let flags = object_number(data, 18, 2, true, 65535)
  if flags >> 5 != 0 {
    object_reject("OB001", 18, "nonzero reserved import object flags")
  }
  let kind = flags & 3
  let name_type = (flags >> 2) & 7
  if kind == 3 || name_type > 4 {
    object_reject("OB002", 18, "unsupported import object kind or name mode")
  }
  let mut cursor = 20
  let mut symbol_end = 20
  for field = 0; field < (if name_type == 4 { 3 } else { 2 }); field = field + 1 {
    let start = cursor
    while cursor < data.length() && data[cursor] != b'\x00' {
      cursor += 1
    }
    if cursor == data.length() || cursor == start {
      object_reject(
        "OB001", start, "empty or unterminated import object string",
      )
    }
    if field == 0 {
      symbol_end = cursor
    }
    cursor += 1
  }
  if data.length() - cursor > 3 {
    object_reject("OB001", cursor, "unexpected import object payload")
  }
  for i = cursor; i < data.length(); i = i + 1 {
    if data[i] != b'\x00' {
      object_reject("OB001", i, "invalid import object padding")
    }
  }
  let count = if kind == 0 { 2 } else { 1 }
  object_charge_symbols(budget, count, 18)
  let length = symbol_end - 20
  if length > budget.names_left - 6 {
    object_reject("OB003", 20, "expanded symbol-name byte limit exceeded")
  }
  budget.names_left -= 6 + length
  let name = data[20:symbol_end].to_owned()
  let result = [b"__imp_" + name]
  if kind == 0 {
    if length > budget.names_left {
      object_reject("OB003", 20, "expanded symbol-name byte limit exceeded")
    }
    budget.names_left -= length
    result.push(name)
  }
  result
}
