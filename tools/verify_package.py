"""Build an independent four-backend consumer from the actual MoonAr package.

The consumer imports only public APIs. Its provider is extracted from the ZIP
produced by `moon package`, rather than the working checkout. A JSON report
records the tested archive and SHA-256 under _build/verification.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile


CONSUMER = r'''
///|
fn fixture() -> Bytes {
  __OBJECT__
}

///|
fn[T] write_ok(value : Result[T, @ar.WriteError]) -> T raise {
  match value {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
fn[T] parse_ok(value : Result[T, @ar.ParseError]) -> T raise {
  match value {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
test "public object discovery returns defined symbols and precise failures" {
  match @ar.symbols_from_object(fixture()) {
    Ok(names) => assert_eq(names, [b"entry"])
    Err(error) => fail(error.message)
  }
  assert_true(@ar.symbols_from_object(b"\x7fELF\x02") is Err({ code: "OB001", .. }))
  assert_true(
    @ar.symbols_from_object(fixture(), max_symbols=1)
    is Err({ code: "OB003", .. }),
  )
  assert_true(@ar.symbols_from_object(b"ordinary data") is Ok([]))
}

///|
test "public regular builder edits and every output format rebuild indexes" {
  let original = write_ok(@ar.ArchiveBuilder::from_members([
    @ar.WriteMember::new(b"old.o", fixture()),
  ]))
  let plan = write_ok(original.insert(0, @ar.WriteMember::new(b"data", b"12345678")))
  let plan = write_ok(plan.move_member(1, 0))
  let plan = write_ok(plan.replace(0, @ar.WriteMember::new(b"object.o", fixture())))
  let plan = write_ok(plan.append(@ar.WriteMember::new(b"remove", b"")))
  let plan = write_ok(plan.remove(2))
  assert_eq(original.member_count(), 1)
  assert_eq(original.members()[0].name, b"old.o")
  let symbols = write_ok(plan.discover_symbols())
  assert_eq(symbols, [{ name: b"entry", member_index: 0, }])
  for format in [@ar.Gnu, @ar.Gnu64, @ar.Bsd, @ar.Bsd64, @ar.Darwin, @ar.Darwin64] {
    let bytes = write_ok(plan.write(format~, symbols=Some(symbols)))
    let archive = parse_ok(@ar.parse(bytes))
    let index = archive.symbol_indexes()[0]
    assert_eq(index.symbols.length(), 1)
    assert_eq(index.symbols[0].name, b"entry")
    assert_eq(archive.member_bytes(index.symbols[0].member_index), Some(fixture()))
    let imported = write_ok(archive.edit(drop_symbol_indexes=true))
    assert_eq(imported.members(), plan.members())
  }
}

///|
test "public thin creation loading materialization and index reconstruction" {
  let plan = write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"objects/object.o", fixture().length()),
  ]))
  for width in [32, 64] {
    let bytes = write_ok(plan.write(
      symbol_width=width,
      symbols=Some([{ name: b"entry", member_index: 0, }]),
    ))
    let archive = parse_ok(@ar.parse_thin(bytes))
    assert_eq(archive.byte_length(), bytes.length())
    let target = archive.symbol_indexes()[0].symbols[0].member_index
    assert_eq(parse_ok(archive.member_path(target)), b"objects/object.o")
    assert_eq(archive.inline_bytes(target), None)
    let loader = fn(path, size) {
      if path == b"objects/object.o" && size == fixture().length() {
        Ok(fixture())
      } else {
        Err("unexpected member request")
      }
    }
    assert_eq(parse_ok(archive.load_member(target, loader)), fixture())
    assert_true(archive.materialize(loader) is Err({ code: "AR011", .. }))
    let regular = parse_ok(archive.materialize(loader, drop_symbol_indexes=true))
    let symbols = write_ok(regular.discover_symbols())
    let restored = parse_ok(@ar.parse(write_ok(regular.write(symbols=Some(symbols)))))
    assert_eq(restored.symbol_indexes()[0].symbols[0].name, b"entry")
    assert_eq(
      restored.member_bytes(restored.symbol_indexes()[0].symbols[0].member_index),
      Some(fixture()),
    )
    assert_eq(
      write_ok(archive.edit(drop_symbol_indexes=true)).members(),
      plan.members(),
    )
  }
}

///|
test "public thin editing preserves independent plans and size errors" {
  let original = @ar.ThinArchiveBuilder::new()
  let plan = write_ok(original.append(@ar.ThinWriteMember::new(b"a", 3)))
  let plan = write_ok(plan.insert(0, @ar.ThinWriteMember::new(b"b", 4)))
  let plan = write_ok(plan.move_member(1, 0))
  let plan = write_ok(plan.replace(1, @ar.ThinWriteMember::new(b"c", 2)))
  let plan = write_ok(plan.remove(1))
  assert_eq(original.member_count(), 0)
  assert_eq(plan.members(), [@ar.ThinWriteMember::new(b"a", 3)])
  let archive = parse_ok(@ar.parse_thin(write_ok(plan.write())))
  let target = archive.member_count() - 1
  assert_true(
    archive.load_member(target, (_, _) => Ok(b"wrong"))
    is Err({ code: "AR014", .. }),
  )
  assert_true(
    archive.materialize((_, _) => Ok(b"abc"), max_bytes=2)
    is Err({ code: "AR008", .. }),
  )
}

///|
test "public logical comparison and endian selection work across packages" {
  let plan = write_ok(@ar.ArchiveBuilder::from_members([
    @ar.WriteMember::new(b"object.o", fixture()),
  ]))
  let symbols = write_ok(plan.discover_symbols())
  let gnu = parse_ok(@ar.parse(write_ok(plan.write(symbols=Some(symbols)))))
  let bsd = parse_ok(@ar.parse(write_ok(plan.write(
    format=@ar.Bsd64, symbols=Some(symbols), index_little_endian=false,
  ))))
  assert_eq(bsd.symbol_indexes()[0].format, "bsd64-be")
  let difference = @ar.compare_logical(gnu, bsd)
  assert_true(difference.content_equal && difference.symbols_equal)
  assert_true(!difference.bytes_equal && difference.changes.is_empty())
  let exposed = bsd.symbol_indexes()
  exposed[0].symbols.clear()
  assert_eq(bsd.symbol_indexes()[0].symbols.length(), 1)
}
///|
test "public immutable snapshots validate thin contents and preserve source identity" {
  let plan = write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"data", 3),
  ]))
  let thin = parse_ok(@ar.parse_thin(write_ok(plan.write())))
  assert_eq(parse_ok(thin.validate_members((_, _) => Ok(b"abc"))), 3)
  let before = parse_ok(thin.snapshot((_, _) => Ok(b"abc")))
  let after = parse_ok(thin.snapshot((_, _) => Ok(b"xyz")))
  let result = before.compare_logical(after)
  assert_true(result.bytes_equal && !result.content_equal)
  assert_eq(result.changes[0].before_index, Some(1))
  let ordinary = parse_ok(@ar.parse(write_ok(write_ok(@ar.ArchiveBuilder::from_members([
    @ar.WriteMember::new(b"data", b"abc"),
  ])).write())))
  let mixed = before.compare_logical(ordinary.snapshot())
  assert_true(mixed.content_equal && mixed.symbols_equal)
  assert_true(thin.validate_members((_, _) => Ok(b"x")) is Err({ code: "AR014", .. }))
}

'''


def elf_fixture():
    # A relocatable ELF64 with an absolute global "entry" symbol. Its section
    # and symbol tables are explicit wire-format data, independent of MoonAr.
    ident = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    header = ident + struct.pack("<HHIQQQIHHHHHH", 1, 62, 1, 0, 0, 64, 0, 64, 0, 0, 64, 3, 0)
    names = b"\0entry\0"
    strings = struct.pack("<IIQQQQIIQQ", 0, 3, 0, 0, 256, len(names), 0, 0, 1, 0)
    symbols = struct.pack("<IIQQQQIIQQ", 0, 2, 0, 0, 256 + len(names), 48, 1, 1, 8, 24)
    symbol = struct.pack("<IBBHQQ", 1, 0x10, 0, 0xFFF1, 42, 0)
    data = header + b"\0" * 64 + strings + symbols + names + b"\0" * 24 + symbol
    return data + b"\0" * (-len(data) % 8)


def run(args, cwd):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, capture_output=True,
        check=False, timeout=180,
    )
    if result.returncode:
        raise AssertionError(
            f"{args!r}: exit {result.returncode}\n"
            + result.stdout.decode("utf-8", errors="replace")
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout.decode("utf-8", errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", default=shutil.which("moon"))
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--report", type=Path, default=Path("_build/verification/package-consumer.json"))
    args = parser.parse_args()
    if not args.moon:
        parser.error("MoonBit's moon executable is required")
    root = Path(__file__).resolve().parent.parent
    metadata = (root / "moon.mod").read_text(encoding="utf-8")
    module = re.search(r'^name\s*=\s*"([^"]+)"', metadata, re.M).group(1)
    version = re.search(r'^version\s*=\s*"([^"]+)"', metadata, re.M).group(1)
    archive = args.archive
    if archive is None:
        run([args.moon, "package"], root)
        archive = root / "_build/publish" / (module.replace("/", "-") + "-" + version + ".zip")
    archive = archive.resolve()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    build_root = root / "_build"
    build_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="package-consumer-", dir=build_root) as temporary:
        consumer = Path(temporary).resolve()
        assert consumer.parent == build_root.resolve()
        provider = consumer / "provider"
        provider.mkdir()
        with zipfile.ZipFile(archive) as package:
            files = [entry for entry in package.infolist() if not entry.is_dir()]
            for entry in files:
                name = PurePosixPath(entry.filename.replace("\\", "/"))
                assert not name.is_absolute() and ".." not in name.parts, entry.filename
                target = provider.joinpath(*name.parts)
                assert target.resolve().is_relative_to(provider.resolve()), entry.filename
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.read(entry))
        provider_metadata = (provider / "moon.mod").read_text(encoding="utf-8")
        assert f'version = "{version}"' in provider_metadata
        (consumer / "moon.mod").write_text(
            f'name = "verification/moonar-consumer"\nversion = "0.1.0"\n'
            f'import {{ "{module}@{version}", }}\n', encoding="utf-8",
        )
        (consumer / "moon.work").write_text('members = [ ".", "./provider" ]\n', encoding="utf-8")
        (consumer / "moon.pkg").write_text(
            f'import {{ "{module}" @ar, }} for "test"\n', encoding="utf-8",
        )
        fixture = 'b"' + "".join(f"\\x{byte:02x}" for byte in elf_fixture()) + '"'
        (consumer / "consumer_test.mbt").write_text(
            CONSUMER.replace("__OBJECT__", fixture).lstrip(), encoding="utf-8",
        )
        output = run([
            args.moon, "test", "--target", "all", "--deny-warn",
            "--package", "verification/moonar-consumer",
        ], consumer)
        print(output.strip())
    record = {
        "version": version, "archive": str(archive), "archive_sha256": digest,
        "packaged_files": len(files), "consumer_tests_per_target": 6,
        "targets": ["wasm", "wasm-gc", "js", "native"], "passed": True,
        "interfaces": [
            "symbols_from_object", "ArchiveBuilder.discover_symbols",
            "ArchiveBuilder.insert", "WriteFormat six layouts",
            "ThinArchiveBuilder", "ThinArchive.materialize", "compare_logical",
            "ThinArchive.validate_members", "ArchiveSnapshot.compare_logical",
        ],
    }
    report = args.report if args.report.is_absolute() else root / args.report
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"PASS packaged public API consumer: {version}, {len(files)} files, SHA-256 {digest}")


if __name__ == "__main__":
    main()
