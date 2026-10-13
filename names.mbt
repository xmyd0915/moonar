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
    while stop + 1 < end && !(data[stop] == b'/' && data[stop + 1] == b'\n') {
      stop += 1
    }
    if stop + 1 >= end {
      reject("AR006", cursor, "unterminated GNU long name")
    }
    if stop == cursor {
      reject("AR006", cursor, "empty GNU long name")
    }
    if wanted.get(cursor - start) is Some(_) {
      names[cursor - start] = data[cursor:stop].to_owned()
    }
    cursor = stop + 2
  }
  names
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
