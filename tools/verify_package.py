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
  for format in [@ar.Gnu, @ar.Gnu64, @ar.Bsd, @ar.Bsd64, @ar.Darwin, @ar.Darwin64, @ar.Coff] {
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

///|
test "public nested references preserve offsets and resolve through bounded shared loaders" {
  let data = write_ok(write_ok(@ar.ArchiveBuilder::from_members([
    @ar.WriteMember::new(b"actual.o", fixture()),
  ])).write())
  let plan = write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"base.a", fixture().length(), archive_member_offset=Some(8)),
  ]))
  let thin = parse_ok(@ar.parse_thin(write_ok(plan.write())))
  assert_eq(thin.get_member(1).unwrap().archive_member_offset, Some(8))
  let loader = (_, _) => Ok(data)
  let actual = parse_ok(thin.resolve_member(1, loader))
  assert_eq((actual.name, actual.data), (b"actual.o", fixture()))
  assert_eq(parse_ok(thin.member_sources(loader)), [b"base.a"])
  let regular = parse_ok(thin.materialize(loader))
  let snapshot = parse_ok(thin.snapshot(loader))
  let ordinary = parse_ok(@ar.parse(write_ok(regular.write())))
  assert_true(snapshot.compare_logical(ordinary.snapshot()).content_equal)
  assert_true(thin.materialize(loader, nested_limits=@ar.NestedLimits::new(max_depth=0)) is Err({ code: "AR008", .. }))
}

///|
test "public nested batch operations reuse an exactly budgeted dependency path" {
  let child = write_ok(write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"leaf.o", 3),
  ])).write())
  let parsed_child = parse_ok(@ar.parse_thin(child))
  let target = parsed_child.get_member(parsed_child.member_count() - 1).unwrap()
  let outer = parse_ok(@ar.parse_thin(write_ok(write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"dir/inner.a", 3, archive_member_offset=Some(target.header_offset)),
    @ar.ThinWriteMember::new(b"dir/inner.a", 3, archive_member_offset=Some(target.header_offset)),
  ])).write())))
  let mut parsed_name_bytes = 0
  for i in 0..<parsed_child.member_count() {
    parsed_name_bytes += parsed_child.get_member(i).unwrap().name.length()
  }
  let exact = 11 + 10 + parsed_name_bytes
  let limits = @ar.NestedLimits::new(max_name_bytes=exact)
  let loader = fn(path, _) {
    if path == b"dir/inner.a" { Ok(child) }
    else if path == b"dir/leaf.o" { Ok(b"abc") }
    else { Err("unexpected dependency") }
  }
  assert_eq(parse_ok(outer.validate_members(loader, nested_limits=limits)), 6)
  assert_eq(parse_ok(outer.member_sources(loader, nested_limits=limits)), [b"dir/inner.a", b"dir/leaf.o"])
  let packed = parse_ok(outer.materialize(loader, nested_limits=limits))
  let ordinary = parse_ok(@ar.parse(write_ok(packed.write())))
  assert_true(parse_ok(outer.snapshot(loader, nested_limits=limits)).compare_logical(ordinary.snapshot()).content_equal)
  assert_true(outer.validate_members(loader, nested_limits=@ar.NestedLimits::new(max_name_bytes=exact - 1)) is Err({ code: "AR008", .. }))
}

///|
test "public short import discovery and COFF dual indexes round trip" {
  let object = b"\x00\x00\xff\xff\x00\x00\x64\x86\x00\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x04\x00entry\x00x.dll\x00"
  match @ar.symbols_from_object(object) {
    Ok(names) => assert_eq(names, [b"__imp_entry", b"entry"])
    Err(error) => fail(error.message)
  }
  let plan = write_ok(@ar.ArchiveBuilder::from_members([@ar.WriteMember::new(b"long import member.obj", object)]))
  let symbols = write_ok(plan.discover_symbols())
  let archive = parse_ok(@ar.parse(write_ok(plan.write(format=@ar.Coff, symbols=Some(symbols)))))
  assert_eq(archive.symbol_indexes()[0].format, "coff")
  assert_eq(archive.symbol_indexes()[0].symbols.length(), 2)
  assert_eq(archive.get_member(0).unwrap().kind, @ar.SymbolTable)
  assert_eq(archive.get_member(1).unwrap().kind, @ar.SymbolTable)
}

///|
test "public LLVM bitcode discovery builds ordinary and thin archive indexes" {
  let object = __BITCODE__
  match @ar.symbols_from_object(object) {
    Ok(names) => assert_eq(names, [b"entry"])
    Err(error) => fail(error.message)
  }
  assert_true(@ar.symbols_from_object(object, max_symbols=0) is Err({ code: "OB003", .. }))
  let plan = write_ok(@ar.ArchiveBuilder::from_members([@ar.WriteMember::new(b"entry.bc", object)]))
  let symbols = write_ok(plan.discover_symbols())
  let archive = parse_ok(@ar.parse(write_ok(plan.write(symbols=Some(symbols)))))
  assert_eq(archive.symbol_indexes()[0].symbols[0].name, b"entry")
  let thin = parse_ok(@ar.parse_thin(write_ok(write_ok(@ar.ThinArchiveBuilder::from_members([
    @ar.ThinWriteMember::new(b"entry.bc", object.length()),
  ])).write(symbols=Some(symbols)))))
  let loaded = parse_ok(thin.materialize((_, _) => Ok(object), drop_symbol_indexes=true))
  assert_eq(write_ok(loaded.discover_symbols()), symbols)
}

///|
test "public CLI separates host path syntax from ordinary member names" {
  for windows in [false, true] {
    let inputs : Array[String] = []
    let outputs : Array[Bytes] = []
    let request = @cli.parse_args(["create", "result.a", "part\\name.bin"]).unwrap()
    let reply = @cli.run(request,
      fn(path) { inputs.push(path); Ok(b"payload") },
      write=fn(_, bytes, _) { outputs.push(bytes); Ok(()) },
      canonical=fn(path) { Ok(if path == "." { if windows { "C:\\work" } else { "/work" } } else { path }) })
    assert_eq(reply.exit_code, 0)
    assert_eq(inputs, [if windows { "part/name.bin" } else { "part\\name.bin" }])
    let plan = write_ok(parse_ok(@ar.parse(outputs[0])).edit(drop_symbol_indexes=true))
    assert_eq(plan.members()[0].name, if windows { b"name.bin" } else { b"part\\name.bin" })
  }
}

///|
test "public CLI rejects malformed direct requests before filesystem access" {
  let base = @cli.parse_args(["create", "out.a", "--json"]).unwrap()
  guard base.command is @cli.Manage(options) else { abort("create request") }
  for invalid in [
    { ..base, command: @cli.Manage({ ..options, arguments: [] }) },
    { ..base, command: @cli.Manage({ ..options, operation: "unknown" }) },
    { ..base, max_bytes: -1 },
    { ..base, command: @cli.Manage({ ..options, operation: "move", arguments: ["in.a", "0", "bad"] }) },
  ] {
    let callbacks : Array[String] = []
    let reply = @cli.run(invalid,
      fn(path) { callbacks.push("read:" + path); Ok(b"!<arch>\n") },
      write=fn(path, _, _) { callbacks.push("write:" + path); Ok(()) },
      canonical=fn(path) { callbacks.push("canonical:" + path); Ok(path) },
      validate_path=fn(_, path) { callbacks.push("validate:" + path); Ok(()) })
    assert_eq(reply.exit_code, 2)
    assert_eq(reply.stderr, "")
    assert_true(reply.stdout.contains("CLI001"))
    assert_true(callbacks.is_empty())
  }
}
'''


def bitcode_fixture():
    # Explicit version-3 summary wire data and a single module envelope. The
    # independent compiler/linker workflow is exercised by verify_lto.py.
    class Bits:
        def __init__(self):
            self.values = []
        def fixed(self, value, width):
            self.values.extend((value >> bit) & 1 for bit in range(width))
        def vbr(self, value, width):
            mask = (1 << (width - 1)) - 1
            while value > mask:
                self.fixed((value & mask) | (1 << (width - 1)), width)
                value >>= width - 1
            self.fixed(value, width)
        def align(self):
            self.values.extend([0] * (-len(self.values) % 32))
        def data(self):
            assert len(self.values) % 8 == 0
            return bytes(sum(self.values[start + bit] << bit for bit in range(8))
                         for start in range(0, len(self.values), 8))
    def block(identifier, body):
        bits = Bits()
        bits.fixed(1, 2)
        bits.vbr(identifier, 8)
        bits.vbr(3, 4)
        bits.align()
        bits.fixed(len(body) // 4, 32)
        return bits.data() + body
    def blob(data):
        bits = Bits()
        bits.fixed(2, 3)
        bits.vbr(2, 5)
        bits.fixed(1, 1)
        bits.vbr(1, 8)
        bits.fixed(0, 1)
        bits.fixed(5, 3)
        bits.fixed(4, 3)
        bits.vbr(len(data), 6)
        bits.align()
        before = bits.data() + data + b"\0" * (-len(data) % 4)
        return before + b"\0" * 4
    header = [0] * 19
    for index, value in {0: 3, 3: 76, 4: 1, 5: 88, 7: 88, 8: 1, 9: 112, 17: 112}.items():
        header[index] = value
    table = struct.pack("<19I", *header) + struct.pack("<3I", 0, 1, 0)
    table += struct.pack("<6I", 0, 5, 0, 5, 0xffffffff, 1024)
    return b"BC\xc0\xde" + block(8, b"\0" * 4) + block(25, blob(table)) + block(23, blob(b"entry"))


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
        assert 'license = "MIT"' in provider_metadata
        for name in ("LICENSE", "README.md", "ORIGINS.md", "docs/WRITING.md", "docs/API.md"):
            assert (provider / name).is_file() and (provider / name).stat().st_size > 0, name
        assert (provider / "LICENSE").read_bytes() == (root / "LICENSE").read_bytes()
        (consumer / "moon.mod").write_text(
            f'name = "verification/moonar-consumer"\nversion = "0.1.0"\n'
            f'import {{ "{module}@{version}", }}\n', encoding="utf-8",
        )
        (consumer / "moon.work").write_text('members = [ ".", "./provider" ]\n', encoding="utf-8")
        (consumer / "moon.pkg").write_text(
            f'import {{ "{module}" @ar, "{module}/cli" @cli, }} for "test"\n', encoding="utf-8",
        )
        fixture = 'b"' + "".join(f"\\x{byte:02x}" for byte in elf_fixture()) + '"'
        bitcode = 'b"' + "".join(f"\\x{byte:02x}" for byte in bitcode_fixture()) + '"'
        (consumer / "consumer_test.mbt").write_text(
            CONSUMER.replace("__OBJECT__", fixture).replace("__BITCODE__", bitcode).lstrip(), encoding="utf-8",
        )
        output = run([
            args.moon, "test", "--target", "all", "--deny-warn",
            "--package", "verification/moonar-consumer",
        ], consumer)
        print(output.strip())
    record = {
        "version": version, "archive": str(archive), "archive_sha256": digest,
        "packaged_files": len(files), "consumer_tests_per_target": len(re.findall(r'^test "', CONSUMER, re.M)),
        "targets": ["wasm", "wasm-gc", "js", "native"], "passed": True,
        "interfaces": [
            "symbols_from_object", "ArchiveBuilder.discover_symbols",
            "ArchiveBuilder.insert", "WriteFormat seven layouts",
            "ThinArchiveBuilder", "ThinArchive.materialize", "compare_logical",
            "ThinArchive.validate_members", "ArchiveSnapshot.compare_logical",
            "ThinArchive.resolve_member", "ThinArchive.member_sources", "NestedLimits", "WriteFormat.Coff",
            "LLVM bitcode version-3 symbol discovery",
            "cli.run host path semantics",
            "cli.run direct request validation before filesystem access",
        ],
        "license_and_documentation_present": True,
    }
    report = args.report if args.report.is_absolute() else root / args.report
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"PASS packaged public API consumer: {version}, {len(files)} files, SHA-256 {digest}")


if __name__ == "__main__":
    main()
