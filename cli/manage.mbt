///|
priv suberror ManageFailure {
  ManageFailure(String, String)
}

///|
fn[T] manage_fail(code : String, message : String) -> T raise ManageFailure {
  raise ManageFailure(code, message)
}

///|
fn[T] manage_written(
  value : Result[T, @ar.WriteError],
) -> T raise ManageFailure {
  match value {
    Ok(value) => value
    Err(error) =>
      manage_fail(
        error.code,
        (match error.member_index {
          Some(index) => "member \{index}: "
          None => ""
        }) +
        error.message,
      )
  }
}

///|
fn[T] manage_parsed(value : Result[T, @ar.ParseError]) -> T raise ManageFailure {
  match value {
    Ok(value) => value
    Err(error) =>
      manage_fail(error.code, "byte \{error.offset}: \{error.message}")
  }
}

///|
fn path_text(name : Bytes) -> String raise ManageFailure {
  @utf8.decode(name[:], ignore_bom=false) catch {
    _ => manage_fail("IO003", "filesystem member paths must be UTF-8")
  }
}

///|
fn slash_path(path : String) -> String {
  path.replace_all(old="\\", new="/")
}

///|
fn path_dir(path : String) -> String {
  let parts = slash_path(path).split("/").map(p => p.to_owned()).to_array()
  ignore(parts.pop())
  let result = parts.join("/")
  if result.is_empty() {
    if slash_path(path).has_prefix("/") {
      "/"
    } else {
      "."
    }
  } else {
    result
  }
}

///|
fn path_name(path : String) -> String {
  slash_path(path).split("/").last().unwrap_or("").to_owned()
}

///|
fn clean_path(path : String) -> String {
  let path = slash_path(path)
  let absolute = path.has_prefix("/")
  let parts : Array[String] = []
  for part in path.split("/") {
    if part == "" || part == "." {
      continue
    }
    if part == ".." &&
      !parts.is_empty() &&
      parts[parts.length() - 1] != ".." &&
      !parts[parts.length() - 1].has_suffix(":") {
      ignore(parts.pop())
    } else if part != ".." || !absolute {
      parts.push(part.to_owned())
    }
  }
  let prefix = if path.has_prefix("//") {
    "//"
  } else if absolute {
    "/"
  } else {
    ""
  }
  let result = prefix + parts.join("/")
  if result.is_empty() {
    "."
  } else {
    result
  }
}

///|
fn joined_path(base : String, relative : String) -> String {
  base + "/" + relative
}

///|
// Resolve existing files through links. For a new output the existing parent
// supplies the real directory, so absolute/relative and directory aliases agree.
fn output_path_identity(
  path : String,
  canonical : (String) -> Result[String, String],
) -> String raise ManageFailure {
  match canonical(path) {
    Ok(path) => clean_path(path)
    Err(_) =>
      match canonical(path_dir(path)) {
        Ok(parent) => clean_path(joined_path(parent, path_name(path)))
        Err(message) =>
          manage_fail("IO003", "cannot resolve output directory: \{message}")
      }
  }
}

///|
fn same_path_identity(left : String, right : String) -> Bool {
  let left = clean_path(left)
  let right = clean_path(right)
  // Canonical Windows drive and UNC paths have case-insensitive spelling.
  // POSIX paths retain their case-sensitive names.
  let windows = left.has_prefix("//") ||
    right.has_prefix("//") ||
    (left.length() >= 2 && left[1] == ':') ||
    (right.length() >= 2 && right[1] == ':')
  if windows {
    left.to_lower() == right.to_lower()
  } else {
    left == right
  }
}

///|
fn protected_thin_path(
  archive_path : String,
  name : Bytes,
  canonical : (String) -> Result[String, String],
) -> String raise ManageFailure {
  let base = match canonical(path_dir(archive_path)) {
    Ok(base) => base
    Err(message) =>
      manage_fail("IO003", "cannot resolve archive directory: \{message}")
  }
  let target = joined_path(base, path_text(name))
  match canonical(target) {
    Ok(path) => clean_path(path)
    Err(_) =>
      match canonical(path_dir(target)) {
        Ok(parent) => clean_path(joined_path(parent, path_name(target)))
        // Metadata-only edits can remove missing references. An unresolved
        // ancestor cannot alias an output whose parent must already exist.
        Err(_) => clean_path(target)
      }
  }
}

///|
fn resolved_reference(
  base : String,
  target : String,
  canonical : (String) -> Result[String, String],
) -> String raise ManageFailure {
  let base = match canonical(base) {
    Ok(path) => path
    Err(error) => manage_fail("IO003", error)
  }
  let target = match canonical(target) {
    Ok(path) => path
    Err(error) => manage_fail("IO003", error)
  }
  relative_path(base, target)
}

///|
// Both arguments are interpreted against the same process working directory.
fn relative_path(base : String, target : String) -> String raise ManageFailure {
  let base = clean_path(base)
  let target = clean_path(target)
  let a = base
    .split("/")
    .filter(p => p != ".")
    .map(p => p.to_owned())
    .to_array()
  let b = target
    .split("/")
    .filter(p => p != ".")
    .map(p => p.to_owned())
    .to_array()
  let drive_path = (!a.is_empty() && a[0].has_suffix(":")) ||
    (!b.is_empty() && b[0].has_suffix(":"))
  let unc_base = base.has_prefix("//")
  let unc_target = target.has_prefix("//")
  if base.has_prefix("/") != target.has_prefix("/") ||
    unc_base != unc_target ||
    (
      drive_path &&
      (a.is_empty() || b.is_empty() || a[0].to_lower() != b[0].to_lower())
    ) {
    manage_fail(
      "IO003", "thin paths must use the same root and consistent absolute or relative paths",
    )
  }
  if unc_base {
    let root_a = base
      .split("/")
      .filter(p => p != "")
      .map(p => p.to_owned())
      .to_array()
    let root_b = target
      .split("/")
      .filter(p => p != "")
      .map(p => p.to_owned())
      .to_array()
    if root_a.length() < 2 ||
      root_b.length() < 2 ||
      root_a[0].to_lower() != root_b[0].to_lower() ||
      root_a[1].to_lower() != root_b[1].to_lower() {
      manage_fail("IO003", "thin paths cannot cross UNC server or share roots")
    }
  }
  let mut common = 0
  while common < a.length() &&
        common < b.length() &&
        // Canonical directory spellings can identify different files in a
        // case-sensitive Windows directory. Only root names ignore case.
        (if (drive_path && common == 0) || (unc_base && common < 4) {
          a[common].to_lower() == b[common].to_lower()
        } else {
          a[common] == b[common]
        }) {
    common += 1
  }
  let result : Array[String] = []
  for i = common; i < a.length(); i = i + 1 {
    result.push("..")
  }
  for i = common; i < b.length(); i = i + 1 {
    result.push(b[i])
  }
  let result = result.join("/")
  if result.is_empty() {
    manage_fail("IO003", "thin member cannot refer to its archive directory")
  }
  result
}

///|
fn read_managed(
  path : String,
  request : Request,
  read : (String) -> Result[Bytes, String],
) -> Bytes raise ManageFailure {
  let bytes = match read(path) {
    Ok(bytes) => bytes
    Err(error) => manage_fail("IO001", "\{path}: \{error}")
  }
  if bytes.length() > request.max_bytes {
    manage_fail("AR008", "input exceeds --max-bytes")
  }
  bytes
}

///|
fn parse_managed(
  bytes : Bytes,
  request : Request,
) -> @ar.Archive raise ManageFailure {
  manage_parsed(
    @ar.parse(
      bytes,
      max_bytes=request.max_bytes,
      max_members=request.max_members,
      max_name_bytes=request.max_name_bytes,
      max_symbols=request.max_symbols,
      max_symbol_name_bytes=request.max_symbol_name_bytes,
    ),
  )
}

///|
fn parse_managed_thin(
  bytes : Bytes,
  request : Request,
) -> @ar.ThinArchive raise ManageFailure {
  manage_parsed(
    @ar.parse_thin(
      bytes,
      max_bytes=request.max_bytes,
      max_members=request.max_members,
      max_name_bytes=request.max_name_bytes,
      max_symbols=request.max_symbols,
      max_symbol_name_bytes=request.max_symbol_name_bytes,
    ),
  )
}

///|
fn load_reference(
  archive_path : String,
  entry : @ar.ThinWriteMember,
  options : ManageOptions,
  request : Request,
  read : (String) -> Result[Bytes, String],
  validate_path : (String, String) -> Result[Unit, String],
) -> @ar.WriteMember raise ManageFailure {
  // Use the public path/size policy even for newly created plans.
  let probe = manage_written(@ar.ThinArchiveBuilder::from_members([entry]))
  let bytes = manage_written(probe.write(max_bytes=request.max_bytes))
  let archive = manage_parsed(@ar.parse_thin(bytes))
  let mut ordinary = 0
  for i = 0; i < archive.member_count(); i = i + 1 {
    if archive.get_member(i).unwrap().kind == @ar.Regular {
      ordinary = i
      break
    }
  }
  manage_parsed(
    archive.resolve_member(
      ordinary,
      external_reader(archive_path, options.allow_parent, read, validate_path),
      max_bytes=request.max_bytes,
      allow_parent_paths=options.allow_parent,
      nested_limits=nested_limits(request),
    ),
  )
}

///|
fn run_manage(
  request : Request,
  options : ManageOptions,
  read : (String) -> Result[Bytes, String],
  write : (String, Bytes, Bool) -> Result[Unit, String],
  validate_path : (String, String) -> Result[Unit, String],
  canonical : (String) -> Result[String, String],
) -> Reply {
  try {
    let args = options.arguments
    let operation = options.operation
    let source = args[0]
    let destination = if operation == "extract" {
      args[2]
    } else if operation == "convert" {
      args[1]
    } else {
      options.output.unwrap_or(source)
    }
    let mut regular = @ar.ArchiveBuilder::new()
    let mut thin_plan = @ar.ThinArchiveBuilder::new()
    let mut is_thin = options.thin
    let mut original_thin : @ar.ThinArchive? = None
    let protected_members : Array[String] = []
    if operation != "create" {
      let input = read_managed(source, request, read)
      is_thin = input.has_prefix(b"!<thin>\n"[:])
      if is_thin {
        let archive = parse_managed_thin(input, request)
        original_thin = Some(archive)
        thin_plan = manage_written(archive.edit(drop_symbol_indexes=true))
        for entry in thin_plan.members() {
          protected_members.push(
            protected_thin_path(source, entry.name, canonical),
          )
        }
      } else {
        regular = manage_written(
          parse_managed(input, request).edit(drop_symbol_indexes=true),
        )
      }
    }
    // Positional edits select ordinary members, so a name table never shifts the selection.
    if operation == "create" || operation == "add" {
      let position = options.at.unwrap_or(
        if is_thin {
          thin_plan.member_count()
        } else {
          regular.member_count()
        },
      )
      let old_regular = regular.members()
      let old_thin = thin_plan.members()
      let count = if is_thin { old_thin.length() } else { old_regular.length() }
      if position < 0 || position > count {
        manage_fail("WR001", "insert position is outside the archive")
      }
      if count > request.max_members ||
        args.length() - 1 > request.max_members - count {
        manage_fail("WR003", "archive entry limit exceeded")
      }
      let next_regular : Array[@ar.WriteMember] = []
      let next_thin : Array[@ar.ThinWriteMember] = []
      for i in 0..<position {
        if is_thin {
          next_thin.push(old_thin[i])
        } else {
          next_regular.push(old_regular[i])
        }
      }
      let mut total_payload = old_regular.fold(init=0, fn(total, entry) {
        total + entry.data.length()
      })
      for i = 1; i < args.length(); i = i + 1 {
        let payload = read_managed(args[i], request, read)
        if is_thin {
          let name = resolved_reference(path_dir(source), args[i], canonical)
          if clean_path(joined_path(path_dir(source), name)) ==
            clean_path(source) {
            manage_fail(
              "IO003", "thin member cannot refer to the output archive",
            )
          }
          if payload.has_prefix(b"!<arch>\n"[:]) {
            let archive = parse_managed(payload, request)
            for j in 0..<archive.member_count() {
              let entry = archive.get_member(j).unwrap()
              if entry.kind == @ar.Regular {
                next_thin.push(
                  @ar.ThinWriteMember::new(
                    @utf8.encode(name),
                    entry.size,
                    metadata=entry.metadata,
                    archive_member_offset=Some(entry.header_offset),
                  ),
                )
              }
            }
          } else if payload.has_prefix(b"!<thin>\n"[:]) {
            let archive = parse_managed_thin(payload, request)
            for
              entry in manage_written(archive.edit(drop_symbol_indexes=true)).members() {
              let path = joined_path(path_dir(args[i]), path_text(entry.name))
              next_thin.push({
                ..entry,
                name: @utf8.encode(
                  resolved_reference(path_dir(source), path, canonical),
                ),
              })
            }
          } else {
            next_thin.push(
              @ar.ThinWriteMember::new(@utf8.encode(name), payload.length()),
            )
          }
          if next_thin.length() > request.max_members - (count - position) {
            manage_fail("WR003", "archive entry limit exceeded")
          }
        } else {
          if payload.length() > request.max_bytes - total_payload {
            manage_fail("WR003", "total member data exceed --max-bytes")
          }
          total_payload += payload.length()
          next_regular.push(
            @ar.WriteMember::new(@utf8.encode(path_name(args[i])), payload),
          )
        }
      }
      for i = position; i < count; i = i + 1 {
        if is_thin {
          next_thin.push(old_thin[i])
        } else {
          next_regular.push(old_regular[i])
        }
      }
      if is_thin {
        thin_plan = manage_written(
          @ar.ThinArchiveBuilder::from_members(next_thin),
        )
      } else {
        regular = manage_written(@ar.ArchiveBuilder::from_members(next_regular))
      }
    } else if operation == "replace" {
      let index = limit_number(args[1]).unwrap()
      let payload = read_managed(args[2], request, read)
      if is_thin {
        thin_plan = manage_written(
          thin_plan.replace(
            index,
            @ar.ThinWriteMember::new(
              @utf8.encode(
                resolved_reference(path_dir(source), args[2], canonical),
              ),
              payload.length(),
            ),
          ),
        )
      } else {
        guard regular.members().get(index) is Some(old) else {
          manage_fail("WR001", "member index is outside the archive")
        }
        regular = manage_written(
          regular.replace(
            index,
            @ar.WriteMember::new(old.name, payload, metadata=old.metadata),
          ),
        )
      }
    } else if operation == "delete" {
      let positions : Map[Int, Unit] = Map([])
      let count = if is_thin {
        thin_plan.member_count()
      } else {
        regular.member_count()
      }
      for i = 1; i < args.length(); i = i + 1 {
        let index = limit_number(args[i]).unwrap()
        if index < 0 || index >= count {
          manage_fail("WR001", "deletion index is outside the archive")
        }
        if positions.get(index) is Some(_) {
          manage_fail("WR001", "duplicate deletion index")
        }
        positions[index] = ()
      }
      if is_thin {
        let kept : Array[@ar.ThinWriteMember] = []
        for index, entry in thin_plan.members() {
          if positions.get(index) is None {
            kept.push(entry)
          }
        }
        thin_plan = manage_written(@ar.ThinArchiveBuilder::from_members(kept))
      } else {
        let kept : Array[@ar.WriteMember] = []
        for index, entry in regular.members() {
          if positions.get(index) is None {
            kept.push(entry)
          }
        }
        regular = manage_written(@ar.ArchiveBuilder::from_members(kept))
      }
    } else if operation == "move" {
      let from = limit_number(args[1]).unwrap()
      let to = limit_number(args[2]).unwrap()
      if is_thin {
        thin_plan = manage_written(thin_plan.move_member(from, to))
      } else {
        regular = manage_written(regular.move_member(from, to))
      }
    } else if operation == "rename" {
      let index = limit_number(args[1]).unwrap()
      if is_thin {
        guard thin_plan.members().get(index) is Some(old) else {
          manage_fail("WR001", "member index is outside the archive")
        }
        thin_plan = manage_written(
          thin_plan.replace(index, { ..old, name: @utf8.encode(args[2]), }),
        )
      } else {
        guard regular.members().get(index) is Some(old) else {
          manage_fail("WR001", "member index is outside the archive")
        }
        regular = manage_written(
          regular.replace(index, { ..old, name: @utf8.encode(args[2]), }),
        )
      }
    }
    if is_thin {
      for entry in thin_plan.members() {
        protected_members.push(
          protected_thin_path(source, entry.name, canonical),
        )
      }
    }
    let destination_identity = output_path_identity(destination, canonical)
    // Resolve container dependencies before any output write, including edits
    // that do not load payloads. Removing broken references in place stays possible.
    let source_identity = output_path_identity(source, canonical)
    let plans : Array[@ar.ThinArchive] = []
    if original_thin is Some(archive) &&
      !same_path_identity(source_identity, destination_identity) &&
      manage_written(archive.edit(drop_symbol_indexes=true))
      .members()
      .any(e => e.archive_member_offset is Some(_)) {
      plans.push(archive)
    }
    if is_thin &&
      thin_plan.members().any(e => e.archive_member_offset is Some(_)) {
      plans.push(
        parse_managed_thin(
          manage_written(thin_plan.write(max_bytes=request.max_bytes)),
          request,
        ),
      )
    }
    for archive in plans {
      for
        path in manage_parsed(
          archive.member_sources(
            external_reader(source, options.allow_parent, read, validate_path),
            allow_parent_paths=options.allow_parent,
            nested_limits=nested_limits(request),
          ),
        ) {
        protected_members.push(protected_thin_path(source, path, canonical))
      }
    }
    if operation == "extract" &&
      same_path_identity(
        destination_identity,
        output_path_identity(source, canonical),
      ) {
      manage_fail("IO003", "extract output must differ from the archive path")
    }
    for member_path in protected_members {
      if same_path_identity(destination_identity, member_path) {
        manage_fail("IO003", "output would overwrite a thin archive member")
      }
    }
    let mut extracted : Bytes? = None
    if operation == "extract" {
      let index = limit_number(args[1]).unwrap()
      extracted = Some(
        if is_thin {
          guard thin_plan.members().get(index) is Some(entry) else {
            manage_fail("WR001", "member index is outside the archive")
          }
          load_reference(source, entry, options, request, read, validate_path).data
        } else {
          guard regular.members().get(index) is Some(entry) else {
            manage_fail("WR001", "member index is outside the archive")
          }
          entry.data
        },
      )
    }
    let metadata = if options.preserve {
      @ar.Preserve
    } else {
      @ar.Deterministic
    }
    let mut symbols : Array[@ar.WriteSymbol]? = None
    if extracted is None && is_thin {
      if options.format != @ar.Gnu &&
        options.format != @ar.Gnu64 &&
        operation != "convert" {
        manage_fail("WR005", "thin output requires gnu or gnu64")
      }
      if operation == "convert" || options.index_mode == "auto" {
        let archive = parse_managed_thin(
          manage_written(thin_plan.write(max_bytes=request.max_bytes)),
          request,
        )
        regular = manage_parsed(
          archive.materialize(
            external_reader(source, options.allow_parent, read, validate_path),
            drop_symbol_indexes=true,
            allow_parent_paths=options.allow_parent,
            max_bytes=request.max_bytes,
            nested_limits=nested_limits(request),
          ),
        )
      }
      if operation == "convert" {
        is_thin = false
      }
    }
    if extracted is None && options.index_mode == "auto" {
      symbols = Some(
        manage_written(
          regular.discover_symbols(
            max_symbols=request.max_symbols,
            max_symbol_name_bytes=request.max_symbol_name_bytes,
          ),
        ),
      )
    }
    if extracted is None &&
      is_thin &&
      clean_path(destination) != clean_path(source) {
      let rebased : Array[@ar.ThinWriteMember] = []
      for entry in thin_plan.members() {
        let target = joined_path(path_dir(source), path_text(entry.name))
        if clean_path(target) == clean_path(destination) {
          manage_fail("IO003", "thin output would overwrite one of its members")
        }
        rebased.push({
          ..entry,
          name: @utf8.encode(
            resolved_reference(path_dir(destination), target, canonical),
          ),
        })
      }
      thin_plan = manage_written(@ar.ThinArchiveBuilder::from_members(rebased))
    }
    let bytes = match extracted {
      Some(bytes) => bytes
      None =>
        if is_thin {
          manage_written(
            thin_plan.write(
              metadata~,
              symbols~,
              symbol_width=if options.format == @ar.Gnu64 { 64 } else { 32 },
              max_bytes=request.max_bytes,
              max_members=request.max_members,
              max_name_bytes=request.max_name_bytes,
              max_symbols=request.max_symbols,
              max_symbol_name_bytes=request.max_symbol_name_bytes,
            ),
          )
        } else {
          manage_written(
            regular.write(
              format=options.format,
              metadata~,
              symbols~,
              index_little_endian=options.little_endian,
              max_bytes=request.max_bytes,
              max_members=request.max_members,
              max_name_bytes=request.max_name_bytes,
              max_symbols=request.max_symbols,
              max_symbol_name_bytes=request.max_symbol_name_bytes,
            ),
          )
        }
    }
    let overwrite = options.force ||
      (
        operation != "create" &&
        operation != "extract" &&
        // Case-insensitive matches can refuse dangerous writes, but must not
        // grant replacement of a distinct file in a case-sensitive directory.
        destination_identity == output_path_identity(source, canonical)
      )
    match write(destination, bytes, overwrite) {
      Ok(_) => ()
      Err(error) => manage_fail("IO002", error)
    }
    {
      exit_code: 0,
      stdout: if request.json_output {
        Json::object({
          "schema_version": Json(1),
          "operation": Json(operation),
          "output": Json(destination),
          "byte_length": Json(bytes.length()),
        }).stringify() +
        "\n"
      } else {
        "Wrote \{bytes.length()} bytes to \{Json(destination).stringify()}.\n"
      },
      stderr: "",
    }
  } catch {
    ManageFailure(code, message) =>
      error_reply(code, message, request.json_output, 2)
  }
}
