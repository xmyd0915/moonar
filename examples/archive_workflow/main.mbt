///|
fn[T] written(result : Result[T, @ar.WriteError]) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
fn[T] parsed(result : Result[T, @ar.ParseError]) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail("\{error.code} at \{error.offset}: \{error.message}")
  }
}

///|
// The explicit allowlist supplies bytes; archive paths never open files here.
fn resolve_thin(args : Array[String], start : Int) -> @ar.ThinArchive raise {
  let archive = parsed(@ar.parse_thin(@fs.read_file_to_bytes(args[2])))
  let files : Map[Bytes, Bytes] = Map([])
  let mut i = start
  while i < args.length() {
    files[@utf8.encode(args[i])] = @fs.read_file_to_bytes(args[i + 1])
    i += 2
  }
  let entries : Array[Json] = []
  let mut builder = @ar.ArchiveBuilder::new()
  for i = 0; i < archive.member_count(); i = i + 1 {
    let entry = archive.get_member(i).unwrap()
    if entry.kind != @ar.Regular {
      continue
    }
    let payload = parsed(
      archive.load_member(i, fn(path, _limit) {
        match files.get(path) {
          Some(bytes) => Ok(bytes)
          None => Err("member is absent from the supplied file map")
        }
      }),
    )
    entries.push(
      Json::object({
        "name_hex": Json(entry.name_hex()),
        "size": Json(payload.length()),
      }),
    )
    builder = written(
      builder.append(
        @ar.WriteMember::new(entry.name, payload, metadata=entry.metadata),
      ),
    )
  }
  if args[1] == "materialize" {
    // This data-container example deliberately writes without a symbol index.
    // Static libraries can pass a fresh WriteSymbol mapping to write().
    @fs.write_bytes_to_file(args[3], written(builder.write()))
  }
  println(
    Json::object({
      "members": Json::array(entries),
      "symbol_count": Json(
        archive
        .symbol_indexes()
        .fold(init=0, fn(total, index) { total + index.symbols.length() }),
      ),
    }).stringify(),
  )
  archive
}

///|
fn workflow(args : Array[String]) -> Unit raise {
  if args.length() == 4 && args[1] == "create" {
    let format = match args[3] {
      "gnu" => @ar.Gnu
      "bsd" => @ar.Bsd
      _ => fail("expected gnu or bsd")
    }
    let mut builder = @ar.ArchiveBuilder::new()
    for
      (name, data) in [
        (b"short.txt", b"hello\n"),
        (b"a_long_member_name_for_testing.bin", b"\x00\xff\x0a"),
        (b"same.txt", b"first"),
        (b"same.txt", b"second"),
        (b"empty", b""),
      ] {
      builder = written(builder.append(@ar.WriteMember::new(name, data)))
    }
    @fs.write_bytes_to_file(args[2], written(builder.write(format~)))
  } else if args.length() == 4 && args[1] == "edit" {
    let archive = parsed(@ar.parse(@fs.read_file_to_bytes(args[2])))
    let mut builder = written(archive.edit())
    builder = written(
      builder.append(@ar.WriteMember::new(b"added.txt", b"appended")),
    )
    builder = written(
      builder.replace(0, @ar.WriteMember::new(b"short.txt", b"updated")),
    )
    builder = written(builder.remove(1))
    builder = written(builder.move_member(2, 0))
    @fs.write_bytes_to_file(args[3], written(builder.write()))
  } else if args.length() == 5 && args[1] == "indexed" {
    let mut builder = @ar.ArchiveBuilder::new()
    builder = written(
      builder.append(
        @ar.WriteMember::new(
          b"a_long_alpha_object_name.o",
          @fs.read_file_to_bytes(args[3]),
        ),
      ),
    )
    builder = written(
      builder.append(
        @ar.WriteMember::new(b"beta.o", @fs.read_file_to_bytes(args[4])),
      ),
    )
    @fs.write_bytes_to_file(
      args[2],
      written(
        builder.write(
          symbols=Some([
            { name: b"moon_alpha", member_index: 0, },
            { name: b"moon_beta", member_index: 1, },
          ]),
        ),
      ),
    )
  } else if args.length() == 5 && args[1] == "reindex" {
    let archive = parsed(@ar.parse(@fs.read_file_to_bytes(args[2])))
    let mut builder = written(archive.edit(drop_symbol_indexes=true))
    builder = written(
      builder.replace(
        0,
        @ar.WriteMember::new(
          b"replacement_alpha.o",
          @fs.read_file_to_bytes(args[4]),
        ),
      ),
    )
    builder = written(builder.move_member(0, 1))
    @fs.write_bytes_to_file(
      args[3],
      written(
        builder.write(
          symbols=Some([
            { name: b"moon_alpha", member_index: 1, },
            { name: b"moon_beta", member_index: 0, },
          ]),
        ),
      ),
    )
  } else if args.length() >= 3 &&
    args[1] == "thin" &&
    (args.length() - 3) % 2 == 0 {
    ignore(resolve_thin(args, 3))
  } else if args.length() >= 4 &&
    args[1] == "materialize" &&
    (args.length() - 4) % 2 == 0 {
    ignore(resolve_thin(args, 4))
  } else {
    fail(
      "Usage: archive_workflow create OUT gnu|bsd; edit IN OUT; indexed OUT ALPHA_OBJECT BETA_OBJECT; reindex IN OUT REPLACEMENT_ALPHA; thin IN [MEMBER FILE]...; materialize IN OUT [MEMBER FILE]...",
    )
  }
}

///|
fn main {
  workflow(@env.args()) catch {
    error => {
      eprintln(error)
      @sys.exit(1)
    }
  }
}
