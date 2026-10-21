///|
/// An immutable comparison input with loaded member bytes. The original
/// container bytes and physical record positions remain the source identity.
/// A snapshot does not access external files after construction.
struct ArchiveSnapshot {
  source : Bytes
  archive : Archive
} derive(Debug)

///|
pub extend ArchiveSnapshot with Debug::{to_repr}

///|
/// Ordinary archives already contain every member and need no loader.
pub fn Archive::snapshot(self : Archive) -> ArchiveSnapshot {
  { source: self.data, archive: self, }
}

///|
// Check every declaration and path before requesting any external contents.
fn thin_load_plan(
  archive : ThinArchive,
  max_bytes : Int,
  allow_parent_paths : Bool,
) -> (Array[(Int, Bytes)], Int) raise InvalidArchive {
  if max_bytes < 0 {
    reject("AR008", 0, "limits must be nonnegative")
  }
  let paths : Array[(Int, Bytes)] = []
  let mut total = 0
  for index, entry in archive.archive.records {
    if entry.kind != Regular {
      continue
    }
    let path = match archive.member_path(index, allow_parent_paths~) {
      Ok(path) => path
      Err(error) => raise InvalidArchive(error)
    }
    if entry.size > max_bytes - total {
      reject(
        "AR008",
        entry.header_offset,
        "total external member byte limit exceeded",
      )
    }
    total += entry.size
    paths.push((index, path))
  }
  (paths, total)
}

///|
fn thin_load_bytes(
  entry : Member,
  path : Bytes,
  loader : (Bytes, Int) -> Result[Bytes, String],
) -> Bytes raise InvalidArchive {
  let bytes = match loader(path, entry.size) {
    Ok(bytes) => bytes
    Err(message) => reject("AR013", entry.header_offset, message)
  }
  if bytes.length() != entry.size {
    reject(
      "AR014",
      entry.header_offset,
      "external member size differs from its archive header",
    )
  }
  bytes
}

///|
/// Validate every external member without retaining its contents. Returns the
/// total loaded byte count. Repeated references each count toward max_bytes.
/// Paths and cumulative declared sizes are checked before the first loader call.
pub fn ThinArchive::validate_members(
  self : ThinArchive,
  loader : (Bytes, Int) -> Result[Bytes, String],
  max_bytes? : Int = 67108864,
  allow_parent_paths? : Bool = false,
) -> Result[Int, ParseError] {
  try {
    let (paths, total) = thin_load_plan(self, max_bytes, allow_parent_paths)
    for (index, path) in paths {
      ignore(thin_load_bytes(self.archive.records[index], path, loader))
    }
    Ok(total)
  } catch {
    InvalidArchive(error) => Err(error)
  }
}

///|
/// Load an immutable snapshot for logical comparison with another thin snapshot
/// or an ordinary Archive.snapshot(). Index mappings are retained as parsed;
/// this operation neither discovers symbols nor rewrites the input archive.
/// max_bytes limits cumulative external payloads, separately from container size.
pub fn ThinArchive::snapshot(
  self : ThinArchive,
  loader : (Bytes, Int) -> Result[Bytes, String],
  max_bytes? : Int = 67108864,
  allow_parent_paths? : Bool = false,
) -> Result[ArchiveSnapshot, ParseError] {
  try {
    let (paths, total) = thin_load_plan(self, max_bytes, allow_parent_paths)
    if total > 2147483647 - self.archive.data.length() {
      reject("AR008", 0, "snapshot byte length exceeds the supported range")
    }
    let data = @buffer.Buffer(size_hint=self.archive.data.length() + total)
    data.write_bytes(self.archive.data[:])
    let records = self.archive.records.copy()
    for (index, path) in paths {
      let entry = records[index]
      let bytes = thin_load_bytes(entry, path, loader)
      records[index] = { ..entry, data_offset: data.length(), }
      data.write_bytes(bytes[:])
    }
    // This private view is used only by the comparison engine. It is never
    // exposed as an Archive or serialized as a physical ordinary archive.
    Ok({
      source: self.archive.data,
      archive: {
        data: data.to_bytes(),
        records,
        indexes: self.archive.indexes,
      },
    })
  } catch {
    InvalidArchive(error) => Err(error)
  }
}

///|
/// Compare loaded contents, metadata, order and original symbol mappings.
/// bytes_equal compares the original container bytes. For thin snapshots it can
/// be true while content_equal is false because external contents have changed.
/// Change and ambiguity indices refer to the original physical input records.
pub fn ArchiveSnapshot::compare_logical(
  self : ArchiveSnapshot,
  other : ArchiveSnapshot,
) -> LogicalComparison {
  let result = compare_logical(self.archive, other.archive)
  { ..result, bytes_equal: self.source == other.source, }
}
