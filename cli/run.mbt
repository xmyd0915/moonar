///|
pub fn help() -> String {
  "MoonAr 0.1.0\nUsage: moonar inspect FILE [--json]\n       moonar check FILE [--json]\n       moonar --help | --version\nOptions: --max-bytes N (default 67108864), --max-members N (default 100000)\nUse -- before filenames beginning with '-'.\nThe CLI loads the file into memory before applying parser limits.\n"
}

///|
fn error_reply(
  code : String,
  message : String,
  json_output : Bool,
  exit_code : Int,
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
/// The injected reader keeps CLI behavior testable without a filesystem.
pub fn run(
  request : Request,
  read : (String) -> Result[Bytes, String],
) -> Reply {
  let path = match request.command {
    Help => return { exit_code: 0, stdout: help(), stderr: "", }
    Version => return { exit_code: 0, stdout: "moonar 0.1.0\n", stderr: "", }
    Inspect(path) | Check(path) => path
  }
  let bytes = match read(path) {
    Ok(bytes) => bytes
    Err(message) => return error_reply("IO001", message, request.json_output, 2)
  }
  let archive = match parse_input(request, bytes) {
    Ok(archive) => archive
    Err(reply) => return reply
  }
  let stdout = if request.json_output {
    archive.to_json().stringify() + "\n"
  } else {
    match request.command {
      Inspect(_) => inspect_text(archive)
      _ =>
        "OK: \{archive.member_count()} records, \{archive.byte_length()} bytes\n"
    }
  }
  { exit_code: 0, stdout, stderr: "", }
}
