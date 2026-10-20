"""Exercise the public write/edit/thin API against GNU and LLVM tools."""

import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
from verify_archives import run


SAMPLES = [
    ("short.txt", b"hello\n"),
    ("a_long_member_name_for_testing.bin", b"\x00\xff\x0a"),
    ("same.txt", b"first"),
    ("same.txt", b"second"),
    ("empty", b""),
]


def inventory(ar, cwd, archive, expected):
    assert run([ar, "t", archive], cwd).splitlines() == [
        name.encode() for name, _ in expected
    ], archive
    destination = cwd / (archive + "-extracted")
    destination.mkdir()
    counts = {}
    for name, data in expected:
        counts[name] = counts.get(name, 0) + 1
        run([ar, "xN", counts[name], cwd / archive, name], destination)
        assert (destination / name).read_bytes() == data, (archive, name)


def verify_writer(exe, ar, llvm, cwd):
    for dialect in ("gnu", "bsd"):
        archive = dialect + "-written.a"
        run([exe, "create", archive, dialect], cwd)
        run([exe, "create", dialect + "-repeat.a", dialect], cwd)
        assert (cwd / archive).read_bytes() == (
            cwd / (dialect + "-repeat.a")
        ).read_bytes()
        inventory(ar, cwd, archive, SAMPLES)
        if llvm:
            assert run([llvm, "t", archive], cwd).splitlines() == [
                name.encode() for name, _ in SAMPLES
            ]
            # GNU validates each duplicate with xN. LLVM additionally reads the
            # complete concatenated byte stream, including empty/binary entries.
            assert run([llvm, "p", archive], cwd) == b"".join(
                data for _, data in SAMPLES
            )

    inputs = []
    for i, (name, data) in enumerate(SAMPLES):
        folder = cwd / str(i)
        folder.mkdir()
        (folder / name).write_bytes(data)
        inputs.append(f"{i}/{name}")
    producers = [(ar, [])]
    if llvm:
        producers.append((llvm, ["--format=bsd"]))
    for i, (producer, options) in enumerate(producers):
        source = f"external-{i}.a"
        target = f"edited-{i}.a"
        run([producer, *options, "qcDS", source, *inputs], cwd)
        original = (cwd / source).read_bytes()
        run([exe, "edit", source, target], cwd)
        assert (cwd / source).read_bytes() == original
        inventory(ar, cwd, target, [
            ("same.txt", b"second"),
            ("short.txt", b"updated"),
            ("same.txt", b"first"),
            ("empty", b""),
            ("added.txt", b"appended"),
        ])
    print("GNU/BSD creation, deterministic bytes and duplicate-member edits: OK")


def verify_thin(exe, ar, llvm, cwd):
    members = ["thin_a.bin", "thin_long_member_name.bin", "thin_empty.bin"]
    payloads = [b"odd", b"\x00\xff\x0a\x01", b""]
    mapping = []
    for name, payload in zip(members, payloads):
        (cwd / name).write_bytes(payload)
        mapping.extend([name, name])
    for i, producer in enumerate([ar] + ([llvm] if llvm else [])):
        archive = f"thin-{i}.a"
        run([producer, "qcDST", archive, *members], cwd)
        report = json.loads(run([exe, "thin", archive, *mapping], cwd))
        assert report["symbol_count"] == 0
        assert report["members"] == [
            {"name_hex": name.encode().hex(), "size": len(payload)}
            for name, payload in zip(members, payloads)
        ]
        regular = f"materialized-{i}.a"
        run([exe, "materialize", archive, regular, *mapping], cwd)
        inventory(ar, cwd, regular, list(zip(members, payloads)))
        run([exe, "thin", archive], cwd, expected=1)
        (cwd / "wrong.bin").write_bytes(b"wrong length")
        run([exe, "thin", archive, members[0], "wrong.bin"], cwd, expected=1)
    print("GNU/LLVM thin references, loading, failures and materialization: OK")


def verify_symbols(exe, ar, nm, cc, llvm, cwd):
    (cwd / "alpha.c").write_text("int moon_alpha(void) { return 17; }\n")
    (cwd / "beta.c").write_text("int moon_beta(void) { return 25; }\n")
    (cwd / "main.c").write_text(
        "int moon_alpha(void); int moon_beta(void);\n"
        "int main(void) { return moon_alpha() + moon_beta() == 42 ? 0 : 1; }\n"
    )
    run([cc, "-c", "alpha.c", "-o", "alpha.o"], cwd)
    run([cc, "-c", "beta.c", "-o", "beta.o"], cwd)
    run([exe, "indexed", "indexed.a", "alpha.o", "beta.o"], cwd)
    symbols = run([nm, "--print-armap", "indexed.a"], cwd)
    assert b"moon_alpha in a_long_alpha_object_name.o" in symbols
    assert b"moon_beta in beta.o" in symbols
    inventory(ar, cwd, "indexed.a", [
        ("a_long_alpha_object_name.o", (cwd / "alpha.o").read_bytes()),
        ("beta.o", (cwd / "beta.o").read_bytes()),
    ])
    if llvm:
        assert run([llvm, "t", "indexed.a"], cwd).splitlines() == [
            b"a_long_alpha_object_name.o", b"beta.o"
        ]
    run([cc, "main.c", "indexed.a", "-o", "linked.exe"], cwd)
    run([cwd / "linked.exe"], cwd)
    original = (cwd / "indexed.a").read_bytes()
    (cwd / "replacement.c").write_text("int moon_alpha(void) { return 19; }\n")
    run([cc, "-c", "replacement.c", "-o", "replacement.o"], cwd)
    run([exe, "reindex", "indexed.a", "reindexed.a", "replacement.o"], cwd)
    assert (cwd / "indexed.a").read_bytes() == original
    inventory(ar, cwd, "reindexed.a", [
        ("beta.o", (cwd / "beta.o").read_bytes()),
        ("replacement_alpha.o", (cwd / "replacement.o").read_bytes()),
    ])
    symbols = run([nm, "--print-armap", "reindexed.a"], cwd)
    assert b"moon_alpha in replacement_alpha.o" in symbols
    assert b"moon_beta in beta.o" in symbols
    # The old expected result must fail; the changed implementation must link
    # and return the new result after replacement and member reordering.
    run([cc, "main.c", "reindexed.a", "-o", "changed.exe"], cwd)
    run([cwd / "changed.exe"], cwd, expected=1)
    (cwd / "main.c").write_text(
        "int moon_alpha(void); int moon_beta(void);\n"
        "int main(void) { return moon_alpha() + moon_beta() == 44 ? 0 : 1; }\n"
    )
    run([cc, "main.c", "reindexed.a", "-o", "changed.exe"], cwd)
    run([cwd / "changed.exe"], cwd)
    for i, producer in enumerate([ar] + ([llvm] if llvm else [])):
        archive = f"thin-objects-{i}.a"
        run([producer, "rcsDT", archive, "alpha.o", "beta.o"], cwd)
        report = json.loads(run([
            exe, "thin", archive, "alpha.o", "alpha.o", "beta.o", "beta.o"
        ], cwd))
        assert report["symbol_count"] == 2, report
    # The example refuses to edit an indexed input without a policy.
    run([exe, "edit", "indexed.a", "must-not-exist.a"], cwd, expected=1)
    assert not (cwd / "must-not-exist.a").exists()
    print("GNU32 indexes, object replacement/reordering and real link/run: OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--ar", default=shutil.which("ar"))
    parser.add_argument("--nm", default=shutil.which("nm"))
    parser.add_argument("--cc", default=shutil.which("gcc") or shutil.which("cc"))
    parser.add_argument("--llvm-ar", default=shutil.which("llvm-ar"))
    parser.add_argument("--require-llvm", action="store_true")
    args = parser.parse_args()
    if not args.ar or not args.nm or not args.cc:
        parser.error("GNU ar/nm and a C compiler are required")
    if args.require_llvm and not args.llvm_ar:
        parser.error("LLVM ar is required")
    exe = str(Path(args.workflow).resolve())
    with tempfile.TemporaryDirectory(prefix="moonar-workflow-") as temporary:
        cwd = Path(temporary)
        verify_writer(exe, args.ar, args.llvm_ar, cwd)
        verify_thin(exe, args.ar, args.llvm_ar, cwd)
        verify_symbols(exe, args.ar, args.nm, args.cc, args.llvm_ar, cwd)
    if not args.llvm_ar:
        print("LLVM comparison skipped: llvm-ar is unavailable")


if __name__ == "__main__":
    main()
