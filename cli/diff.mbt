///|
fn load_diff_input(
  request : Request,
  path : String,
  read : (String) -> Result[Bytes, String],
) -> Result[@ar.Archive, Reply] {
  let bytes = match read(path) {
    Ok(bytes) => bytes
    Err(message) =>
      return Err(
        error_reply("IO001", "\{path}: \{message}", request.json_output, 2),
      )
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
    Ok(archive) => Ok(archive)
    Err(error) =>
      Err(
        if request.json_output {
          {
            exit_code: 2,
            stdout: Json::object({
              "schema_version": Json(1),
              "input": Json(path),
              "error": Json::object({
                "code": Json(error.code),
                "offset": Json(error.offset),
                "message": Json(error.message),
              }),
            }).stringify() +
            "\n",
            stderr: "",
          }
        } else {
          {
            exit_code: 2,
            stdout: "",
            stderr: "\{Json(path).stringify()}: \{error.code} at byte \{error.offset}: \{error.message}\n",
          }
        },
      )
  }
}

///|
fn diff_text(result : @ar.Comparison) -> String {
  if result.bytes_equal {
    return "Archives are byte-for-byte identical.\n"
  }
  let out = StringBuilder()
  out.write_string("Archive bytes differ.\n")
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
) -> Reply {
  let before = match load_diff_input(request, before_path, read) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  let after = match load_diff_input(request, after_path, read) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  if request.logical {
    let result = @ar.compare_logical(before, after)
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
  let result = @ar.compare(before, after)
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
