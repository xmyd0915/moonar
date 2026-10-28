"""Compile, link and execute Mach-O consumers on a native macOS host.

Uses Apple's Clang, linker, ar, nm and libtool through xcrun. No cross-target
execution or emulation is used. Requires Python 3.9+ and Xcode command-line tools.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile


def run(args, cwd, expected=0):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, capture_output=True, timeout=120)
    if result.returncode != expected:
        raise AssertionError((args, result.returncode, result.stdout.decode(errors="replace"),
                              result.stderr.decode(errors="replace")))
    return result.stdout


def verify(exe, cwd):
    def cli(*args, expected=0):
        return run([exe, *args], cwd, expected)

    def inspect(archive):
        return json.loads(cli("inspect", archive, "--json"))

    executions = []

    def execute(archive, answer, label):
        target = cwd / label
        run(["xcrun", "clang", "main.c", archive, "-o", target], cwd)
        actual = run([target], cwd)
        assert actual == f"{answer}\n".encode(), (archive, actual, answer)
        executions.append({"archive": archive, "result": answer})

    def symbols(document):
        names = {entry["index"]: entry["name_display"] for entry in document["members"]}
        return sorted((entry["name_display"], names[entry["member_index"]])
                      for table in document["symbol_indexes"] for entry in table["symbols"])

    sources = {
        "alpha_long_object_name": "int moon_alpha(void) { return 17; }\n",
        "beta": "int moon_beta(void) { return 25; }\n",
        "replacement": "int moon_beta(void) { return 27; }\n",
        "unused": "int moon_unused(void) { return 9; }\n",
    }
    for name, source in sources.items():
        (cwd / (name + ".c")).write_text(source)
        run(["xcrun", "clang", "-O2", "-c", name + ".c", "-o", name + ".o"], cwd)
    (cwd / "main.c").write_text(
        '#include <stdio.h>\nint moon_alpha(void); int moon_beta(void);\n'
        'int main(void) { printf("%d\\n", moon_alpha()+moon_beta()); return 0; }\n')
    objects = ["alpha_long_object_name.o", "beta.o"]
    run(["xcrun", "libtool", "-static", "-D", "-o", "reference.a", *objects], cwd)
    reference = inspect("reference.a")
    assert symbols(reference) == [("_moon_alpha", objects[0]), ("_moon_beta", objects[1])]
    execute("reference.a", 42, "reference-consumer")
    for fmt in ("bsd", "bsd64", "darwin", "darwin64"):
        archive = fmt + ".a"
        cli("create", archive, *objects, "--format", fmt)
        assert symbols(inspect(archive)) == symbols(reference)
        listed = run(["xcrun", "ar", "t", archive], cwd).splitlines()
        assert [name for name in listed if not name.startswith(b"__.SYMDEF")] == [name.encode() for name in objects]
        nm = run(["xcrun", "nm", "-gU", archive], cwd)
        assert b"_moon_alpha" in nm and b"_moon_beta" in nm
        for name in objects:
            data = (cwd / name).read_bytes()
            expected = data + b"\n" * (-len(data) % 8) if fmt.startswith("darwin") else data
            assert run(["xcrun", "ar", "p", archive, name], cwd) == expected
        execute(archive, 42, fmt + "-created")
        cli("replace", archive, 1, "replacement.o", "--format", fmt)
        cli("move", archive, 1, 0, "--format", fmt)
        cli("rename", archive, 0, "renamed beta.o", "--format", fmt)
        cli("add", archive, "unused.o", "--at", 1, "--format", fmt)
        cli("delete", archive, 1, "--format", fmt)
        cli("index", archive, "--format", fmt)
        execute(archive, 44, fmt + "-edited")
        extracted = fmt + "-extracted.o"
        cli("extract", archive, 0, extracted)
        data = (cwd / "replacement.o").read_bytes()
        expected = data + b"\n" * (-len(data) % 8) if fmt.startswith("darwin") else data
        assert (cwd / extracted).read_bytes() == expected
        converted = fmt + "-converted.a"
        cli("convert", archive, converted, "--format", "darwin")
        execute(converted, 44, fmt + "-converted")
        original = (cwd / archive).read_bytes()
        reply = json.loads(cli("index", archive, "--format", fmt, "--max-symbols", 0, "--json", expected=2))
        assert reply["error"]["code"] == "AR008" and (cwd / archive).read_bytes() == original
        print(f"PASS macOS {fmt}: Apple tools, native execution 42 -> 44, complete edits, conversion and failure preservation")
    for fmt in ("gnu", "gnu64"):
        thin = fmt + "-thin.a"
        cli("create", thin, *objects, "--thin", "--format", fmt)
        cli("check", thin, "--external")
        cli("replace", thin, 1, "replacement.o", "--format", fmt)
        cli("move", thin, 1, 0, "--format", fmt)
        packed = fmt + "-packed.a"
        cli("convert", thin, packed, "--format", "darwin")
        execute(packed, 44, fmt + "-materialized")
    # Retain Apple's mode fields when comparing complete logical metadata.
    cli("create", "nested.a", "reference.a", "--thin", "--preserve-metadata")
    cli("check", "nested.a", "--external")
    cli("diff", "nested.a", "reference.a", "--logical")
    cli("convert", "nested.a", "nested-packed.a", "--format", "darwin")
    execute("nested-packed.a", 42, "nested-materialized")
    print("PASS macOS: GNU32/64 thin edits and nested thin materialization execute natively")
    return executions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True, type=Path)
    parser.add_argument("--report", type=Path, default=Path("_build/verification/macos-consumer.json"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native macOS execution is required")
    exe = args.moonar.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="moonar-macos-") as temporary:
        cwd = Path(temporary)
        executions = verify(exe, cwd)
        record = {
            "schema_version": 1, "passed": True, "platform": platform.platform(),
            "architecture": platform.machine(), "native_execution": True,
            "moonar_version": run([exe, "--version"], cwd).decode().strip(),
            "executable_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
            "compiler": run(["xcrun", "clang", "--version"], cwd).decode().strip(),
            "executions": executions,
        }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"PASS macOS {record['architecture']}: {len(executions)} compiled consumers executed")


if __name__ == "__main__":
    main()
