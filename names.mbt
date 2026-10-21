///|
// Scan once, retaining only referenced names. A large unused table must not
// allocate a map entry and byte buffer for every name it happens to contain.
fn gnu_names(
  data : Bytes,
  start : Int,
  size : Int,
  wanted : Map[Int, Unit],
) -> Map[Int, Bytes] raise InvalidArchive {
  let names : Map[Int, Bytes] = Map([])
  let mut cursor = start
  let end = start + size
  while cursor < end {
    // GNU ar may include one final newline in the table's declared size.
    if cursor == end - 1 && data[cursor] == b'\n' {
      break
    }
    let mut stop = cursor
    while stop < end && data[stop] != b'\n' {
      stop += 1
    }
    if stop == end {
      reject("AR006", cursor, "unterminated GNU long name")
    }
    if stop == cursor || data[stop - 1] != b'/' {
      reject("AR006", stop, "GNU long-name newline must follow a slash")
    }
    let name_end = stop - 1
    if name_end == cursor {
      reject("AR006", cursor, "empty GNU long name")
    }
    for i = cursor; i < name_end; i = i + 1 {
      if data[i] == b'\x00' {
        reject("AR006", i, "NUL inside GNU long name")
      }
    }
    if wanted.get(cursor - start) is Some(_) {
      names[cursor - start] = data[cursor:name_end].to_owned()
    }
    cursor = stop + 1
  }
  names
}

///|
fn coff_names(
  data : Bytes,
  start : Int,
  size : Int,
  wanted : Map[Int, Unit],
) -> Map[Int, Bytes] raise InvalidArchive {
  let result : Map[Int, Bytes] = Map([])
  let end = start + size
  let mut cursor = start
  while cursor < end {
    if data[cursor] == b'\x00' {
      for i = cursor; i < end; i = i + 1 {
        if data[i] != b'\x00' {
          reject("AR006", i, "invalid COFF long-name padding")
        }
      }
      break
    }
    let first = cursor
    while cursor < end && data[cursor] != b'\x00' {
      cursor += 1
    }
    if cursor == end {
      reject("AR006", first, "unterminated COFF long name")
    }
    if wanted.get(first - start) is Some(_) {
      result[first - start] = data[first:cursor].to_owned()
    }
    cursor += 1
  }
  result
}

///|
fn member_kind(name : Bytes) -> MemberKind {
  if name == b"//" {
    NameTable
  } else if name == b"/" ||
    name == b"/SYM64/" ||
    name == b"__.SYMDEF" ||
    name == b"__.SYMDEF SORTED" ||
    name == b"__.SYMDEF_64" ||
    name == b"__.SYMDEF_64 SORTED" {
    SymbolTable
  } else {
    Regular
  }
}

///|
fn embedded_name_size(
  data : Bytes,
  start : Int,
  width : Int,
) -> Int raise InvalidArchive {
  if width == 0 {
    reject("AR006", start, "missing BSD name length")
  }
  for i = start; i < start + width; i = i + 1 {
    if data[i] < b'0' || data[i] > b'9' {
      reject("AR006", i, "invalid BSD name length")
    }
  }
  number_field(data, start, width, 10, false, 2147483647L).unwrap().to_int()
}

///|
fn bsd_name(
  data : Bytes,
  start : Int,
  width : Int,
) -> Bytes raise InvalidArchive {
  let mut end = start + width
  while end > start && data[end - 1] == b'\x00' {
    end -= 1
  }
  if end == start {
    reject("AR006", start, "empty BSD name")
  }
  for i = start; i < end; i = i + 1 {
    if data[i] == b'\x00' {
      reject("AR006", i, "NUL inside BSD name")
    }
  }
  data[start:end].to_owned()
}
