"""Verify archive management with real files, objects and independent tools.

Python 3.9+, a native MoonAr CLI, GNU ar/nm and a C compiler are required.
LLVM ar is optional locally and required with --require-llvm. Optional Clang or
Zig adds Mach-O object checks; Zig also links the Darwin archives.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(args, cwd, expected=0, env=None):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, capture_output=True,
        check=False, env=env, timeout=90,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"{args!r}: exit {result.returncode}, expected {expected}\n"
            + result.stdout.decode("utf-8", errors="replace")
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout


def inspect(exe, cwd, path):
    return json.loads(run([exe, "inspect", path, "--json"], cwd))


def regular(document):
    return [entry for entry in document["members"] if entry["kind"] == "regular"]


def mappings(document):
    names = {
        entry["index"]: bytes.fromhex(entry["name_hex"])
        for entry in regular(document)
    }
    return [
        (bytes.fromhex(symbol["name_hex"]), names[symbol["member_index"]])
        for index in document["symbol_indexes"] for symbol in index["symbols"]
    ]


def assert_error(exe, cwd, args, code=None):
    reply = json.loads(run([exe, *args, "--json"], cwd, expected=2))
    assert "error" in reply, reply
    if code:
        assert reply["error"]["code"] == code, reply


def extract_oracle(exe, ar, llvm, cwd, archive, expected, darwin=False):
    document = inspect(exe, cwd, archive)
    entries = regular(document)
    names = [name.encode() for name, _ in expected]
    assert [bytes.fromhex(item["name_hex"]) for item in entries] == names
    for label, tool in [("gnu", ar), ("llvm", llvm)]:
        if not tool:
            continue
        # Older GNU binutils displays embedded BSD symbol tables as entries.
        actual = [
            item for item in run([tool, "t", archive], cwd).splitlines()
            if item not in (b"__.SYMDEF", b"__.SYMDEF_64")
        ]
        assert actual == names, (archive, label, actual, names)
        destination = cwd / (archive + "-" + label + "-extract")
        destination.mkdir()
        occurrences = {}
        for i, (name, payload) in enumerate(expected):
            payload = payload + b"\n" * (-len(payload) % 8) if darwin else payload
            occurrences[name] = occurrences.get(name, 0) + 1
            run([tool, "xN", occurrences[name], cwd / archive, name], destination)
            assert (destination / name).read_bytes() == payload, (archive, name)
            target = destination / ("cli-" + str(i))
            run([exe, "extract", cwd / archive, i, target], cwd)
            assert target.read_bytes() == payload, (archive, name, "CLI")
    return document


def compile_objects(cc, cwd):
    sources = {
        "alpha": "int moon_alpha(void) { return 17; }\n",
        "beta": "int moon_beta(void) { return 25; }\n",
        "replacement": "int moon_alpha(void) { return 19; }\n",
        "unused": "int moon_unused(void) { return 99; }\n",
    }
    for name, text in sources.items():
        (cwd / (name + ".c")).write_text(text)
        run([cc, "-c", name + ".c", "-o", name + ".o"], cwd)
    (cwd / "main.c").write_text(
        "int moon_alpha(void); int moon_beta(void);\n"
        "int main(void) { return moon_alpha() + moon_beta() == EXPECTED ? 0 : 1; }\n"
    )


def link_run(cc, cwd, archive, answer, label, expected=0):
    target = cwd / (label + ".exe")
    run([cc, f"-DEXPECTED={answer}", "main.c", archive, "-o", target], cwd)
    run([target], cwd, expected=expected)


def verify_native_edits(exe, ar, nm, cc, llvm, cwd):
    compile_objects(cc, cwd)
    run([exe, "create", "library.a", "alpha.o", "beta.o"], cwd)
    original = (cwd / "library.a").read_bytes()
    run([exe, "create", "repeat.a", "alpha.o", "beta.o"], cwd)
    assert original == (cwd / "repeat.a").read_bytes()
    link_run(cc, cwd, "library.a", 42, "initial")
    map_text = run([nm, "--print-armap", "library.a"], cwd)
    assert b"moon_alpha in alpha.o" in map_text
    assert b"moon_beta in beta.o" in map_text
    run([exe, "replace", "library.a", 0, "replacement.o"], cwd)
    link_run(cc, cwd, "library.a", 42, "old-result", expected=1)
    link_run(cc, cwd, "library.a", 44, "replacement-result")
    run([exe, "move", "library.a", 1, 0], cwd)
    run([exe, "rename", "library.a", 1, "renamed alpha.o"], cwd)
    run([exe, "add", "library.a", "unused.o", "--at", 1], cwd)
    run([exe, "delete", "library.a", 1], cwd)
    document = extract_oracle(exe, ar, llvm, cwd, "library.a", [
        ("beta.o", (cwd / "beta.o").read_bytes()),
        ("renamed alpha.o", (cwd / "replacement.o").read_bytes()),
    ])
    assert mappings(document) == [
        (b"moon_beta", b"beta.o"), (b"moon_alpha", b"renamed alpha.o"),
    ]
    link_run(cc, cwd, "library.a", 44, "edited-result")
    run([exe, "create", "unindexed.a", "alpha.o", "beta.o", "--index", "none"], cwd)
    assert inspect(exe, cwd, "unindexed.a")["symbol_indexes"] == []
    run([exe, "index", "unindexed.a"], cwd)
    link_run(cc, cwd, "unindexed.a", 42, "reindexed-result")
    print("CLI create/replace/move/rename/add/delete/index and actual link/run: OK")


def verify_formats(exe, ar, nm, cc, llvm, cwd):
    expected = [
        ("alpha.o", (cwd / "alpha.o").read_bytes()),
        ("beta.o", (cwd / "beta.o").read_bytes()),
    ]
    for fmt in ("gnu", "gnu64", "bsd", "bsd64", "darwin", "darwin64"):
        name = fmt + "-automatic.a"
        run([exe, "create", name, "alpha.o", "beta.o", "--format", fmt], cwd)
        document = extract_oracle(
            exe, ar, llvm, cwd, name, expected, darwin=fmt.startswith("darwin"),
        )
        assert mappings(document) == [
            (b"moon_alpha", b"alpha.o"), (b"moon_beta", b"beta.o"),
        ]
        bits = "64" if fmt.endswith("64") else "32"
        assert document["symbol_indexes"][0]["format"] == (
            "gnu" + bits if fmt.startswith("gnu") else "bsd" + bits + "-le"
        )
        if fmt.startswith("gnu"):
            map_text = run([nm, "--print-armap", name], cwd)
            assert b"moon_alpha in alpha.o" in map_text
            link_run(cc, cwd, name, 42, fmt + "-automatic")
        else:
            big = fmt + "-big.a"
            run([
                exe, "create", big, "alpha.o", "beta.o", "--format", fmt,
                "--big-endian-index",
            ], cwd)
            assert inspect(exe, cwd, big)["symbol_indexes"][0]["format"] == (
                "bsd" + bits + "-be"
            )
        converted = fmt + "-converted.a"
        run([exe, "convert", name, converted, "--format", "gnu"], cwd)
        link_run(cc, cwd, converted, 42, fmt + "-converted")
    print("CLI six output layouts, automatic indexes, endian choices and conversion: OK")


def verify_duplicates_and_errors(exe, ar, llvm, cwd):
    for folder, payload in [("first", b"one\n"), ("second", b"\x00two\n\n")]:
        (cwd / folder).mkdir()
        (cwd / folder / "same.txt").write_bytes(payload)
    run([exe, "create", "duplicates.a", "first/same.txt", "second/same.txt"], cwd)
    run([exe, "move", "duplicates.a", 0, 1], cwd)
    extract_oracle(exe, ar, llvm, cwd, "duplicates.a", [
        ("same.txt", b"\x00two\n\n"), ("same.txt", b"one\n"),
    ])
    original = (cwd / "library.a").read_bytes()
    (cwd / "broken.o").write_bytes(b"\x7fELF\x02\x01")
    assert_error(exe, cwd, ["replace", "library.a", 0, "broken.o"])
    assert (cwd / "library.a").read_bytes() == original
    for args in [
        ["delete", "library.a", 999],
        ["delete", "library.a", 0, 0],
        ["move", "library.a", 0, 99],
        ["add", "library.a", "unused.o", "--at", 99],
        ["rename", "library.a", 0, "bad\nname"],
        ["index", "library.a", "--max-symbols", 0],
        ["extract", "library.a", 0, "library.a", "--force"],
    ]:
        assert_error(exe, cwd, args)
        assert (cwd / "library.a").read_bytes() == original
    (cwd / "occupied.a").write_bytes(b"keep this output")
    assert_error(exe, cwd, ["create", "occupied.a", "alpha.o"])
    assert (cwd / "occupied.a").read_bytes() == b"keep this output"
    run([exe, "create", "occupied.a", "alpha.o", "--force"], cwd)
    assert regular(inspect(exe, cwd, "occupied.a"))[0]["name_display"] == "alpha.o"
    assert_error(exe, cwd, ["extract", "library.a", 0, "occupied.a"])
    assert_error(exe, cwd, ["create", "limited.a", "alpha.o", "--max-bytes", 8])
    assert not (cwd / "limited.a").exists()
    # GNU can safely hold special-looking filenames using ordinary long references.
    (cwd / "__.SYMDEF SORTED").write_bytes(b"ordinary file")
    run([ar, "qcDS", "reserved-reference.a", "__.SYMDEF SORTED"], cwd)
    document = inspect(exe, cwd, "reserved-reference.a")
    assert document["symbol_indexes"] == []
    assert regular(document)[0]["name_display"] == "__.SYMDEF SORTED"
    run([exe, "create", "reserved-written.a", "__.SYMDEF SORTED"], cwd)
    assert run([ar, "t", "reserved-written.a"], cwd).splitlines() == [b"__.SYMDEF SORTED"]
    print("CLI duplicate positions, rejected updates, overwrite rules and reserved filenames: OK")


def verify_thin(exe, ar, nm, cc, llvm, cwd):
    for fmt in ("gnu", "gnu64"):
        archive = fmt + "-thin.a"
        run([exe, "create", archive, "alpha.o", "beta.o", "--thin", "--format", fmt], cwd)
        assert (cwd / archive).read_bytes().startswith(b"!<thin>\n")
        document = inspect(exe, cwd, archive)
        assert mappings(document) == [
            (b"moon_alpha", b"alpha.o"), (b"moon_beta", b"beta.o"),
        ]
        assert run([ar, "t", archive], cwd).splitlines() == [b"alpha.o", b"beta.o"]
        assert b"moon_alpha in " in run([nm, "--print-armap", archive], cwd)
        if llvm:
            assert run([llvm, "t", archive], cwd).splitlines() == [b"alpha.o", b"beta.o"]
            assert run([llvm, "p", archive], cwd) == (
                (cwd / "alpha.o").read_bytes() + (cwd / "beta.o").read_bytes()
            )
        link_run(cc, cwd, archive, 42, fmt + "-thin-linked")
    (cwd / "relocated").mkdir()
    before = (cwd / "gnu-thin.a").read_bytes()
    run([exe, "move", "gnu-thin.a", 1, 0, "--output", "relocated/library.a"], cwd)
    assert (cwd / "gnu-thin.a").read_bytes() == before
    moved = inspect(exe, cwd, "relocated/library.a")
    assert [entry["name_display"] for entry in regular(moved)] == ["../beta.o", "../alpha.o"]
    assert_error(exe, cwd, ["extract", "relocated/library.a", 0, "blocked.o"])
    assert not (cwd / "blocked.o").exists()
    run([
        exe, "extract", "relocated/library.a", 0, "extracted-thin.o", "--allow-parent-paths",
    ], cwd)
    assert (cwd / "extracted-thin.o").read_bytes() == (cwd / "beta.o").read_bytes()
    run([
        exe, "convert", "relocated/library.a", "materialized.a", "--allow-parent-paths",
    ], cwd)
    link_run(cc, cwd, "materialized.a", 42, "materialized-linked")
    # Missing external files can be removed without loading the surviving members.
    (cwd / "missing.o").write_bytes(b"missing")
    run([exe, "create", "missing-thin.a", "missing.o", "alpha.o", "--thin", "--index", "none"], cwd)
    (cwd / "missing.o").unlink()
    original = (cwd / "missing-thin.a").read_bytes()
    assert_error(exe, cwd, ["index", "missing-thin.a"])
    assert (cwd / "missing-thin.a").read_bytes() == original
    run([exe, "delete", "missing-thin.a", 0, "--index", "none"], cwd)
    assert [entry["name_display"] for entry in regular(inspect(exe, cwd, "missing-thin.a"))] == ["alpha.o"]
    run([exe, "index", "missing-thin.a"], cwd)
    assert mappings(inspect(exe, cwd, "missing-thin.a")) == [(b"moon_alpha", b"alpha.o")]
    # Declared sizes protect readers against changed external files.
    (cwd / "changing.bin").write_bytes(b"initial")
    run([exe, "create", "changing.a", "changing.bin", "--thin", "--index", "none"], cwd)
    (cwd / "changing.bin").write_bytes(b"a different length")
    assert_error(exe, cwd, ["extract", "changing.a", 0, "changed.bin"], "AR014")
    assert not (cwd / "changed.bin").exists()
    print("CLI thin write/index/link, rebasing, explicit loading, deletion and materialization: OK")


def verify_macho(exe, llvm, clang, zig, cwd):
    if not llvm or not (clang or zig):
        print("Mach-O interoperability skipped: supply --clang or --zig and --llvm-ar")
        return
    compiler = [zig, "cc", "-target", "x86_64-macos"] if zig else [
        clang, "-target", "x86_64-apple-darwin",
    ]
    for name in ("alpha", "beta"):
        run([*compiler, "-c", name + ".c", "-o", name + "-macho.o"], cwd)
    for fmt in ("bsd", "bsd64", "darwin", "darwin64"):
        archive = fmt + "-macho.a"
        run([exe, "create", archive, "alpha-macho.o", "beta-macho.o", "--format", fmt], cwd)
        document = inspect(exe, cwd, archive)
        assert mappings(document) == [
            (b"_moon_alpha", b"alpha-macho.o"), (b"_moon_beta", b"beta-macho.o"),
        ]
        assert run([llvm, "t", archive], cwd).splitlines() == [
            b"alpha-macho.o", b"beta-macho.o",
        ]
        if zig:
            run([
                *compiler, "-DEXPECTED=42", "-c", "main.c", "-o", "main-macho.o",
            ], cwd)
            run([
                *compiler, "-nostdlib", "-Wl,-e,_main", "main-macho.o", archive,
                "-o", fmt + "-macho-linked",
            ], cwd)
    run([llvm, "--format=darwin", "rcsD", "reference-macho.a", "alpha-macho.o", "beta-macho.o"], cwd)
    assert mappings(inspect(exe, cwd, "reference-macho.a")) == mappings(document)
    print("Mach-O automatic symbols, LLVM reference indexes and BSD/Darwin layouts: OK")
    if zig:
        print("All four BSD/Darwin Mach-O archives linked successfully; execution requires macOS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True)
    parser.add_argument("--ar", default=shutil.which("ar"))
    parser.add_argument("--nm", default=shutil.which("nm"))
    parser.add_argument("--cc", default=shutil.which("gcc") or shutil.which("cc"))
    parser.add_argument("--llvm-ar", default=shutil.which("llvm-ar"))
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--zig")
    parser.add_argument("--require-llvm", action="store_true")
    args = parser.parse_args()
    if not args.ar or not args.nm or not args.cc:
        parser.error("GNU ar/nm and a C compiler are required")
    if args.require_llvm and not args.llvm_ar:
        parser.error("LLVM ar is required")
    exe = str(Path(args.moonar).resolve())
    with tempfile.TemporaryDirectory(prefix="moonar-cli-") as temporary:
        cwd = Path(temporary)
        verify_native_edits(exe, args.ar, args.nm, args.cc, args.llvm_ar, cwd)
        verify_formats(exe, args.ar, args.nm, args.cc, args.llvm_ar, cwd)
        verify_duplicates_and_errors(exe, args.ar, args.llvm_ar, cwd)
        verify_thin(exe, args.ar, args.nm, args.cc, args.llvm_ar, cwd)
        verify_macho(exe, args.llvm_ar, args.clang, args.zig, cwd)


if __name__ == "__main__":
    main()
