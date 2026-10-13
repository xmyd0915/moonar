///|
priv suberror InvalidArchive {
  InvalidArchive(ParseError)
}

///|
fn reject(
  code : String,
  offset : Int,
  message : String,
) -> Unit raise InvalidArchive {
  raise InvalidArchive({ code, offset, message, })
}

///|
// Header numbers use ASCII digits, with spaces permitted only at the ends.
fn number_field(
  data : Bytes,
  start : Int,
  width : Int,
  radix : Int,
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
fn parse_records(
  data : Bytes,
  max_members : Int,
) -> Archive raise InvalidArchive {
  if data.length() >= 8 && data[:8] == b"!<thin>\n"[:] {
    reject("AR007", 0, "thin archives are not supported")
  }
  if data.length() < 8 || data[:8] != b"!<arch>\n"[:] {
    reject("AR001", 0, "expected ar archive magic")
  }
  let records : Array[Member] = []
  let pending_names : Array[(Int, Int)] = []
  let mut long_names : Map[Int, Bytes]? = None
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
    }
    let mut name = if kind == Regular && raw_name.has_suffix(b"/"[:]) {
      raw_name[:raw_name.length() - 1].to_owned()
    } else {
      raw_name
    }
    if name.is_empty() {
      reject("AR006", offset, "empty member name")
    }
    let timestamp = number_field(
      data,
      offset + 16,
      12,
      10,
      true,
      0x7fffffffffffffffL,
    )
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
      if long_names is Some(_) {
        reject("AR006", offset, "more than one GNU name table")
      }
      long_names = Some(gnu_names(data, data_offset, stored_size))
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
            records[index] = { ..entry, name, kind: member_kind(name), }
        }
    }
  }
  { data, records, }
}

///|
/// Read a regular ar archive. Limits include special records and the entire input.
/// Input bytes are immutable. Errors carry offsets into that input.
pub fn parse(
  input : Bytes,
  max_members? : Int = 100000,
  max_bytes? : Int = 67108864,
) -> Result[Archive, ParseError] {
  if max_members < 0 || max_bytes < 0 {
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
  Ok(parse_records(input, max_members)) catch {
    InvalidArchive(error) => Err(error)
  }
}
