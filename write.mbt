///|
/// Member-name encoding used when creating a regular archive.
pub(all) enum WriteFormat {
  Gnu
  Bsd
} derive(Eq, Debug)

///|
/// Deterministic writes use time/uid/gid zero and mode 0644.
/// Preserve writes the supplied metadata, including blank fields represented by None.
pub(all) enum WriteMetadata {
  Deterministic
  Preserve
} derive(Eq, Debug)

///|
/// An ordinary entry to write. Names and payloads retain their exact bytes.
pub(all) struct WriteMember {
  name : Bytes
  data : Bytes
  metadata : Metadata
} derive(Eq, Debug)

///|
pub fn WriteMember::new(
  name : Bytes,
  data : Bytes,
  metadata? : Metadata = {
    timestamp: Some(0L),
    uid: Some(0L),
    gid: Some(0L),
    mode: Some(420L),
  },
) -> WriteMember {
  { name, data, metadata, }
}

///|
/// A symbol target is a zero-based ordinary-entry index in the final builder.
/// Supply mappings after all edits; mappings are never carried across edits.
pub(all) struct WriteSymbol {
  name : Bytes
  member_index : Int
} derive(Eq, Debug)

///|
/// WR001: invalid entry/name/index; WR002: unrepresentable metadata;
/// WR003: resource limit; WR004: existing index needs an explicit decision;
/// WR005: invalid or unsupported symbol-index request.
pub(all) struct WriteError {
  code : String
  member_index : Int?
  message : String
} derive(Eq, Debug)

///|
/// An immutable editing plan. Operations return a new plan and preserve their input.
struct ArchiveBuilder {
  members : Array[WriteMember]
} derive(Debug)

///|
pub fn ArchiveBuilder::new() -> ArchiveBuilder {
  { members: [], }
}

///|
/// Validate a complete collection and copy its array once.
/// Use this for bulk creation instead of repeatedly appending to an immutable plan.
pub fn ArchiveBuilder::from_members(
  entries : Array[WriteMember],
) -> Result[ArchiveBuilder, WriteError] {
  try {
    for index, entry in entries {
      write_member_valid(entry, index)
    }
    Ok({ members: entries.copy(), })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ArchiveBuilder::member_count(self : ArchiveBuilder) -> Int {
  self.members.length()
}

///|
/// Return an independent array; names and payloads are immutable byte strings.
pub fn ArchiveBuilder::members(self : ArchiveBuilder) -> Array[WriteMember] {
  self.members.copy()
}

///|
priv suberror InvalidWrite {
  InvalidWrite(WriteError)
}

///|
fn[T] write_reject(
  code : String,
  index : Int?,
  message : String,
) -> T raise InvalidWrite {
  raise InvalidWrite({ code, member_index: index, message, })
}

///|
fn write_member_valid(
  entry : WriteMember,
  index : Int,
) -> Unit raise InvalidWrite {
  if entry.name.is_empty() || member_kind(entry.name) != Regular {
    write_reject("WR001", Some(index), "empty or reserved ordinary-entry name")
  }
  for byte in entry.name {
    if byte == b'\x00' {
      write_reject("WR001", Some(index), "NUL inside entry name")
    }
  }
  let fields = [
    ("timestamp", entry.metadata.timestamp, 999999999999L),
    ("uid", entry.metadata.uid, 999999L),
    ("gid", entry.metadata.gid, 999999L),
    ("mode", entry.metadata.mode, 16777215L),
  ]
  for (name, value, maximum) in fields {
    if value is Some(number) && (number < 0L || number > maximum) {
      write_reject(
        "WR002",
        Some(index),
        "\{name} does not fit its archive header field",
      )
    }
  }
}

///|
pub fn ArchiveBuilder::append(
  self : ArchiveBuilder,
  entry : WriteMember,
) -> Result[ArchiveBuilder, WriteError] {
  try {
    write_member_valid(entry, self.members.length())
    let members = self.members.copy()
    members.push(entry)
    Ok({ members, })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ArchiveBuilder::replace(
  self : ArchiveBuilder,
  index : Int,
  entry : WriteMember,
) -> Result[ArchiveBuilder, WriteError] {
  try {
    if index < 0 || index >= self.members.length() {
      write_reject("WR001", Some(index), "entry index is outside the archive")
    }
    write_member_valid(entry, index)
    let members = self.members.copy()
    members[index] = entry
    Ok({ members, })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ArchiveBuilder::remove(
  self : ArchiveBuilder,
  index : Int,
) -> Result[ArchiveBuilder, WriteError] {
  if index < 0 || index >= self.members.length() {
    return Err({
      code: "WR001",
      member_index: Some(index),
      message: "entry index is outside the archive",
    })
  }
  let members = self.members.copy()
  ignore(members.remove(index))
  Ok({ members, })
}

///|
/// Move a entry to its final zero-based position, preserving the order of others.
pub fn ArchiveBuilder::move_member(
  self : ArchiveBuilder,
  from : Int,
  to : Int,
) -> Result[ArchiveBuilder, WriteError] {
  let count = self.members.length()
  if from < 0 || from >= count || to < 0 || to >= count {
    return Err({
      code: "WR001",
      member_index: Some(if from < 0 || from >= count { from } else { to }),
      message: "move position is outside the archive",
    })
  }
  let members = self.members.copy()
  let entry = members.remove(from)
  members.insert(to, entry)
  Ok({ members, })
}

///|
/// Import ordinary members for editing. An existing symbol index must be
/// explicitly discarded; rebuilding uses fresh mappings passed to write().
/// Ordinary-entry positions do not include name or symbol table records.
pub fn Archive::edit(
  self : Archive,
  drop_symbol_indexes? : Bool = false,
) -> Result[ArchiveBuilder, WriteError] {
  if !self.indexes.is_empty() && !drop_symbol_indexes {
    return Err({
      code: "WR004",
      member_index: None,
      message: "choose drop_symbol_indexes=true and optionally supply fresh symbols when writing",
    })
  }
  try {
    let members : Array[WriteMember] = []
    for record in self.records {
      if record.kind == Regular {
        let entry = WriteMember::new(
          record.name,
          self.data[record.data_offset:record.data_offset + record.size].to_owned(),
          metadata=record.metadata,
        )
        write_member_valid(entry, members.length())
        members.push(entry)
      }
    }
    Ok({ members, })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
fn write_add(
  total : Int,
  amount : Int,
  maximum : Int,
  index : Int?,
  message : String,
) -> Int raise InvalidWrite {
  if amount > maximum - total {
    write_reject("WR003", index, message)
  }
  total + amount
}

///|
fn write_record_end(
  offset : Int,
  size : Int,
  maximum : Int,
  index : Int?,
) -> Int raise InvalidWrite {
  let offset = write_add(
    offset, 60, maximum, index, "archive byte limit exceeded",
  )
  let offset = write_add(
    offset, size, maximum, index, "archive byte limit exceeded",
  )
  write_add(offset, size % 2, maximum, index, "archive byte limit exceeded")
}

///|
fn write_gnu_short_name(name : Bytes) -> Bool {
  // "#1/" is the BSD embedded-name marker, even inside a GNU archive.
  if name.length() > 15 || name == b"#1" {
    return false
  }
  for byte in name {
    if byte == b'/' || byte <= b' ' {
      return false
    }
  }
  true
}

///|
fn write_field(output : @buffer.Buffer, text : Bytes, width : Int) -> Unit {
  output.write_bytes(text[:])
  for i = text.length(); i < width; i = i + 1 {
    output.write_byte(b' ')
  }
}

///|
fn write_number_field(
  output : @buffer.Buffer,
  value : Int64?,
  width : Int,
  radix : Int,
) -> Unit {
  let text = match value {
    None => b""
    Some(value) => @utf8.encode(value.to_string(radix~))
  }
  write_field(output, text, width)
}

///|
fn write_header(
  output : @buffer.Buffer,
  name : Bytes,
  metadata : Metadata,
  size : Int,
) -> Unit {
  write_field(output, name, 16)
  write_number_field(output, metadata.timestamp, 12, 10)
  write_number_field(output, metadata.uid, 6, 10)
  write_number_field(output, metadata.gid, 6, 10)
  write_number_field(output, metadata.mode, 8, 8)
  write_number_field(output, Some(size.to_int64()), 10, 10)
  output.write_bytes(b"`\n"[:])
}

///|
fn write_padding(output : @buffer.Buffer, size : Int) -> Unit {
  if size % 2 == 1 {
    output.write_byte(b'\n')
  }
}

///|
/// Write a regular archive after validating its complete layout and budgets.
/// GNU uses a deduplicated long-name table; BSD uses embedded names.
/// `symbols=None` omits the index; `Some([])` writes an empty GNU32 index.
/// GNU32 mappings refer to final ordinary-entry positions and preserve order.
/// Symbol extraction from object files and BSD index writing are not performed.
/// Limits count physical records, expanded names and final serialized bytes.
pub fn ArchiveBuilder::write(
  self : ArchiveBuilder,
  format? : WriteFormat = Gnu,
  metadata? : WriteMetadata = Deterministic,
  symbols? : Array[WriteSymbol]? = None,
  max_bytes? : Int = 67108864,
  max_members? : Int = 100000,
  max_name_bytes? : Int = 67108864,
  max_symbols? : Int = 1000000,
  max_symbol_name_bytes? : Int = 67108864,
) -> Result[Bytes, WriteError] {
  try {
    if max_bytes < 0 ||
      max_members < 0 ||
      max_name_bytes < 0 ||
      max_symbols < 0 ||
      max_symbol_name_bytes < 0 {
      write_reject("WR003", None, "limits must be nonnegative")
    }
    if self.members.length() > max_members {
      write_reject("WR003", None, "archive entry limit exceeded")
    }
    let mut total_names = 0
    let mut table_size = 0
    let name_offsets : Map[Bytes, Int] = Map([])
    let table_names : Array[Bytes] = []
    let sizes : Array[Int] = []
    for index, entry in self.members {
      write_member_valid(entry, index)
      total_names = write_add(
        total_names,
        entry.name.length(),
        max_name_bytes,
        Some(index),
        "expanded entry-name byte limit exceeded",
      )
      let mut size = entry.data.length()
      if size > max_bytes {
        write_reject("WR003", Some(index), "archive byte limit exceeded")
      }
      match format {
        Gnu => {
          if entry.name.find(b"\n"[:]) is Some(_) {
            write_reject(
              "WR001",
              Some(index),
              "GNU member name contains a newline",
            )
          }
          if !write_gnu_short_name(entry.name) &&
            name_offsets.get(entry.name) is None {
            name_offsets[entry.name] = table_size
            table_names.push(entry.name)
            table_size = write_add(
              table_size,
              entry.name.length(),
              max_bytes,
              Some(index),
              "archive byte limit exceeded",
            )
            table_size = write_add(
              table_size,
              2,
              max_bytes,
              Some(index),
              "archive byte limit exceeded",
            )
          }
        }
        Bsd =>
          size = write_add(
            size,
            entry.name.length(),
            max_bytes,
            Some(index),
            "archive byte limit exceeded",
          )
      }
      sizes.push(size)
    }
    let mut index_size = 0
    if symbols is Some(symbols) {
      if format != Gnu {
        write_reject("WR005", None, "symbol-index writing requires GNU format")
      }
      if symbols.length() > max_symbols {
        write_reject("WR003", None, "symbol count limit exceeded")
      }
      index_size = write_add(
        0,
        4,
        max_bytes,
        None,
        "archive byte limit exceeded",
      )
      let mut symbol_names = 0
      for symbol in symbols {
        if symbol.member_index < 0 ||
          symbol.member_index >= self.members.length() {
          write_reject(
            "WR005",
            Some(symbol.member_index),
            "symbol target is outside the ordinary members",
          )
        }
        if symbol.name.is_empty() {
          write_reject(
            "WR005",
            Some(symbol.member_index),
            "symbol name must not be empty",
          )
        }
        for byte in symbol.name {
          if byte == b'\x00' {
            write_reject(
              "WR005",
              Some(symbol.member_index),
              "NUL inside symbol name",
            )
          }
        }
        symbol_names = write_add(
          symbol_names,
          symbol.name.length(),
          max_symbol_name_bytes,
          Some(symbol.member_index),
          "symbol-name byte limit exceeded",
        )
        index_size = write_add(
          index_size,
          5,
          max_bytes,
          None,
          "archive byte limit exceeded",
        )
        index_size = write_add(
          index_size,
          symbol.name.length(),
          max_bytes,
          None,
          "archive byte limit exceeded",
        )
      }
    }
    let mut count = self.members.length()
    let mut offset = write_add(
      0,
      8,
      max_bytes,
      None,
      "archive byte limit exceeded",
    )
    if symbols is Some(_) {
      count = write_add(
        count,
        1,
        max_members,
        None,
        "archive entry limit exceeded",
      )
      total_names = write_add(
        total_names,
        1,
        max_name_bytes,
        None,
        "expanded entry-name byte limit exceeded",
      )
      offset = write_record_end(offset, index_size, max_bytes, None)
    }
    if table_size > 0 {
      count = write_add(
        count,
        1,
        max_members,
        None,
        "archive entry limit exceeded",
      )
      total_names = write_add(
        total_names,
        2,
        max_name_bytes,
        None,
        "expanded entry-name byte limit exceeded",
      )
      offset = write_record_end(offset, table_size, max_bytes, None)
    }
    ignore(count)
    ignore(total_names)
    let headers : Array[Int] = []
    for index, size in sizes {
      headers.push(offset)
      offset = write_record_end(offset, size, max_bytes, Some(index))
    }
    // Allocation happens only after every field, reference and output size passes.
    let output = @buffer.Buffer(size_hint=offset)
    output.write_bytes(b"!<arch>\n"[:])
    let special_metadata : Metadata = {
      timestamp: None,
      uid: None,
      gid: None,
      mode: None,
    }
    if symbols is Some(symbols) {
      write_header(output, b"/", special_metadata, index_size)
      output.write_int_be(symbols.length())
      for symbol in symbols {
        output.write_int_be(headers[symbol.member_index])
      }
      for symbol in symbols {
        output.write_bytes(symbol.name[:])
        output.write_byte(b'\x00')
      }
      write_padding(output, index_size)
    }
    if table_size > 0 {
      write_header(output, b"//", special_metadata, table_size)
      for name in table_names {
        output.write_bytes(name[:])
        output.write_bytes(b"/\n"[:])
      }
      write_padding(output, table_size)
    }
    let deterministic : Metadata = {
      timestamp: Some(0L),
      uid: Some(0L),
      gid: Some(0L),
      mode: Some(420L),
    }
    for index, entry in self.members {
      let header_name = match format {
        Gnu =>
          match name_offsets.get(entry.name) {
            Some(reference) => @utf8.encode("/\{reference}")
            None => entry.name + b"/"
          }
        Bsd => @utf8.encode("#1/\{entry.name.length()}")
      }
      write_header(
        output,
        header_name,
        if metadata == Deterministic {
          deterministic
        } else {
          entry.metadata
        },
        sizes[index],
      )
      if format == Bsd {
        output.write_bytes(entry.name[:])
      }
      output.write_bytes(entry.data[:])
      write_padding(output, sizes[index])
    }
    Ok(output.to_bytes())
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub extend WriteFormat with Eq::{equal, not_equal}

///|
pub extend WriteFormat with Debug::{to_repr}

///|
pub extend WriteMetadata with Eq::{equal, not_equal}

///|
pub extend WriteMetadata with Debug::{to_repr}

///|
pub extend WriteMember with Eq::{equal, not_equal}

///|
pub extend WriteMember with Debug::{to_repr}

///|
pub extend WriteSymbol with Eq::{equal, not_equal}

///|
pub extend WriteSymbol with Debug::{to_repr}

///|
pub extend WriteError with Eq::{equal, not_equal}

///|
pub extend WriteError with Debug::{to_repr}

///|
pub extend ArchiveBuilder with Debug::{to_repr}
