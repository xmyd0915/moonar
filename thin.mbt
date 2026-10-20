///|
/// A physical thin-archive record. Regular records refer to external files;
/// their size is the declared external file size, not an inline payload length.
pub(all) struct ThinMember {
  name : Bytes
  kind : MemberKind
  header_offset : Int
  size : Int
  metadata : Metadata
} derive(Eq, Debug)

///|
/// GNU thin archive metadata and validated symbol references, without file I/O.
struct ThinArchive {
  archive : Archive
} derive(Debug)

///|
pub extend ThinMember with Eq::{equal, not_equal}

///|
pub extend ThinMember with Debug::{to_repr}

///|
pub extend ThinArchive with Debug::{to_repr}

///|
pub fn ThinMember::name_text(self : ThinMember) -> String {
  @utf8.decode_lossy(self.name[:], ignore_bom=false)
}

///|
pub fn ThinMember::name_hex(self : ThinMember) -> String {
  hex_bytes(self.name)
}

///|
/// Count physical records, including inline symbol and name tables.
pub fn ThinArchive::member_count(self : ThinArchive) -> Int {
  self.archive.records.length()
}

///|
pub fn ThinArchive::byte_length(self : ThinArchive) -> Int {
  self.archive.data.length()
}

///|
pub fn ThinArchive::get_member(self : ThinArchive, index : Int) -> ThinMember? {
  self.archive.records
  .get(index)
  .map(entry => {
    name: entry.name,
    kind: entry.kind,
    header_offset: entry.header_offset,
    size: entry.size,
    metadata: entry.metadata,
  })
}

///|
/// Return copies; symbol targets use the same physical indices as get_member.
pub fn ThinArchive::symbol_indexes(self : ThinArchive) -> Array[SymbolIndex] {
  self.archive.symbol_indexes()
}

///|
/// Only special records have inline bytes. Regular records and invalid indices
/// return None; use load_member to obtain an external member's contents.
pub fn ThinArchive::inline_bytes(self : ThinArchive, index : Int) -> Bytes? {
  guard self.archive.records.get(index) is Some(entry) else { return None }
  if entry.kind == Regular {
    None
  } else {
    self.archive.member_bytes(index)
  }
}

///|
fn parse_thin_records(
  data : Bytes,
  max_members : Int,
  max_name_bytes : Int,
) -> Archive raise InvalidArchive {
  if data.length() < 8 || data[:8] != b"!<thin>\n"[:] {
    reject("AR001", 0, "expected GNU thin archive magic")
  }
  let records : Array[Member] = []
  let pending_names : Array[(Int, Int)] = []
  let wanted_names : Map[Int, Unit] = Map([])
  let mut long_table : (Int, Int)? = None
  let mut offset = 8
  while offset < data.length() {
    if records.length() >= max_members {
      reject("AR008", offset, "archive member limit exceeded")
    }
    if data.length() - offset < 60 {
      reject("AR002", offset, "truncated thin member header")
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
    if raw_name.has_prefix(b"#1/"[:]) {
      reject(
        "AR011", offset, "BSD embedded names are unsupported in thin archives",
      )
    }
    // Only the raw GNU header spelling determines the physical role. A name
    // table entry such as __.SYMDEF is an external file, not an inline index.
    let kind = if raw_name == b"//" {
      NameTable
    } else if raw_name == b"/" || raw_name == b"/SYM64/" {
      SymbolTable
    } else {
      Regular
    }
    if kind == Regular && raw_name.has_prefix(b"/"[:]) {
      for i = 1; i < raw_name.length(); i = i + 1 {
        if raw_name[i] == b':' {
          reject(
            "AR011",
            offset + i,
            "nested archive offset references are unsupported",
          )
        }
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
    let name = if kind == Regular && raw_name.has_suffix(b"/"[:]) {
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
    let size = number_field(data, offset + 48, 10, 10, false, 2147483647L)
      .unwrap()
      .to_int()
    let data_offset = offset + 60
    // External members occupy exactly the header, even for an odd declared size.
    let inline_size = if kind == Regular { 0 } else { size }
    if inline_size > data.length() - data_offset {
      reject("AR002", data_offset, "truncated thin special-record payload")
    }
    let end = data_offset + inline_size
    let padding = inline_size % 2
    if padding == 1 && (end == data.length() || data[end] != b'\n') {
      reject("AR003", end, "missing or invalid alignment byte")
    }
    if kind == NameTable {
      if long_table is Some(_) {
        reject("AR006", offset, "more than one GNU name table")
      }
      long_table = Some((data_offset, size))
    }
    records.push({
      name,
      kind,
      header_offset: offset,
      data_offset,
      size,
      stored_size: size,
      metadata: { timestamp, uid, gid, mode, },
    })
    offset = end + padding
  }
  let long_names = match long_table {
    Some((start, size)) => Some(gnu_names(data, start, size, wanted_names))
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
          Some(name) => records[index] = { ..entry, name, }
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
/// Parse GNU thin metadata and GNU 32/64-bit symbol indexes without loading
/// external files. Byte limits cover this input, not referenced external files.
/// Nested archive offset references and BSD embedded names are rejected.
pub fn parse_thin(
  input : Bytes,
  max_members? : Int = 100000,
  max_bytes? : Int = 67108864,
  max_name_bytes? : Int = 67108864,
  max_symbols? : Int = 1000000,
  max_symbol_name_bytes? : Int = 67108864,
) -> Result[ThinArchive, ParseError] {
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
    let archive = parse_thin_records(input, max_members, max_name_bytes)
    let indexes = parse_symbol_indexes(
      archive, max_symbols, max_symbol_name_bytes,
    )
    Ok({ archive: { ..archive, indexes, }, })
  } catch {
    InvalidArchive(error) => Err(error)
  }
}

///|
fn thin_relative_path(
  name : Bytes,
  offset : Int,
  allow_parent_paths? : Bool = false,
) -> Bytes raise InvalidArchive {
  if name.is_empty() || name[0] == b'/' {
    reject("AR012", offset, "external member path must be relative")
  }
  if name[name.length() - 1] == b'/' {
    reject("AR012", offset, "external member path must end in a file component")
  }
  for byte in name {
    if byte == b'\\' || byte == b':' || byte == b'\x00' {
      reject(
        "AR012", offset, "external member path contains a nonportable separator or prefix",
      )
    }
  }
  let normalized : Array[Byte] = []
  let mut cursor = 0
  while cursor < name.length() {
    let start = cursor
    while cursor < name.length() && name[cursor] != b'/' {
      cursor += 1
    }
    let part = name[start:cursor]
    if cursor == name.length() && (part == b"."[:] || part == b".."[:]) {
      reject(
        "AR012", offset, "external member path must end in a file component",
      )
    }
    if part == b".."[:] && !allow_parent_paths {
      reject(
        "AR012", offset, "external member path contains a parent component",
      )
    }
    if !part.is_empty() && part != b"."[:] {
      if !normalized.is_empty() {
        normalized.push(b'/')
      }
      for byte in part {
        normalized.push(byte)
      }
    }
    cursor += 1
  }
  if normalized.is_empty() {
    reject("AR012", offset, "external member path does not name a file")
  }
  Bytes::from_array(normalized)
}

///|
/// Return a portable relative path, removing "." and repeated "/" components.
/// Absolute, backslash, drive/stream and directory-ending paths fail with AR012.
/// Parent components require allow_parent_paths=true and remain in the returned
/// path so callers can resolve them relative to the archive directory.
pub fn ThinArchive::member_path(
  self : ThinArchive,
  index : Int,
  allow_parent_paths? : Bool = false,
) -> Result[Bytes, ParseError] {
  guard self.archive.records.get(index) is Some(entry) else {
    return Err({
      code: "AR011",
      offset: 0,
      message: "invalid thin member index",
    })
  }
  if entry.kind != Regular {
    return Err({
      code: "AR011",
      offset: entry.header_offset,
      message: "thin record is not an external member",
    })
  }
  Ok(thin_relative_path(entry.name, entry.header_offset, allow_parent_paths~)) catch {
    InvalidArchive(error) => Err(error)
  }
}

///|
/// Request an external member from a caller-supplied loader. The loader receives
/// a portable relative path and the maximum expected byte count. It controls the
/// base directory, symlink handling and actual I/O allocation. Declared size is
/// checked before calling it; returned bytes must match that size and max_bytes.
pub fn ThinArchive::load_member(
  self : ThinArchive,
  index : Int,
  loader : (Bytes, Int) -> Result[Bytes, String],
  max_bytes? : Int = 67108864,
  allow_parent_paths? : Bool = false,
) -> Result[Bytes, ParseError] {
  if max_bytes < 0 {
    return Err({
      code: "AR008",
      offset: 0,
      message: "limits must be nonnegative",
    })
  }
  let path = match self.member_path(index, allow_parent_paths~) {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  let entry = self.archive.records[index]
  if entry.size > max_bytes {
    return Err({
      code: "AR008",
      offset: entry.header_offset,
      message: "external member byte limit exceeded",
    })
  }
  match loader(path, entry.size) {
    Err(message) =>
      Err({ code: "AR013", offset: entry.header_offset, message, })
    Ok(bytes) =>
      if bytes.length() > max_bytes {
        Err({
          code: "AR008",
          offset: entry.header_offset,
          message: "external member byte limit exceeded",
        })
      } else if bytes.length() != entry.size {
        Err({
          code: "AR014",
          offset: entry.header_offset,
          message: "external member size differs from its archive header",
        })
      } else {
        Ok(bytes)
      }
  }
}
