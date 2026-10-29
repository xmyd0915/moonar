///|
pub fn help() -> String {
  "MoonAr 0.7.2\nUsage: moonar list|inspect|check FILE [--json]\n       moonar check FILE --external [--allow-parent-paths] [--json]\n       moonar diff BEFORE AFTER [--logical] [--json]\n       moonar create OUT [FILES...] [--thin]\n       moonar add ARCHIVE FILES... [--at N]\n       moonar replace ARCHIVE INDEX FILE\n       moonar delete ARCHIVE INDEX...\n       moonar move ARCHIVE FROM TO\n       moonar rename ARCHIVE INDEX NAME\n       moonar extract ARCHIVE INDEX OUT\n       moonar convert ARCHIVE OUT\n       moonar index ARCHIVE\n       moonar --help | --version\nWrite options: --format gnu|gnu64|bsd|bsd64|darwin|darwin64|coff (gnu),\n               --index auto|none (auto), --output FILE, --force,\n               --preserve-metadata, --big-endian-index, --json.\nThin access: --allow-parent-paths permits external references outside the archive directory.\nMember positions are zero-based ordinary-member positions shown by list.\ninspect shows physical records; check validates metadata; --external also validates thin members.\ndiff --logical accepts regular and thin inputs and loads external contents.\nEdits retain thin storage; convert materializes thin inputs into regular archives.\nNew outputs require --force to replace an existing file; in-place edits replace atomically.\nLimits: --max-bytes N (67108864), --max-members N (100000),\n        --max-name-bytes N (67108864), --max-symbols N (1000000),\n        --max-symbol-name-bytes N (67108864),\n        --max-archive-bytes N (67108864), --max-depth N (16; maximum 64).\nUse -- before filenames beginning with '-'.\nDiff exits: 0 equal, 1 different or ambiguous, 2 invalid input or I/O error.\nMutation exits: 0 success, 2 invalid input or I/O error.\nThe CLI loads files into memory before applying parser limits.\n"
}

///|
fn error_reply(
  code : String,
  message : String,
  json_output : Bool,
  exit_code : Int32,
) -> Reply {
  if json_output {
    {
      exit_code,
      stdout: Json::object({
        "schema_version": Json(1),
        "error": Json::object({ "code": Json(code), "message": Json(message) }),
      }).stringify() +
      "\n",
      stderr: "",
    }
  } else {
    {
      exit_code,
      stdout: "",
      stderr: code + ": " + Json(message).stringify() + "\n",
    }
  }
}

///|
fn parse_input(request : Request, bytes : Bytes) -> Result[@ar.Archive, Reply] {
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
            exit_code: 1,
            stdout: error.to_json().stringify() + "\n",
            stderr: "",
          }
        } else {
          {
            exit_code: 1,
            stdout: "",
            stderr: "\{error.code} at byte \{error.offset}: \{error.message}\n",
          }
        },
      )
  }
}

///|
fn inspect_text(archive : @ar.Archive) -> String {
  let out = StringBuilder()
  for i = 0; i < archive.member_count(); i = i + 1 {
    let entry = archive.get_member(i).unwrap()
    out.write_string(
      "\{i}\t\{entry.kind.label()}\t\{entry.size}\t\{Json(entry.name_text()).stringify()}\n",
    )
  }
  out.to_string()
}

///|
// List selectors are ordinary positions; retain the original physical position
// separately so a JSON selector can be passed directly to an edit command.
fn list_json(physical : Json) -> Json {
  let fields = match physical {
    Object(fields) => fields
    _ => abort("archive JSON")
  }
  let records = match fields["members"] {
    Array(records) => records
    _ => abort("members JSON")
  }
  let members : Array[Json] = []
  for record in records {
    if record is Object(entry) && entry.get("kind") == Some(Json("regular")) {
      entry["record_index"] = entry["index"]
      entry["index"] = Json(members.length())
      members.push(Json::object(entry))
    }
  }
  Json::object({
    "schema_version": Json(1),
    "format": fields["format"],
    "byte_length": fields["byte_length"],
    "index_kind": Json("ordinary_member"),
    "members": Json::array(members),
  })
}

///|
/// The injected reader keeps CLI behavior testable without a filesystem.
pub fn run(
  request : Request,
  read : (String) -> Result[Bytes, String],
  write~ : (String, Bytes, Bool) -> Result[Unit, String] = fn(_, _, _) {
    Err("no output writer was supplied")
  },
  validate_path~ : (String, String) -> Result[Unit, String] = fn(_, _) {
    Ok(())
  },
  canonical~ : (String) -> Result[String, String] = fn(path) { Ok(path) },
) -> Reply {
  match checked_request(request) {
    Ok(_) => ()
    Err(message) =>
      return error_reply("CLI001", message, request.json_output, 2)
  }
  let windows = if request.command is (Help | Version) {
    false
  } else {
    match canonical(".") {
      Ok(path) => windows_identity(path)
      Err(_) => false
    }
  }
  let canonical = if windows {
    fn(path) { canonical(path).map(slash_path) }
  } else {
    canonical
  }
  let path = match request.command {
    Help => return { exit_code: 0, stdout: help(), stderr: "", }
    Version => return { exit_code: 0, stdout: "moonar 0.7.2\n", stderr: "", }
    Diff(before, after) =>
      return run_diff(request, before, after, read, validate_path, windows)
    Manage(options) =>
      return run_manage(
        request, options, read, write, validate_path, canonical, windows,
      )
    Inspect(path) | List(path) | Check(path) => path
  }
  let bytes = match read(path) {
    Ok(bytes) => bytes
    Err(message) => return error_reply("IO001", message, request.json_output, 2)
  }
  if bytes.has_prefix(b"!<thin>\n"[:]) {
    return inspect_thin(request, path, bytes, read, validate_path, windows)
  }
  let archive = match parse_input(request, bytes) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  let stdout = if request.json_output {
    (if request.command is List(_) {
      list_json(archive.to_json())
    } else {
      archive.to_json()
    }).stringify() +
    "\n"
  } else {
    match request.command {
      Inspect(_) => inspect_text(archive)
      List(_) => {
        let out = StringBuilder()
        let mut position = 0
        for i = 0; i < archive.member_count(); i = i + 1 {
          let entry = archive.get_member(i).unwrap()
          if entry.kind == @ar.Regular {
            out.write_string(
              "\{position}\t\{entry.size}\t\{Json(entry.name_text()).stringify()}\n",
            )
            position += 1
          }
        }
        out.to_string()
      }
      _ =>
        "OK: \{archive.member_count()} records, \{archive.byte_length()} bytes\n"
    }
  }
  { exit_code: 0, stdout, stderr: "", }
}

///|
fn inspect_thin(
  request : Request,
  path : String,
  bytes : Bytes,
  read : (String) -> Result[Bytes, String],
  validate_path : (String, String) -> Result[Unit, String],
  windows : Bool,
) -> Reply {
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
    Err(error) =>
      return if request.json_output {
        {
          exit_code: 1,
          stdout: error.to_json().stringify() + "\n",
          stderr: "",
        }
      } else {
        {
          exit_code: 1,
          stdout: "",
          stderr: "\{error.code} at byte \{error.offset}: \{error.message}\n",
        }
      }
  }
  let external_bytes = if request.external {
    match
      archive.validate_members(
        external_reader(
          path,
          request.allow_parent_paths,
          read,
          validate_path,
          windows~,
        ),
        max_bytes=request.max_bytes,
        allow_parent_paths=request.allow_parent_paths,
        nested_limits=nested_limits(request),
      ) {
      Ok(total) => Some(total)
      Err(error) => return archive_input_error(request, path, error, 1)
    }
  } else {
    None
  }
  let text = StringBuilder()
  let mut position = 0
  for i = 0; i < archive.member_count(); i = i + 1 {
    let entry = archive.get_member(i).unwrap()
    let reference = match entry.archive_member_offset {
      Some(offset) => "\tarchive-offset=\{offset}"
      None => ""
    }
    if request.command is List(_) {
      if entry.kind == @ar.Regular {
        text.write_string(
          "\{position}\t\{entry.size}\t\{Json(entry.name_text()).stringify()}\{reference}\n",
        )
        position += 1
      }
    } else {
      text.write_string(
        "\{i}\t\{entry.kind.label()}\t\{entry.size}\t\{Json(entry.name_text()).stringify()}\{reference}\n",
      )
    }
  }
  {
    exit_code: 0,
    stdout: if request.json_output {
      (if external_bytes is Some(total) {
        let value = archive.to_json()
        if value is Object(fields) {
          fields["external_checked"] = Json(true)
          fields["external_byte_length"] = Json(total)
        }
        value
      } else if request.command is List(_) {
        list_json(archive.to_json())
      } else {
        archive.to_json()
      }).stringify() +
      "\n"
    } else if request.command is (Inspect(_) | List(_)) {
      text.to_string()
    } else if external_bytes is Some(total) {
      "OK: \{archive.member_count()} thin records; external members checked, \{total} bytes.\n"
    } else {
      "OK: \{archive.member_count()} thin records, \{archive.byte_length()} container bytes\n"
    },
    stderr: "",
  }
}
