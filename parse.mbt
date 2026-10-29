///|
priv suberror InvalidArchive {
  InvalidArchive(ParseError)
}

///|
fn[T] reject(
  code : String,
  offset : Int32,
  message : String,
) -> T raise InvalidArchive {
  raise InvalidArchive({ code, offset, message, })
}

///|
// Header numbers use ASCII digits, with spaces permitted only at the ends.
fn number_field(
  data : Bytes,
  start : Int32,
  width : Int32,
  radix : Int32,
  optional : Bool,
  limit : Int64,
) -> Int64? raise InvalidArchive {
  let mut first = start
  let mut last = start + width
  while first < last && data[first] == b' ' {
    first += 1
  }
  while last > first && data[last - 1] == b' ' {
    last -= 1
  }
  if first == last {
    if optional {
      return None
    }
    reject("AR004", start, "missing numeric field")
  }
  let mut value = 0L
  for i = first; i < last; i = i + 1 {
    let digit = data[i].to_int() - 48
    if digit < 0 || digit >= radix {
      reject("AR004", i, "invalid digit in archive header")
    }
    if value > (limit - digit.to_int64()) / radix.to_int64() {
      reject("AR005", start, "numeric field exceeds supported range")
    }
    value = value * radix.to_int64() + digit.to_int64()
  }
  Some(value)
}

///|
fn has_coff_linker_pair(data : Bytes) -> Bool {
  if data.length() < 68 || data[8:24] != b"/               "[:] {
    return false
  }
  let size = number_field(data, 56, 10, 10, false, 2147483647L) catch {
    InvalidArchive(_) => return false
  }
  let size = size.unwrap().to_int()
  if size > data.length() - 68 {
    return false
  }
  if size % 2 > data.length() - 68 - size {
    return false
  }
  let second = 68 + size + size % 2
  data.length() - second >= 60 &&
  data[second:second + 16] == b"/               "[:]
}

///|
fn archive_timestamp(
  data : Bytes,
  start : Int32,
  coff : Bool,
) -> Int64? raise InvalidArchive {
  // Microsoft import libraries use -1 as an unknown timestamp. Preserve its
  // semantic absence rather than treating it as a negative Unix timestamp.
  if coff {
    let mut first = start
    let mut last = start + 12
    while first < last && data[first] == b' ' {
      first += 1
    }
    while last > first && data[last - 1] == b' ' {
      last -= 1
    }
    if data[first:last] == b"-1"[:] {
      return None
    }
  }
  number_field(data, start, 12, 10, true, 0x7fffffffffffffffL)
}

///|
fn parse_records(
  data : Bytes,
  max_members : Int32,
  max_name_bytes : Int32,
) -> Archive raise InvalidArchive {
  if data.length() >= 8 && data[:8] == b"!<thin>\n"[:] {
    reject("AR007", 0, "use parse_thin for thin archives")
  }
  if data.length() < 8 || data[:8] != b"!<arch>\n"[:] {
    reject("AR001", 0, "expected ar archive magic")
  }
  let coff_header = has_coff_linker_pair(data)
  let records : Array[Member] = []
  let pending_names : Array[(Int32, Int32)] = []
  let wanted_names : Map[Int32, Unit] = Map([])
  let mut long_table : (Int32, Int32)? = None
  let mut offset = 8
  while offset < data.length() {
    if records.length() >= max_members {
      reject("AR008", offset, "archive member limit exceeded")
    }
    if data.length() - offset < 60 {
      reject("AR002", offset, "truncated member header")
    }
    if data[offset + 58] != b'`' || data[offset + 59] != b'\n' {
      reject("AR003", offset + 58, "invalid member header trailer")
    }
    let mut name_end = offset + 16
    while name_end > offset && data[name_end - 1] == b' ' {
      name_end -= 1
    }
    let raw_name = data[offset:name_end].to_owned()
    if raw_name.is_empty() {
      reject("AR006", offset, "empty member name")
    }
    let mut kind = member_kind(raw_name)
    if kind == Regular && raw_name.has_prefix(b"/"[:]) {
      for i = 1; i < raw_name.length(); i = i + 1 {
        if raw_name[i] < b'0' || raw_name[i] > b'9' {
          reject("AR006", offset + i, "invalid GNU name reference")
        }
      }
      let reference = number_field(
          data,
          offset + 1,
          raw_name.length() - 1,
          10,
          false,
          2147483647L,
        )
        .unwrap()
        .to_int()
      pending_names.push((records.length(), reference))
      wanted_names[reference] = ()
    }
    let mut name = if kind == Regular && raw_name.has_suffix(b"/"[:]) {
      raw_name[:raw_name.length() - 1].to_owned()
    } else {
      raw_name
    }
    if name.is_empty() {
      reject("AR006", offset, "empty member name")
    }
    for byte in name {
      if byte == b'\x00' {
        reject("AR006", offset, "NUL inside member name")
      }
    }
    let timestamp = archive_timestamp(data, offset + 16, coff_header)
    let uid = number_field(data, offset + 28, 6, 10, true, 0x7fffffffffffffffL)
    let gid = number_field(data, offset + 34, 6, 10, true, 0x7fffffffffffffffL)
    let mode = number_field(data, offset + 40, 8, 8, true, 0x7fffffffffffffffL)
    let stored_size = number_field(
        data,
        offset + 48,
        10,
        10,
        false,
        2147483647L,
      )
      .unwrap()
      .to_int()
    let mut data_offset = offset + 60
    if stored_size > data.length() - data_offset {
      reject("AR002", data_offset, "truncated member payload")
    }
    let end = data_offset + stored_size
    let padding = stored_size % 2
    if padding == 1 && (end == data.length() || data[end] != b'\n') {
      reject("AR003", end, "missing or invalid alignment byte")
    }
    if kind == NameTable {
      if long_table is Some(_) {
        reject("AR006", offset, "more than one GNU name table")
      }
      long_table = Some((data_offset, stored_size))
    }
    let mut size = stored_size
    if raw_name.has_prefix(b"#1/"[:]) {
      let name_size = embedded_name_size(
        data,
        offset + 3,
        raw_name.length() - 3,
      )
      if name_size == 0 || name_size > stored_size {
        reject("AR006", offset, "BSD name length is outside its record")
      }
      name = bsd_name(data, data_offset, name_size)
      data_offset += name_size
      size -= name_size
    }
    kind = member_kind(name)
    records.push({
      name,
      kind,
      header_offset: offset,
      data_offset,
      size,
      stored_size,
      metadata: { timestamp, uid, gid, mode, },
    })
    offset = end + padding
  }
  let coff = records.length() >= 2 &&
    records[0].name == b"/" &&
    records[1].name == b"/" &&
    records[1].size >= 8
  let long_names = match long_table {
    Some((start, size)) =>
      Some(
        if coff {
          coff_names(data, start, size, wanted_names)
        } else {
          gnu_names(data, start, size, wanted_names)
        },
      )
    None => None
  }
  for (index, reference) in pending_names {
    let entry = records[index]
    match long_names {
      None =>
        reject(
          "AR006",
          entry.header_offset,
          "GNU name reference has no name table",
        )
      Some(names) =>
        match names.get(reference) {
          None =>
            reject(
              "AR006",
              entry.header_offset,
              "GNU name reference is not an entry boundary",
            )
          Some(name) =>
            // A GNU string-table reference denotes an ordinary record.
            // Its resolved filename may equal an index spelling without
            // becoming a physical symbol or name table.
            records[index] = { ..entry, name, }
        }
    }
  }
  let mut total_name_bytes = 0
  for entry in records {
    if entry.name.length() > max_name_bytes - total_name_bytes {
      reject(
        "AR008",
        entry.header_offset,
        "expanded member-name byte limit exceeded",
      )
    }
    total_name_bytes += entry.name.length()
  }
  { data, records, indexes: [], }
}

///|
/// Read a regular ar archive. Limits include special records and the entire input.
/// Input bytes are immutable. Errors carry offsets into that input.
pub fn parse(
  input : Bytes,
  max_members~ : Int32 = 100000,
  max_bytes~ : Int32 = 67108864,
  max_name_bytes~ : Int32 = 67108864,
  max_symbols~ : Int32 = 1000000,
  max_symbol_name_bytes~ : Int32 = 67108864,
) -> Result[Archive, ParseError] {
  if max_members < 0 ||
    max_bytes < 0 ||
    max_name_bytes < 0 ||
    max_symbols < 0 ||
    max_symbol_name_bytes < 0 {
    return Err({
      code: "AR008",
      offset: 0,
      message: "limits must be nonnegative",
    })
  }
  if input.length() > max_bytes {
    return Err({
      code: "AR008",
      offset: 0,
      message: "archive byte limit exceeded",
    })
  }
  try {
    let archive = parse_records(input, max_members, max_name_bytes)
    let indexes = parse_symbol_indexes(
      archive, max_symbols, max_symbol_name_bytes,
    )
    Ok({ ..archive, indexes, })
  } catch {
    InvalidArchive(error) => Err(error)
  }
}
