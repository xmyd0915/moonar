///|
fn slash_path(path : String) -> String {
  path.replace_all(old="\\", new="/")
}

///|
fn windows_path(path : String) -> String {
  // Keep C:foo relative to that drive's current directory; it is not C:/foo.
  let path = slash_path(path)
  if path.length() >= 2 &&
    path[1] == ':' &&
    (path.length() == 2 || path[2] != '/') {
    path[:2].to_owned() + "./" + path[2:].to_owned()
  } else {
    path
  }
}

///|
fn windows_identity(path : String) -> Bool {
  (
    path.length() >= 3 &&
    path[1] == ':' &&
    ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) &&
    (path[2] == '/' || path[2] == '\\')
  ) ||
  path.has_prefix("\\\\") ||
  path.has_prefix("//")
}

///|
fn manage_destination(options : ManageOptions) -> String {
  match options.operation {
    "extract" => options.arguments[2]
    "convert" => options.arguments[1]
    _ => options.output.unwrap_or(options.arguments[0])
  }
}

///|
fn windows_manage_options(options : ManageOptions) -> ManageOptions {
  let arguments = Array::makei(options.arguments.length(), fn(index) {
    let value = options.arguments[index]
    let filesystem = index == 0 ||
      options.operation == "create" ||
      options.operation == "add" ||
      options.operation == "convert" ||
      (
        (options.operation == "replace" || options.operation == "extract") &&
        index == 2
      )
    if filesystem {
      windows_path(value)
    } else {
      value
    }
  })
  { ..options, arguments, output: options.output.map(windows_path), }
}

///|
fn path_dir(path : String) -> String {
  // Windows filesystem inputs have already been normalized. A POSIX backslash
  // remains part of a filename and must never become a separator here.
  let parts = path.split("/").map(p => p.to_owned()).to_array()
  ignore(parts.pop())
  let result = parts.join("/")
  if result.is_empty() {
    if path.has_prefix("/") {
      "/"
    } else {
      "."
    }
  } else if result.length() == 2 && result[1] == ':' {
    result + "/"
  } else {
    result
  }
}

///|
fn path_name(path : String) -> String {
  path.split("/").last().unwrap_or("").to_owned()
}

///|
fn clean_path(path : String) -> String {
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
  let result = if parts.length() == 1 &&
    result.has_suffix(":") &&
    path.length() >= 3 &&
    path[2] == '/' {
    result + "/"
  } else {
    result
  }
  if result.is_empty() {
    "."
  } else {
    result
  }
}

///|
fn joined_path(base : String, relative : String) -> String {
  if base.has_suffix("/") {
    base + relative
  } else {
    base + "/" + relative
  }
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
    .filter(p => p != "." && p != "")
    .map(p => p.to_owned())
    .to_array()
  let b = target
    .split("/")
    .filter(p => p != "." && p != "")
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
        (if (drive_path && common == 0) || (unc_base && common < 2) {
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
