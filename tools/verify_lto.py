"""Verify LLVM bitcode archives with compiler-produced objects and real LTO links.

Requires Clang, LLD and LLVM ar, or a Zig installation providing those tools.
Both full and ThinLTO object inputs are exercised. Python 3.9+ is required.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(args, cwd, expected=0):
    result = subprocess.run([str(item) for item in args], cwd=cwd, capture_output=True, timeout=180)
    assert result.returncode == expected, (args, result.returncode,
        result.stdout.decode(errors="replace"), result.stderr.decode(errors="replace"))
    return result.stdout


def document(exe, cwd, archive):
    return json.loads(run([exe, "inspect", archive, "--json"], cwd))


def verify(exe, compiler, archiver, mode, cwd, zig):
    flags = ["-flto=thin" if mode == "thin" else "-flto", "-O2", "-fcommon"]
    (cwd / "alpha.c").write_text(
        "extern int beta(void); static volatile int local_state=17; int lto_common;\n"
        "__attribute__((weak)) int weak_value(void) { return 3; }\n"
        "int alpha(void) { return local_state+beta()+weak_value(); }\n")
    (cwd / "beta.c").write_text(
        "int beta(void) { return 22; }\n"
        "int beta_alias(void) __attribute__((alias(\"beta\")));\n")
    (cwd / "replacement.c").write_text("int beta(void) { return 24; }\n")
    (cwd / "native.c").write_text("int native_value(void) { return 9; }\n")
    (cwd / "templates.cc").write_text(
        "template<class T> __attribute__((noinline)) T twice(T value) { return value+value; }\n"
        "extern \"C\" int template_value(int value) { return twice(value); }\n")
    (cwd / "main.c").write_text(
        "int alpha(void); int main(void) { return alpha()==EXPECTED ? 0 : 1; }\n")
    for name in ("alpha", "beta", "replacement"):
        run([*compiler, *flags, "-c", name + ".c", "-o", name + ".bc"], cwd)
    run([*compiler, "-O2", "-c", "native.c", "-o", "native.o"], cwd)
    run([*compiler, *flags, "-fno-exceptions", "-fno-rtti", "-c", "templates.cc", "-o", "templates.bc"], cwd)
    run([*archiver, "rcsD", "reference.a", "alpha.bc", "beta.bc", "templates.bc"], cwd)
    def cli(*args, expected=0):
        return run([exe, *args], cwd, expected)
    def link(archive, answer, label):
        extra = [] if zig else ["-fuse-ld=lld"]
        target = cwd / (label + ".exe")
        run([*compiler, *flags, *extra, "-DEXPECTED=" + str(answer), "main.c", archive, "-o", target], cwd)
        run([target], cwd)
    cli("create", "created.a", "alpha.bc", "beta.bc", "templates.bc")
    cli("diff", "reference.a", "created.a", "--logical")
    names = [symbol["name_display"] for table in document(exe, cwd, "created.a")["symbol_indexes"] for symbol in table["symbols"]]
    assert "alpha" in names and "beta" in names and "lto_common" in names and "beta_alias" in names
    assert "local_state" not in names
    link("created.a", 42, "created")
    cli("replace", "created.a", 1, "replacement.bc")
    cli("move", "created.a", 1, 0)
    cli("index", "created.a")
    link("created.a", 44, "edited")
    cli("extract", "created.a", 0, "extracted.bc")
    assert (cwd / "extracted.bc").read_bytes() == (cwd / "replacement.bc").read_bytes()
    for fmt in ("gnu", "gnu64"):
        thin = fmt + "-thin.a"
        cli("create", thin, "alpha.bc", "beta.bc", "--thin", "--format", fmt)
        link(thin, 42, fmt + "-thin")
        cli("replace", thin, 1, "replacement.bc", "--format", fmt)
        link(thin, 44, fmt + "-thin-edited")
        packed = fmt + "-packed.a"
        cli("convert", thin, packed, "--format", fmt)
        link(packed, 44, fmt + "-materialized")
    cli("create", "nested.a", "reference.a", "--thin")
    cli("convert", "nested.a", "nested-materialized.a")
    link("nested-materialized.a", 42, "nested")
    cli("convert", "reference.a", "converted.a", "--format", "gnu64")
    link("converted.a", 42, "converted")
    cli("create", "mixed.a", "alpha.bc", "beta.bc", "templates.bc", "native.o")
    (cwd / "main.c").write_text(
        "int alpha(void); int native_value(void); int template_value(int); int main(void) { return alpha()+native_value()+template_value(3)==EXPECTED ? 0 : 1; }\n")
    link("mixed.a", 57, "mixed")
    if os.name == "nt":
        cli("create", "coff.lib", "alpha.bc", "beta.bc", "templates.bc", "native.o", "--format", "coff")
        link("coff.lib", 57, "coff")
    original = (cwd / "created.a").read_bytes()
    cli("index", "created.a", "--max-symbols", 0, expected=2)
    assert (cwd / "created.a").read_bytes() == original
    (cwd / "broken.bc").write_bytes((cwd / "alpha.bc").read_bytes()[:100])
    cli("replace", "created.a", 0, "broken.bc", expected=2)
    assert (cwd / "created.a").read_bytes() == original
    # Mach-O bitcode is wrapped; Darwin archive alignment can add payload bytes.
    target = "x86_64-macos" if zig else "x86_64-apple-darwin"
    wrapped_flags = ["-emit-llvm", "-O2", "-fcommon"] if zig else flags
    run([*compiler, "-target", target, *wrapped_flags, "-c", "alpha.c", "-o", "wrapped.bc"], cwd)
    assert (cwd / "wrapped.bc").read_bytes()[:4] == b"\xde\xc0\x17\x0b"
    run([*archiver, "--format=darwin", "rcsD", "wrapped-reference.a", "wrapped.bc"], cwd)
    cli("create", "wrapped.a", "wrapped.bc", "--format", "darwin")
    cli("diff", "wrapped-reference.a", "wrapped.a", "--logical")
    cli("index", "wrapped.a", "--format", "darwin")
    print(f"PASS {mode} LTO: LLVM mappings, weak/common/alias definitions, full edits, direct thin and nested materialization, mixed native objects, wrapped Mach-O and actual link/run")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True)
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--llvm-ar", default=shutil.which("llvm-ar"))
    parser.add_argument("--zig")
    parser.add_argument("--gcc", default=shutil.which("gcc"))
    args = parser.parse_args()
    if args.zig:
        compiler, archiver = [args.zig, "cc"], [args.zig, "ar"]
    else:
        if not args.clang or not args.llvm_ar:
            parser.error("Clang and LLVM ar, or --zig, are required")
        compiler, archiver = [args.clang], [args.llvm_ar]
    exe = Path(args.moonar).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="moonar-lto-") as directory:
        root = Path(directory).resolve()
        assert root.parent == Path(tempfile.gettempdir()).resolve()
        for mode in ("full", "thin"):
            cwd = root / mode
            cwd.mkdir()
            verify(exe, compiler, archiver, mode, cwd, bool(args.zig))
        if args.gcc:
            cwd = root / "gcc"
            cwd.mkdir()
            (cwd / "value.c").write_text("int value(void) { return 42; }\n")
            (cwd / "main.c").write_text("int value(void); int main(void) { return value()==42 ? 0 : 1; }\n")
            run([args.gcc, "-flto", "-fno-fat-lto-objects", "-c", "value.c", "-o", "slim.o"], cwd)
            original = b"preserve existing output"
            (cwd / "slim.a").write_bytes(original)
            reply = json.loads(run([exe, "create", "slim.a", "slim.o", "--force", "--json"], cwd, expected=2))
            assert reply["error"]["code"] == "WR006" and "GCC slim LTO" in reply["error"]["message"]
            assert (cwd / "slim.a").read_bytes() == original
            run([args.gcc, "-flto", "-ffat-lto-objects", "-c", "value.c", "-o", "fat.o"], cwd)
            run([exe, "create", "fat.a", "fat.o"], cwd)
            target = cwd / "fat.exe"
            run([args.gcc, "-fno-lto", "-fno-use-linker-plugin", "main.c", "fat.a", "-o", target], cwd)
            run([target], cwd)
            print("PASS GCC: slim LTO is rejected before output replacement; fat object native definitions link/run")


if __name__ == "__main__":
    main()
