///|
/// An external thin-archive member. The path is interpreted relative to the
/// archive file; size describes the external file, which is never embedded.
pub(all) struct ThinWriteMember {
  name : Bytes
  size : Int
  metadata : Metadata
} derive(Eq, Debug)

///|
pub fn ThinWriteMember::new(
  name : Bytes,
  size : Int,
  metadata? : Metadata = {
    timestamp: Some(0L),
    uid: Some(0L),
    gid: Some(0L),
    mode: Some(420L),
  },
) -> ThinWriteMember {
  { name, size, metadata, }
}

///|
/// An immutable editing plan for GNU thin archives. Every position is an
/// ordinary-member position, excluding the symbol and name tables.
struct ThinArchiveBuilder {
  members : Array[ThinWriteMember]
} derive(Debug)

///|
pub fn ThinArchiveBuilder::new() -> ThinArchiveBuilder {
  { members: [], }
}

///|
fn thin_write_member_valid(
  entry : ThinWriteMember,
  index : Int,
) -> Unit raise InvalidWrite {
  if entry.size < 0 {
    write_reject(
      "WR001",
      Some(index),
      "external member size must be nonnegative",
    )
  }
  if entry.name.find(b"\n"[:]) is Some(_) {
    write_reject("WR001", Some(index), "GNU member path contains a newline")
  }
  // Writing stores names and performs no file I/O. Parent components are legal
  // relative references; loading retains its own explicit path-policy choice.
  ignore(thin_relative_path(entry.name, 0, allow_parent_paths=true)) catch {
    InvalidArchive(error) => write_reject("WR001", Some(index), error.message)
  }
  // Reuse the numeric-field validation without reserving regular-archive
  // special spellings: thin name-table entries are always external members.
  write_member_valid(
    WriteMember::new(b"member", b"", metadata=entry.metadata),
    index,
  )
}

///|
/// Validate and copy a collection once, preserving exact path bytes and order.
pub fn ThinArchiveBuilder::from_members(
  entries : Array[ThinWriteMember],
) -> Result[ThinArchiveBuilder, WriteError] {
  try {
    for index, entry in entries {
      thin_write_member_valid(entry, index)
    }
    Ok({ members: entries.copy(), })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ThinArchiveBuilder::member_count(self : ThinArchiveBuilder) -> Int {
  self.members.length()
}

///|
pub fn ThinArchiveBuilder::members(
  self : ThinArchiveBuilder,
) -> Array[ThinWriteMember] {
  self.members.copy()
}

///|
pub fn ThinArchiveBuilder::insert(
  self : ThinArchiveBuilder,
  index : Int,
  entry : ThinWriteMember,
) -> Result[ThinArchiveBuilder, WriteError] {
  try {
    if index < 0 || index > self.members.length() {
      write_reject(
        "WR001",
        Some(index),
        "insert position is outside the archive",
      )
    }
    thin_write_member_valid(entry, index)
    let members = self.members.copy()
    members.insert(index, entry)
    Ok({ members, })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ThinArchiveBuilder::append(
  self : ThinArchiveBuilder,
  entry : ThinWriteMember,
) -> Result[ThinArchiveBuilder, WriteError] {
  self.insert(self.members.length(), entry)
}

///|
pub fn ThinArchiveBuilder::replace(
  self : ThinArchiveBuilder,
  index : Int,
  entry : ThinWriteMember,
) -> Result[ThinArchiveBuilder, WriteError] {
  try {
    if index < 0 || index >= self.members.length() {
      write_reject("WR001", Some(index), "entry index is outside the archive")
    }
    thin_write_member_valid(entry, index)
    let members = self.members.copy()
    members[index] = entry
    Ok({ members, })
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub fn ThinArchiveBuilder::remove(
  self : ThinArchiveBuilder,
  index : Int,
) -> Result[ThinArchiveBuilder, WriteError] {
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
/// Move an entry to its final zero-based position.
pub fn ThinArchiveBuilder::move_member(
  self : ThinArchiveBuilder,
  from : Int,
  to : Int,
) -> Result[ThinArchiveBuilder, WriteError] {
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
/// Import external references without loading files. Rebuilt symbol mappings
/// must be supplied after editing; dropping an existing index is explicit.
pub fn ThinArchive::edit(
  self : ThinArchive,
  drop_symbol_indexes? : Bool = false,
) -> Result[ThinArchiveBuilder, WriteError] {
  if !self.archive.indexes.is_empty() && !drop_symbol_indexes {
    return Err({
      code: "WR004",
      member_index: None,
      message: "choose drop_symbol_indexes=true and supply fresh symbols when writing",
    })
  }
  let members : Array[ThinWriteMember] = []
  for entry in self.archive.records {
    if entry.kind == Regular {
      members.push(
        ThinWriteMember::new(entry.name, entry.size, metadata=entry.metadata),
      )
    }
  }
  ThinArchiveBuilder::from_members(members)
}

///|
/// Load all external members into a regular-archive editing plan. max_bytes
/// bounds total payload bytes. All paths and declared sizes are checked before
/// the first loader call. Names, order and metadata are preserved. The loader
/// owns base-directory resolution, symlink policy and I/O allocation.
pub fn ThinArchive::materialize(
  self : ThinArchive,
  loader : (Bytes, Int) -> Result[Bytes, String],
  drop_symbol_indexes? : Bool = false,
  allow_parent_paths? : Bool = false,
  max_bytes? : Int = 67108864,
) -> Result[ArchiveBuilder, ParseError] {
  if max_bytes < 0 {
    return Err({
      code: "AR008",
      offset: 0,
      message: "limits must be nonnegative",
    })
  }
  if !self.archive.indexes.is_empty() && !drop_symbol_indexes {
    return Err({
      code: "AR011",
      offset: 0,
      message: "materialization requires drop_symbol_indexes=true and fresh symbol discovery when writing",
    })
  }
  let paths : Array[(Int, Bytes)] = []
  let mut total = 0
  for index, entry in self.archive.records {
    if entry.kind == Regular {
      let path = match self.member_path(index, allow_parent_paths~) {
        Ok(path) => path
        Err(error) => return Err(error)
      }
      if entry.size > max_bytes - total {
        return Err({
          code: "AR008",
          offset: entry.header_offset,
          message: "total external member byte limit exceeded",
        })
      }
      // Ensure the target regular format can represent every name before I/O.
      write_member_valid(
        WriteMember::new(entry.name, b"", metadata=entry.metadata),
        index,
      ) catch {
        InvalidWrite(error) =>
          return Err({
            code: "AR011",
            offset: entry.header_offset,
            message: error.message,
          })
      }
      total += entry.size
      paths.push((index, path))
    }
  }
  let members : Array[WriteMember] = []
  for (index, path) in paths {
    let entry = self.archive.records[index]
    let bytes = match loader(path, entry.size) {
      Err(message) =>
        return Err({ code: "AR013", offset: entry.header_offset, message, })
      Ok(bytes) => bytes
    }
    if bytes.length() != entry.size {
      return Err({
        code: "AR014",
        offset: entry.header_offset,
        message: "external member size differs from its archive header",
      })
    }
    members.push(WriteMember::new(entry.name, bytes, metadata=entry.metadata))
  }
  Ok({ members, })
}

///|
/// Write GNU thin bytes without reading or embedding any external file.
/// All paths use a deduplicated GNU name table. symbols=None omits the index;
/// Some([]) emits an empty index. symbol_width selects 32 or 64 bit GNU offsets.
/// Symbol targets are final ordinary-member positions after editing.
/// Byte limits cover serialized archive bytes, not the external payload sizes.
pub fn ThinArchiveBuilder::write(
  self : ThinArchiveBuilder,
  metadata? : WriteMetadata = Deterministic,
  symbols? : Array[WriteSymbol]? = None,
  symbol_width? : Int = 32,
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
    if symbol_width != 32 && symbol_width != 64 {
      write_reject("WR005", None, "symbol width must be 32 or 64")
    }
    if self.members.length() > max_members {
      write_reject("WR003", None, "archive entry limit exceeded")
    }
    let width = symbol_width / 8
    let index_name = if symbol_width == 32 { b"/" } else { b"/SYM64/" }
    let mut total_names = 0
    let mut table_size = 0
    let name_offsets : Map[Bytes, Int] = Map([])
    let table_names : Array[Bytes] = []
    for index, entry in self.members {
      thin_write_member_valid(entry, index)
      total_names = write_add(
        total_names,
        entry.name.length(),
        max_name_bytes,
        Some(index),
        "expanded entry-name byte limit exceeded",
      )
      if name_offsets.get(entry.name) is None {
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
    let mut index_size = 0
    if symbols is Some(symbols) {
      if symbols.length() > max_symbols {
        write_reject("WR003", None, "symbol count limit exceeded")
      }
      index_size = write_add(
        0,
        width,
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
          width + 1,
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
        index_name.length(),
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
    for index, _entry in self.members {
      headers.push(offset)
      offset = write_add(
        offset,
        60,
        max_bytes,
        Some(index),
        "archive byte limit exceeded",
      )
    }
    let output = @buffer.Buffer(size_hint=offset)
    output.write_bytes(b"!<thin>\n"[:])
    let special : Metadata = {
      timestamp: None,
      uid: None,
      gid: None,
      mode: None,
    }
    if symbols is Some(symbols) {
      write_header(output, index_name, special, index_size)
      if width == 4 {
        output.write_int_be(symbols.length())
        for symbol in symbols {
          output.write_int_be(headers[symbol.member_index])
        }
      } else {
        output.write_int64_be(symbols.length().to_int64())
        for symbol in symbols {
          output.write_int64_be(headers[symbol.member_index].to_int64())
        }
      }
      for symbol in symbols {
        output.write_bytes(symbol.name[:])
        output.write_byte(b'\x00')
      }
      write_padding(output, index_size)
    }
    if table_size > 0 {
      write_header(output, b"//", special, table_size)
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
    for entry in self.members {
      write_header(
        output,
        @utf8.encode("/\{name_offsets[entry.name]}"),
        if metadata == Deterministic {
          deterministic
        } else {
          entry.metadata
        },
        entry.size,
      )
    }
    Ok(output.to_bytes())
  } catch {
    InvalidWrite(error) => Err(error)
  }
}

///|
pub extend ThinWriteMember with Eq::{equal, not_equal}

///|
pub extend ThinWriteMember with Debug::{to_repr}

///|
pub extend ThinArchiveBuilder with Debug::{to_repr}
