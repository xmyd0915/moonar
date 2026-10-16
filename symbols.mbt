///|
// Decode only bounded values: every count, string index and member offset must
// fit within this input, including values stored in 64-bit table fields.
fn symbol_number(
  data : Bytes,
  pos : Int,
  width : Int,
  little : Bool,
  end : Int,
  limit : Int,
) -> Int raise InvalidArchive {
  if pos > end || end - pos < width {
    reject("AR009", pos, "truncated symbol index integer")
  }
  let mut value = 0
  for n = 0; n < width; n = n + 1 {
    let i = if little { pos + width - 1 - n } else { pos + n }
    let digit = data[i].to_int()
    if digit > limit || value > (limit - digit) / 256 {
      reject(
        "AR009", pos, "symbol index integer is outside its permitted range",
      )
    }
    value = value * 256 + digit
  }
  value
}

///|
fn symbol_target(
  archive : Archive,
  headers : Map[Int, Int],
  offset : Int,
  field_offset : Int,
) -> Int raise InvalidArchive {
  match headers.get(offset) {
    Some(index) if archive.records[index].kind == Regular => index
    _ =>
      reject(
        "AR009", field_offset, "symbol target is not a regular member header",
      )
  }
}

///|
fn symbol_padding(
  data : Bytes,
  start : Int,
  end : Int,
  maximum : Int,
) -> Unit raise InvalidArchive {
  if end - start > maximum {
    reject("AR009", start, "unexpected bytes after symbol index")
  }
  for i = start; i < end; i = i + 1 {
    if data[i] != b'\x00' {
      reject("AR009", i, "symbol index padding must be zero")
    }
  }
}

///|
fn gnu_symbol_index(
  archive : Archive,
  index : Int,
  headers : Map[Int, Int],
  max_symbols : Int,
  max_names : Int,
) -> SymbolIndex raise InvalidArchive {
  let entry = archive.records[index]
  let data = archive.data
  let start = entry.data_offset
  let end = start + entry.size
  let width = if entry.name == b"/SYM64/" { 8 } else { 4 }
  let count = symbol_number(data, start, width, false, end, entry.size / width)
  if count > (entry.size - width) / width {
    reject("AR009", start, "symbol count exceeds index size")
  }
  if count > max_symbols {
    reject("AR008", start, "symbol count limit exceeded")
  }
  let symbols : Array[Symbol] = []
  let mut cursor = start + width + count * width
  let mut name_bytes = 0
  for n = 0; n < count; n = n + 1 {
    let field_offset = start + width + n * width
    let target = symbol_number(
      data,
      field_offset,
      width,
      false,
      end,
      data.length(),
    )
    let member_index = symbol_target(archive, headers, target, field_offset)
    let name_offset = cursor
    while cursor < end && data[cursor] != b'\x00' {
      cursor += 1
    }
    if cursor == end || cursor == name_offset {
      reject("AR009", name_offset, "missing, empty or unterminated symbol name")
    }
    let length = cursor - name_offset
    if length > max_names - name_bytes {
      reject("AR008", name_offset, "expanded symbol-name byte limit exceeded")
    }
    name_bytes += length
    symbols.push({
      name: data[name_offset:cursor].to_owned(),
      member_index,
      name_offset,
      offset_field_offset: field_offset,
    })
    cursor += 1
  }
  symbol_padding(data, cursor, end, 1)
  {
    record_index: index,
    format: if width == 4 {
      "gnu32"
    } else {
      "gnu64"
    },
    symbols,
  }
}

///|
fn bsd_symbol_candidate(
  archive : Archive,
  index : Int,
  headers : Map[Int, Int],
  width : Int,
  little : Bool,
  max_symbols : Int,
  max_names : Int,
) -> SymbolIndex raise InvalidArchive {
  let entry = archive.records[index]
  let data = archive.data
  let start = entry.data_offset
  let end = start + entry.size
  let table_bytes = symbol_number(data, start, width, little, end, entry.size)
  if entry.size < width * 2 ||
    table_bytes > entry.size - width * 2 ||
    table_bytes % (width * 2) != 0 {
    reject("AR009", start, "invalid BSD ranlib table byte count")
  }
  let count = table_bytes / (width * 2)
  if count > max_symbols {
    reject("AR008", start, "symbol count limit exceeded")
  }
  let string_size_pos = start + width + table_bytes
  let string_start = string_size_pos + width
  let string_size = symbol_number(
    data,
    string_size_pos,
    width,
    little,
    end,
    end - string_start,
  )
  let string_end = string_start + string_size
  symbol_padding(data, string_end, end, 7)
  let references : Array[(Int, Int, Int)] = []
  let wanted : Map[Int, Unit] = Map([])
  for n = 0; n < count; n = n + 1 {
    let pos = start + width + n * width * 2
    let name_index = symbol_number(data, pos, width, little, end, string_size)
    let target = symbol_number(
      data,
      pos + width,
      width,
      little,
      end,
      data.length(),
    )
    let member_index = symbol_target(archive, headers, target, pos + width)
    references.push((name_index, member_index, pos + width))
    wanted[name_index] = ()
  }
  // Scan the string table once; repeated references share immutable name bytes.
  let names : Map[Int, Bytes] = Map([])
  let mut cursor = string_start
  let mut unique_name_bytes = 0
  while cursor < string_end {
    let first = cursor
    while cursor < string_end && data[cursor] != b'\x00' {
      cursor += 1
    }
    if cursor == string_end {
      reject("AR009", first, "unterminated BSD symbol string")
    }
    if wanted.get(first - string_start) is Some(_) {
      if first == cursor {
        reject("AR009", first, "empty symbol name")
      }
      if cursor - first > max_names - unique_name_bytes {
        reject("AR008", first, "expanded symbol-name byte limit exceeded")
      }
      unique_name_bytes += cursor - first
      names[first - string_start] = data[first:cursor].to_owned()
    }
    cursor += 1
  }
  let symbols : Array[Symbol] = []
  let mut name_bytes = 0
  for (name_index, member_index, field_offset) in references {
    guard names.get(name_index) is Some(name) else {
      reject(
        "AR009",
        field_offset - width,
        "symbol name is not a string-table entry boundary",
      )
    }
    if name.length() > max_names - name_bytes {
      reject(
        "AR008",
        string_start + name_index,
        "expanded symbol-name byte limit exceeded",
      )
    }
    name_bytes += name.length()
    symbols.push({
      name,
      member_index,
      name_offset: string_start + name_index,
      offset_field_offset: field_offset,
    })
  }
  if entry.name == b"__.SYMDEF SORTED" || entry.name == b"__.SYMDEF_64 SORTED" {
    for n = 1; n < symbols.length(); n = n + 1 {
      if symbols[n - 1].name > symbols[n].name {
        reject(
          "AR009",
          symbols[n].name_offset,
          "sorted BSD symbol index is out of order",
        )
      }
    }
  }
  let bits = if width == 4 { "32" } else { "64" }
  let endian = if little { "le" } else { "be" }
  { record_index: index, format: "bsd\{bits}-\{endian}", symbols, }
}

///|
fn bsd_symbol_index(
  archive : Archive,
  index : Int,
  headers : Map[Int, Int],
  max_symbols : Int,
  max_names : Int,
) -> SymbolIndex raise InvalidArchive {
  let name = archive.records[index].name
  let width = if name == b"__.SYMDEF_64" || name == b"__.SYMDEF_64 SORTED" {
    8
  } else {
    4
  }
  let little = Ok(
    bsd_symbol_candidate(
      archive, index, headers, width, true, max_symbols, max_names,
    ),
  ) catch {
    InvalidArchive(error) => Err(error)
  }
  let big = Ok(
    bsd_symbol_candidate(
      archive, index, headers, width, false, max_symbols, max_names,
    ),
  ) catch {
    InvalidArchive(error) => Err(error)
  }
  match (little, big) {
    (Ok(a), Err(error)) => {
      if error.code == "AR008" {
        raise InvalidArchive(error)
      }
      a
    }
    (Err(error), Ok(b)) => {
      if error.code == "AR008" {
        raise InvalidArchive(error)
      }
      b
    }
    (Ok(a), Ok(b)) => {
      if a.symbols != b.symbols {
        reject(
          "AR010",
          archive.records[index].data_offset,
          "BSD symbol index byte order is ambiguous",
        )
      }
      {
        ..a,
        format: if width == 4 {
          "bsd32-neutral"
        } else {
          "bsd64-neutral"
        },
      }
    }
    (Err(a), Err(b)) => {
      let error = if a.code == "AR008" {
        a
      } else if b.code == "AR008" || b.offset > a.offset {
        b
      } else {
        a
      }
      raise InvalidArchive(error)
    }
  }
}

///|
fn parse_symbol_indexes(
  archive : Archive,
  max_symbols : Int,
  max_names : Int,
) -> Array[SymbolIndex] raise InvalidArchive {
  let headers : Map[Int, Int] = Map([])
  let tables : Array[Int] = []
  for i, entry in archive.records {
    headers[entry.header_offset] = i
    if entry.kind == SymbolTable {
      tables.push(i)
    }
  }
  if tables.length() > 1 {
    reject(
      "AR010",
      archive.records[tables[1]].header_offset,
      "multiple symbol indexes, including COFF linker members, are unsupported",
    )
  }
  tables.map(index => {
    let name = archive.records[index].name
    if name == b"/" || name == b"/SYM64/" {
      gnu_symbol_index(archive, index, headers, max_symbols, max_names)
    } else {
      bsd_symbol_index(archive, index, headers, max_symbols, max_names)
    }
  })
}
