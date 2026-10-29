///|
fn index_mappings(table : SymbolIndex) -> Map[Bytes, Array[Int32]] {
  let result : Map[Bytes, Array[Int32]] = Map([])
  for symbol in table.symbols {
    match result.get(symbol.name) {
      Some(targets) => targets.push(symbol.member_index)
      None => result[symbol.name] = [symbol.member_index]
    }
  }
  result
}

///|
fn coff_symbol_index(
  archive : Archive,
  headers : Map[Int32, Int32],
  max_symbols : Int32,
  max_names : Int32,
) -> SymbolIndex raise InvalidArchive {
  let entry = archive.records[1]
  let data = archive.data
  let start = entry.data_offset
  let end = start + entry.size
  let members = symbol_number(
    data,
    start,
    4,
    true,
    end,
    archive.records.length(),
  )
  if members > (entry.size - 8) / 4 {
    reject("AR009", start, "COFF member offsets exceed the linker record")
  }
  let targets : Array[Int32] = []
  let mut previous = -1
  for n = 0; n < members; n = n + 1 {
    let field = start + 4 + n * 4
    let offset = symbol_number(data, field, 4, true, end, data.length())
    if offset <= previous {
      reject("AR009", field, "COFF member offsets must be strictly increasing")
    }
    targets.push(symbol_target(archive, headers, offset, field))
    previous = offset
  }
  let count_field = start + 4 + members * 4
  let count = symbol_number(
    data,
    count_field,
    4,
    true,
    end,
    (end - count_field - 4) / 2,
  )
  if count > max_symbols {
    reject("AR008", count_field, "symbol count limit exceeded")
  }
  let mut cursor = count_field + 4 + count * 2
  let mut name_bytes = 0
  let symbols : Array[Symbol] = []
  for n = 0; n < count; n = n + 1 {
    let field = count_field + 4 + n * 2
    let ordinal = symbol_number(data, field, 2, true, end, members)
    if ordinal == 0 {
      reject("AR009", field, "COFF member ordinals are one-based")
    }
    let name_offset = cursor
    while cursor < end && data[cursor] != b'\x00' {
      cursor += 1
    }
    if cursor == end || cursor == name_offset {
      reject("AR009", name_offset, "missing or unterminated COFF symbol name")
    }
    let length = cursor - name_offset
    if length > max_names - name_bytes {
      reject("AR008", name_offset, "expanded symbol-name byte limit exceeded")
    }
    name_bytes += length
    let name = data[name_offset:cursor].to_owned()
    if !symbols.is_empty() &&
      symbols[symbols.length() - 1].name.lexical_compare(name) > 0 {
      reject("AR009", name_offset, "COFF symbol names must be sorted")
    }
    symbols.push({
      name,
      member_index: targets[ordinal - 1],
      name_offset,
      offset_field_offset: field,
    })
    cursor += 1
  }
  symbol_padding(data, cursor, end, 1)
  { record_index: 1, format: "coff", symbols, }
}
