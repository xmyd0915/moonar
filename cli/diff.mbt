///|
fn load_diff_input(
  request : Request,
  path : String,
  read : (String) -> Result[Bytes, String],
  validate_path : (String, String) -> Result[Unit, String],
) -> Result[(@ar.ArchiveSnapshot, @ar.Archive?), Reply] {
  let bytes = match read(path) {
    Ok(bytes) => bytes
    Err(message) =>
      return Err(
        error_reply("IO001", "\{path}: \{message}", request.json_output, 2),
      )
  }
  if bytes.has_prefix(b"!<thin>\n"[:]) && request.logical {
    let archive = match
      @ar.parse_thin(
        bytes,
        max_bytes=request.max_bytes,
        max_members=request.max_members,
        max_name_bytes=request.max_name_bytes,
        max_symbols=request.max_symbols,
        max_symbol_name_bytes=request.max_symbol_name_bytes,
      ) {
      Ok(archive) => archive
      Err(error) => return Err(archive_input_error(request, path, error, 2))
    }
    return match
      archive.snapshot(
        external_reader(path, request.allow_parent_paths, read, validate_path),
        max_bytes=request.max_bytes,
        allow_parent_paths=request.allow_parent_paths,
        nested_limits=nested_limits(request),
      ) {
      Ok(snapshot) => Ok((snapshot, None))
      Err(error) => Err(archive_input_error(request, path, error, 2))
    }
  }
  match
    @ar.parse(
      bytes,
      max_bytes=request.max_bytes,
      max_members=request.max_members,
      max_name_bytes=request.max_name_bytes,
      max_symbols=request.max_symbols,
      max_symbol_name_bytes=request.max_symbol_name_bytes,
    ) {
    Ok(archive) => Ok((archive.snapshot(), Some(archive)))
    Err(error) =>
      Err(
        archive_input_error(
          request,
          path,
          if error.code == "AR007" {
            {
              ..error,
              message: "use diff --logical to compare thin archive contents",
            }
          } else {
            error
          },
          2,
        ),
      )
  }
}

///|
fn diff_text(result : @ar.Comparison) -> String {
  if result.bytes_equal &&
    result.changes.is_empty() &&
    !result.order_changed &&
    result.ambiguities.is_empty() {
    return "Archives are byte-for-byte identical.\n"
  }
  let out = StringBuilder()
  out.write_string(
    if result.bytes_equal {
      "Archive container bytes are identical.\n"
    } else {
      "Archive bytes differ.\n"
    },
  )
  if result.order_changed {
    out.write_string("Relative record order changed.\n")
  }
  for change in result.changes {
    let name = Json(@utf8.decode_lossy(change.name[:], ignore_bom=false)).stringify()
    out.write_string(
      "\{change.change.label()} \{name} (\{change.member_kind.label()}, occurrence \{change.occurrence})",
    )
    if change.change == @ar.Modified {
      out.write_string(
        ": payload=\{change.payload_changed}, metadata=\{change.metadata_changed}",
      )
    }
    out.write_string("\n")
  }
  if result.changes.is_empty() && !result.order_changed {
    out.write_string(
      "Record values match; container layout or header spelling differs.\n",
    )
  }
  if !result.ambiguities.is_empty() {
    out.write_string(
      "Duplicate member identity is ambiguous; pairing uses content then occurrence order.\n",
    )
  }
  out.to_string()
}

///|
fn run_diff(
  request : Request,
  before_path : String,
  after_path : String,
  read : (String) -> Result[Bytes, String],
  validate_path : (String, String) -> Result[Unit, String],
) -> Reply {
  let before = match
    load_diff_input(request, before_path, read, validate_path) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  let after = match load_diff_input(request, after_path, read, validate_path) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  if request.logical {
    let result = before.0.compare_logical(after.0)
    let equal = result.content_equal &&
      !result.metadata_changed &&
      !result.order_changed &&
      result.symbols_equal &&
      !result.symbol_index_presence_changed &&
      result.ambiguities.is_empty()
    let stdout = if request.json_output {
      result.to_json().stringify() + "\n"
    } else {
      let text = diff_text({
        bytes_equal: result.bytes_equal,
        order_changed: result.order_changed,
        changes: result.changes,
        ambiguities: result.ambiguities,
      })
      (if equal {
        "Logical archives match.\n"
      } else {
        "Logical archives differ or member matching is ambiguous.\n"
      }) +
      text +
      "Logical content equal: \{result.content_equal}; metadata changed: \{result.metadata_changed}; symbol mappings equal: \{result.symbols_equal}; index presence changed: \{result.symbol_index_presence_changed}.\n"
    }
    return { exit_code: if equal { 0 } else { 1 }, stdout, stderr: "", }
  }
  let result = @ar.compare(before.1.unwrap(), after.1.unwrap())
  {
    exit_code: if result.bytes_equal {
      0
    } else {
      1
    },
    stdout: if request.json_output {
      result.to_json().stringify() + "\n"
    } else {
      diff_text(result)
    },
    stderr: "",
  }
}
