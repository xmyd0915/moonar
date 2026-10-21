///|
/// Aggregate limits for archives fetched while resolving GNU archive-offset
/// references. They are separate from the selected external-payload byte limit.
pub(all) struct NestedLimits {
  max_bytes : Int
  max_members : Int
  max_name_bytes : Int
  max_symbols : Int
  max_symbol_name_bytes : Int
  max_depth : Int
} derive(Eq, Debug)

///|
pub fn NestedLimits::new(
  max_bytes? : Int = 67108864,
  max_members? : Int = 100000,
  max_name_bytes? : Int = 67108864,
  max_symbols? : Int = 1000000,
  max_symbol_name_bytes? : Int = 67108864,
  max_depth? : Int = 16,
) -> NestedLimits {
  {
    max_bytes,
    max_members,
    max_name_bytes,
    max_symbols,
    max_symbol_name_bytes,
    max_depth,
  }
}

///|
pub extend NestedLimits with Eq::{equal, not_equal}

///|
pub extend NestedLimits with Debug::{to_repr}

///|
priv enum NestedArchive {
  RegularContainer(Archive, Map[Int, Int])
  ThinContainer(ThinArchive, Map[Int, Int])
}

///|
priv struct NestedLoadContext {
  loader : (Bytes, Int) -> Result[Bytes, String]
  allow_parent_paths : Bool
  max_depth : Int
  payload_limit : Int
  mut bytes_left : Int
  mut members_left : Int
  mut names_left : Int
  mut symbols_left : Int
  mut symbol_names_left : Int
  cache : Map[Bytes, NestedArchive]
  active : Array[(Bytes, Int)]
  sources : Array[Bytes]
  source_set : Map[Bytes, Unit]
}

///|
fn nested_context(
  loader : (Bytes, Int) -> Result[Bytes, String],
  allow_parent_paths : Bool,
  limits : NestedLimits,
  payload_limit : Int,
) -> NestedLoadContext raise InvalidArchive {
  if limits.max_bytes < 0 ||
    limits.max_members < 0 ||
    limits.max_name_bytes < 0 ||
    limits.max_symbols < 0 ||
    limits.max_symbol_name_bytes < 0 ||
    limits.max_depth < 0 ||
    limits.max_depth > 64 {
    reject(
      "AR008", 0, "nested limits must be nonnegative and depth must not exceed 64",
    )
  }
  {
    loader,
    allow_parent_paths,
    payload_limit,
    max_depth: limits.max_depth,
    bytes_left: limits.max_bytes,
    members_left: limits.max_members,
    names_left: limits.max_name_bytes,
    symbols_left: limits.max_symbols,
    symbol_names_left: limits.max_symbol_name_bytes,
    cache: Map([]),
    active: [],
    sources: [],
    source_set: Map([]),
  }
}

///|
fn nested_diagnostic(
  error : ParseError,
  path : Bytes,
  root_offset : Int,
) -> ParseError {
  {
    ..error,
    offset: root_offset,
    message: "nested archive \{Json(@utf8.decode_lossy(path[:], ignore_bom=false)).stringify()} at byte \{error.offset}: \{error.message}",
  }
}

///|
fn NestedLoadContext::read_archive(
  self : NestedLoadContext,
  path : Bytes,
  root_offset : Int,
) -> NestedArchive raise InvalidArchive {
  if self.cache.get(path) is Some(cached) {
    return cached
  }
  if self.bytes_left < 8 {
    reject(
      "AR008", root_offset, "nested archive byte budget cannot hold a container",
    )
  }
  let bytes = match (self.loader)(path, self.bytes_left) {
    Ok(bytes) => bytes
    Err(message) => reject("AR013", root_offset, message)
  }
  if bytes.length() > self.bytes_left {
    reject("AR008", root_offset, "total nested archive byte limit exceeded")
  }
  let thin = bytes.has_prefix(b"!<thin>\n"[:])
  let parsed_thin = if thin {
    match
      parse_thin(
        bytes,
        max_bytes=self.bytes_left,
        max_members=self.members_left,
        max_name_bytes=self.names_left,
        max_symbols=self.symbols_left,
        max_symbol_name_bytes=self.symbol_names_left,
      ) {
      Ok(value) => Some(value)
      Err(error) =>
        raise InvalidArchive(nested_diagnostic(error, path, root_offset))
    }
  } else {
    None
  }
  let archive = match parsed_thin {
    Some(value) => value.archive
    None =>
      match
        parse(
          bytes,
          max_bytes=self.bytes_left,
          max_members=self.members_left,
          max_name_bytes=self.names_left,
          max_symbols=self.symbols_left,
          max_symbol_name_bytes=self.symbol_names_left,
        ) {
        Ok(value) => value
        Err(error) =>
          raise InvalidArchive(nested_diagnostic(error, path, root_offset))
      }
  }
  self.bytes_left -= bytes.length()
  self.members_left -= archive.records.length()
  let headers : Map[Int, Int] = Map([])
  for i, entry in archive.records {
    headers[entry.header_offset] = i
    self.names_left -= entry.name.length()
  }
  for table in archive.indexes {
    let copies = if table.format == "coff" { 2 } else { 1 }
    for _copy in 0..<copies {
      self.symbols_left -= table.symbols.length()
      for symbol in table.symbols {
        self.symbol_names_left -= symbol.name.length()
      }
    }
  }
  let loaded = match parsed_thin {
    Some(value) => ThinContainer(value, headers)
    None => RegularContainer(archive, headers)
  }
  self.cache[path] = loaded
  loaded
}

///|
fn nested_child_path(
  parent : Bytes,
  child : Bytes,
  maximum : Int,
  root_offset : Int,
) -> Bytes raise InvalidArchive {
  let mut cursor = parent.length()
  while cursor > 0 && parent[cursor - 1] != b'/' {
    cursor -= 1
  }
  if cursor > maximum || child.length() > maximum - cursor {
    reject("AR008", root_offset, "resolved nested source-path budget exceeded")
  }
  parent[:cursor].to_owned() + child
}

///|
fn NestedLoadContext::resolve(
  self : NestedLoadContext,
  entry : Member,
  reference : Int?,
  path : Bytes,
  root_offset : Int,
  load_payload? : Bool = true,
) -> WriteMember raise InvalidArchive {
  if self.source_set.get(path) is None {
    if path.length() > self.names_left {
      reject(
        "AR008", root_offset, "resolved nested source-path budget exceeded",
      )
    }
    self.names_left -= path.length()
    self.source_set[path] = ()
    self.sources.push(path)
  }
  guard reference is Some(offset) else {
    if !load_payload {
      return WriteMember::new(entry.name, b"", metadata=entry.metadata)
    }

    let bytes = thin_load_bytes(
      { ..entry, header_offset: root_offset, },
      path,
      self.loader,
      max_bytes=self.payload_limit,
    )
    return WriteMember::new(entry.name, bytes, metadata=entry.metadata)
  }
  if self.active.contains((path, offset)) {
    reject("AR015", root_offset, "cyclic nested archive reference")
  }
  if self.active.length() >= self.max_depth {
    reject("AR008", root_offset, "nested archive depth limit exceeded")
  }
  self.active.push((path, offset))
  let result = match self.read_archive(path, root_offset) {
    RegularContainer(archive, headers) => {
      guard headers.get(offset) is Some(index) &&
        archive.records[index].kind == Regular else {
        reject(
          "AR015", root_offset, "nested offset is not an ordinary member header",
        )
      }
      let target = archive.records[index]
      if target.size != entry.size {
        reject(
          "AR014", root_offset, "nested member size differs from the thin header",
        )
      }
      WriteMember::new(
        target.name,
        if load_payload {
          archive.member_bytes(index).unwrap()
        } else {
          b""
        },
        metadata=entry.metadata,
      )
    }
    ThinContainer(archive, headers) => {
      guard headers.get(offset) is Some(index) &&
        archive.archive.records[index].kind == Regular else {
        reject(
          "AR015", root_offset, "nested offset is not an ordinary thin member header",
        )
      }
      let target = archive.archive.records[index]
      if target.size != entry.size {
        reject(
          "AR014", root_offset, "nested member size differs from the thin header",
        )
      }
      let child = match
        archive.member_path(index, allow_parent_paths=self.allow_parent_paths) {
        Ok(value) => value
        Err(error) =>
          raise InvalidArchive(nested_diagnostic(error, path, root_offset))
      }
      let resolved = self.resolve(
        target,
        archive.references.get(index),
        nested_child_path(path, child, self.names_left, root_offset),
        root_offset,
        load_payload~,
      )
      { ..resolved, metadata: entry.metadata, }
    }
  }
  ignore(self.active.pop())
  result
}

///|
/// Resolve one ordinary external member, retaining the outer thin metadata.
/// Nested references return the referenced member's logical name and payload.
/// A direct loader request carries the exact declared size; a container request
/// carries the remaining archive-byte budget. The loader controls actual reads.
pub fn ThinArchive::resolve_member(
  self : ThinArchive,
  index : Int,
  loader : (Bytes, Int) -> Result[Bytes, String],
  max_bytes? : Int = 67108864,
  allow_parent_paths? : Bool = false,
  nested_limits? : NestedLimits = NestedLimits::new(),
) -> Result[WriteMember, ParseError] {
  try {
    if max_bytes < 0 {
      reject("AR008", 0, "limits must be nonnegative")
    }
    let context = nested_context(
      loader, allow_parent_paths, nested_limits, max_bytes,
    )
    let path = match self.member_path(index, allow_parent_paths~) {
      Ok(path) => path
      Err(error) => raise InvalidArchive(error)
    }
    let entry = self.archive.records[index]
    if entry.size > max_bytes {
      reject(
        "AR008",
        entry.header_offset,
        "external member byte limit exceeded",
      )
    }
    Ok(
      context.resolve(
        entry,
        self.references.get(index),
        path,
        entry.header_offset,
      ),
    )
  } catch {
    InvalidArchive(error) => Err(error)
  }
}

///|
/// Return portable source paths reached by direct and archive-offset references.
/// Archive containers are parsed and cached, while direct payload files are not
/// opened. Useful for dependency manifests and output-alias protection.
pub fn ThinArchive::member_sources(
  self : ThinArchive,
  loader : (Bytes, Int) -> Result[Bytes, String],
  allow_parent_paths? : Bool = false,
  nested_limits? : NestedLimits = NestedLimits::new(),
) -> Result[Array[Bytes], ParseError] {
  try {
    let context = nested_context(
      loader, allow_parent_paths, nested_limits, 2147483647,
    )
    let paths : Array[(Int, Bytes)] = []
    for index, entry in self.archive.records {
      if entry.kind == Regular {
        let path = match self.member_path(index, allow_parent_paths~) {
          Ok(path) => path
          Err(error) => raise InvalidArchive(error)
        }
        paths.push((index, path))
      }
    }
    for (index, path) in paths {
      let entry = self.archive.records[index]
      ignore(
        context.resolve(
          entry,
          self.references.get(index),
          path,
          entry.header_offset,
          load_payload=false,
        ),
      )
    }
    Ok(context.sources.copy())
  } catch {
    InvalidArchive(error) => Err(error)
  }
}
