"""Check native and Node CLI file publication and thin-path boundaries.

All inputs and aliases are created in one temporary directory. No compiler or
external archiver is needed. Windows uses directory junctions; other platforms
use directory symlinks to exercise canonical filesystem paths.
"""

import argparse
import base64
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def run(command, args, cwd, expected=0):
    result = subprocess.run(
        [*map(str, command), *map(str, args)],
        cwd=cwd, capture_output=True, check=False, timeout=60,
    )
    assert result.returncode == expected, (
        command, args, result.returncode,
        result.stdout.decode("utf-8", errors="replace"),
        result.stderr.decode("utf-8", errors="replace"),
    )
    return result


def directory_alias(link, target):
    assert not link.exists() and target.is_dir()
    if os.name == "nt":
        # This creates a junction only; Python's temporary-directory cleanup
        # removes the junction itself without traversing its target.
        def ps_literal(value):
            return "'" + str(value).replace("'", "''") + "'"

        script = (
            "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path "
            + ps_literal(link) + " -Target " + ps_literal(target) + " | Out-Null"
        )
        result = subprocess.run(
            [
                shutil.which("pwsh") or "powershell.exe", "-NoProfile", "-NonInteractive",
                "-EncodedCommand", base64.b64encode(script.encode("utf-16-le")).decode("ascii"),
            ],
            capture_output=True, check=False, timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
    else:
        link.symlink_to(target, target_is_directory=True)
    assert link.resolve() == target.resolve()


def thin_fixture(path, name, size):
    def header(record_name, stored_size):
        return b"".join([
            record_name.ljust(16), b"0".ljust(12), b"0".ljust(6),
            b"0".ljust(6), b"644".ljust(8),
            str(stored_size).encode().ljust(10), b"`\n",
        ])

    table = name + b"/\n"
    path.write_bytes(
        b"!<thin>\n" + header(b"//", len(table)) + table
        + b"\n" * (len(table) % 2) + header(b"/0", size)
    )


def ordinary_names(command, cwd, archive):
    document = json.loads(run(command, ["inspect", archive, "--json"], cwd).stdout)
    return [
        bytes.fromhex(entry["name_hex"]) for entry in document["members"]
        if entry["kind"] == "regular"
    ]


def verify_publication(label, command, root):
    place = root / label
    place.mkdir()
    first = place / "中文 α one.bin"
    second = place / "中文 β two.bin"
    first.write_bytes(b"first\x00" * 70001)
    second.write_bytes(b"second\x00" * 70003)
    archive = place / "成品 α.a"
    run(command, ["create", archive, first, "--index", "none"], root)
    original = archive.read_bytes()
    run(command, ["create", archive, second, "--index", "none"], root, expected=2)
    assert archive.read_bytes() == original
    if os.name != "nt":
        archive.chmod(0o600)
    run(command, ["create", archive, second, "--index", "none", "--force"], root)
    assert archive.read_bytes() != original
    if os.name != "nt":
        assert stat.S_IMODE(archive.stat().st_mode) == 0o600
        run(command, ["rename", archive, 0, "private.bin", "--index", "none"], root)
        assert stat.S_IMODE(archive.stat().st_mode) == 0o600
        print(f"PASS {label}: existing 0600 permissions remain private after replacement and editing")
    run(command, ["check", archive], root)
    extracted = place / "结果 β.bin"
    run(command, ["extract", archive, 0, extracted], root)
    assert extracted.read_bytes() == second.read_bytes()
    run(command, ["create", place, first, "--index", "none", "--force"], root, expected=2)
    assert place.is_dir() and first.read_bytes() == b"first\x00" * 70001
    before = archive.read_bytes()
    run(command, ["add", archive, place / "missing.bin"], root, expected=2)
    assert archive.read_bytes() == before

    def publish(source):
        return subprocess.run(
            [*map(str, command), "create", str(place / "race.a"), str(source), "--index", "none"],
            cwd=root, capture_output=True, check=False, timeout=60,
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(publish, [first, second]))
    assert sorted(item.returncode for item in results) == [0, 2], [
        (item.returncode, item.stdout, item.stderr) for item in results
    ]
    run(command, ["check", place / "race.a"], root)
    winner = place / "race-content.bin"
    run(command, ["extract", place / "race.a", 0, winner], root)
    assert winner.read_bytes() in (first.read_bytes(), second.read_bytes())
    assert not list(place.glob("*.moonar-*"))
    print(f"PASS {label}: Unicode, exclusive publication, replacement, failures, concurrent writes and cleanup")
    return place


def verify_containment(label, command, root, place):
    base = place / "base"
    outside = place / "base-other"
    base.mkdir()
    outside.mkdir()
    (base / "member.bin").write_bytes(b"inside")
    (outside / "member.bin").write_bytes(b"outside")
    directory_alias(base / "link", outside)
    thin_fixture(base / "escape.a", b"link/member.bin", 7)
    thin_fixture(base / "normal.a", b"member.bin", 6)
    run(command, ["check", base / "escape.a", "--external"], root, expected=1)
    run(command, ["check", base / "escape.a", "--external", "--allow-parent-paths"], root)
    run(command, ["diff", base / "escape.a", base / "escape.a", "--logical"], root, expected=2)
    run(command, ["diff", base / "escape.a", base / "escape.a", "--logical", "--allow-parent-paths"], root)
    bad = base / "escape-result.a"
    run(command, ["convert", base / "escape.a", bad, "--index", "none"], root, expected=2)
    assert not bad.exists()
    run(command, [
        "convert", base / "escape.a", bad, "--index", "none", "--allow-parent-paths",
    ], root)
    assert b"outside" in bad.read_bytes()
    good = base / "normal-result.a"
    run(command, ["convert", base / "normal.a", good, "--index", "none"], root)
    assert b"inside" in good.read_bytes()
    canonical = base / "canonical.a"
    run(command, [
        "create", canonical, base / "link/member.bin",
        "--thin", "--index", "none", "--allow-parent-paths",
    ], root)
    assert ordinary_names(command, root, canonical) == [b"../base-other/member.bin"]
    print(f"PASS {label}: directory alias containment, explicit parent opt-in and canonical references")


def verify_alias_protection(label, command, root, place):
    alias = root / (label + "-alias")
    directory_alias(alias, place)
    data = place / "member.bin"
    data.write_bytes(b"preserve external contents")
    archive = place / "casearchive.a"
    run(command, ["create", archive, data, "--index", "none"], root)
    original = archive.read_bytes()
    run(command, [
        "extract", archive, 0, alias / archive.name, "--force",
    ], root, expected=2)
    assert archive.read_bytes() == original
    self_archive = place / "self.a"
    self_archive.write_bytes(b"preserve original output")
    run(command, [
        "create", self_archive, alias / self_archive.name,
        "--thin", "--index", "none", "--force",
    ], root, expected=2)
    assert self_archive.read_bytes() == b"preserve original output"
    thin = place / "references.a"
    run(command, ["create", thin, data, "--thin", "--index", "none"], root)
    thin_original = thin.read_bytes()
    for output in (data, alias / data.name):
        run(command, [
            "move", thin, 0, 0, "--output", output,
            "--index", "none", "--force",
        ], root, expected=2)
        assert data.read_bytes() == b"preserve external contents"
        assert thin.read_bytes() == thin_original
    upper_archive = archive.with_name(archive.name.upper())
    if upper_archive.exists() and upper_archive.samefile(archive):
        run(command, [
            "extract", archive, 0, upper_archive, "--force",
        ], root, expected=2)
        assert archive.read_bytes() == original
        run(command, [
            "create", self_archive, self_archive.with_name(self_archive.name.upper()),
            "--thin", "--index", "none", "--force",
        ], root, expected=2)
        assert self_archive.read_bytes() == b"preserve original output"
        run(command, [
            "move", thin, 0, 0, "--output", data.with_name(data.name.upper()),
            "--index", "none", "--force",
        ], root, expected=2)
        assert data.read_bytes() == b"preserve external contents"
        assert thin.read_bytes() == thin_original
        print(f"PASS {label}: case-insensitive extraction, self-reference and external-member output protection")
    assert not list(place.glob("*.moonar-*"))
    print(f"PASS {label}: canonical aliases cannot overwrite the source archive or a thin member")



def verify_external_queries(label, command, root, place):
    left, right = place / "query-left", place / "query-right"
    left.mkdir()
    right.mkdir()
    payload = bytes(range(256)) * 20
    for directory in (left, right):
        (directory / "member.bin").write_bytes(payload)
        run(command, ["create", directory / "lib.a", directory / "member.bin", "--thin"], root)
    before, after = left / "lib.a", right / "lib.a"
    originals = (before.read_bytes(), after.read_bytes())
    assert originals[0] == originals[1]
    checked = json.loads(run(command, ["check", before, "--external", "--json"], root).stdout)
    assert checked["external_checked"] is True
    assert checked["external_byte_length"] == len(payload)
    packed = place / "query-packed.a"
    run(command, ["convert", before, packed], root)
    for a, b in [(before, after), (before, packed), (packed, before)]:
        delta = json.loads(run(command, ["diff", a, b, "--logical", "--json"], root).stdout)
        assert delta["content_equal"] and delta["symbols_equal"]
        assert not delta["symbol_index_presence_changed"]
    (right / "member.bin").write_bytes(payload[::-1])
    changed = json.loads(run(command, ["diff", before, after, "--logical", "--json"], root, expected=1).stdout)
    assert changed["bytes_equal"] is True and changed["content_equal"] is False
    target = next(item["index"] for item in checked["members"] if item["kind"] == "regular")
    assert changed["changes"][0]["payload_changed"] is True
    assert changed["changes"][0]["before_index"] == target
    assert changed["changes"][0]["after_index"] == target
    text = run(command, ["diff", before, after, "--logical"], root, expected=1).stdout
    assert b"container bytes are identical" in text and b"payload=true" in text
    (right / "member.bin").write_bytes(b"wrong size")
    run(command, ["check", after], root)
    mismatch = json.loads(run(command, ["check", after, "--external", "--json"], root, expected=1).stdout)
    assert mismatch["input"] == str(after) and mismatch["error"]["code"] == "AR014"
    (right / "member.bin").unlink()
    missing = json.loads(run(command, ["diff", before, after, "--logical", "--json"], root, expected=2).stdout)
    assert missing["input"] == str(after) and missing["error"]["code"] == "AR013"
    repeated = left / "repeated.a"
    run(command, ["create", repeated, left / "member.bin", left / "member.bin", "--thin", "--index", "none"], root)
    budget = json.loads(run(command, [
        "check", repeated, "--external", "--max-bytes", len(payload) + 1000, "--json",
    ], root, expected=1).stdout)
    assert budget["error"]["code"] == "AR008"
    assert (before.read_bytes(), after.read_bytes()) == originals
    print(f"PASS {label}: thin external validation, mixed-storage comparison, unchanged-container content changes and failure diagnostics")

def verify_nested_dependencies(label, command, root, place):
    directory = place / "nested-dependencies"
    directory.mkdir()
    leaf, inner, outer = directory / "leaf.bin", directory / "inner.a", directory / "outer.a"
    payload = bytes(range(256))
    leaf.write_bytes(payload)
    run(command, ["create", inner, leaf, "--thin", "--index", "none"], root)
    document = json.loads(run(command, ["inspect", inner, "--json"], root).stdout)
    offset = next(item["header_offset"] for item in document["members"] if item["kind"] == "regular")
    def header(name, size):
        return (name.ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6)
                + "644".ljust(8) + str(size).ljust(10) + "`\n").encode("ascii")
    names = b"inner.a/\n"
    outer.write_bytes(b"!<thin>\n" + header("//", len(names)) + names + b"\n" * (len(names) % 2)
                      + header("/0:" + str(offset), len(payload)))
    original = outer.read_bytes()
    checked = json.loads(run(command, ["check", outer, "--external", "--json"], root).stdout)
    assert checked["external_byte_length"] == len(payload)
    copy = directory / "copy.bin"
    run(command, ["extract", outer, 0, copy], root)
    assert copy.read_bytes() == payload
    packed = directory / "packed.a"
    run(command, ["convert", outer, packed, "--index", "none"], root)
    run(command, ["diff", outer, packed, "--logical"], root)
    for args in (["extract", outer, 0, leaf, "--force"],
                 ["convert", outer, leaf, "--force"],
                 ["delete", outer, 0, "--index", "none", "--output", leaf, "--force"]):
        reply = json.loads(run(command, [*args, "--json"], root, expected=2).stdout)
        assert reply["error"]["code"] == "IO003", reply
        assert leaf.read_bytes() == payload and outer.read_bytes() == original
    for option in ("--max-depth", "--max-archive-bytes"):
        reply = json.loads(run(command, ["check", outer, "--external", option, 0, "--json"], root, expected=1).stdout)
        assert reply["error"]["code"] == "AR008", reply
    inner.unlink()
    run(command, ["delete", outer, 0, "--index", "none"], root)
    assert outer.read_bytes() == b"!<thin>\n"
    print(f"PASS {label}: nested thin chains, logical names, transitive output protection, limits and broken-reference removal")


def verify_path_spellings(label, command, root, place):
    if os.name == "nt":
        directory = place / "drive-relative"
        directory.mkdir()
        (directory / "member.bin").write_bytes(b"drive relative payload")
        drive = directory.drive
        source, archive = drive + "member.bin", drive + "library.a"
        reply = json.loads(run(command, ["create", archive, source, "--json"], directory).stdout)
        assert reply["output"] == archive
        assert ordinary_names(command, directory, archive) == [b"member.bin"]
        thin = drive + "thin.a"
        run(command, ["create", thin, source, "--thin", "--index", "none"], directory)
        run(command, ["check", thin, "--external"], directory)
        run(command, ["convert", thin, drive + "packed.a", "--index", "none"], directory)
        run(command, ["diff", thin, drive + "packed.a", "--logical"], directory)
        run(command, ["check", "drive-relative\\thin.a", "--external"], place)
        run(command, ["rename", archive, 0, "literal\\member"], directory)
        assert ordinary_names(command, directory, archive) == [b"literal\\member"]
        run(command, ["extract", archive, 0, drive + "copy.bin"], directory)
        assert (directory / "copy.bin").read_bytes() == (directory / "member.bin").read_bytes()
        print(f"PASS {label}: Windows drive-relative files, backslash thin queries and literal archive names")
    else:
        directory = place / "directory\\component"
        directory.mkdir()
        source, archive = directory / "literal\\name.bin", directory / "library.a"
        payload = b"literal POSIX backslash"
        source.write_bytes(payload)
        run(command, ["create", archive, source], root)
        assert ordinary_names(command, root, archive) == [b"literal\\name.bin"]
        run(command, ["rename", archive, 0, "new\\member"], root)
        output = directory / "copy\\data.bin"
        run(command, ["extract", archive, 0, output], root)
        assert output.read_bytes() == payload
        # A backslash in the containing directory is a valid host path. The
        # portable member reference itself still follows the thin path policy.
        plain = directory / "plain.bin"
        plain.write_bytes(payload)
        thin, packed = directory / "thin.a", directory / "packed.a"
        run(command, ["create", thin, plain, "--thin", "--index", "none"], root)
        run(command, ["check", thin, "--external"], root)
        run(command, ["convert", thin, packed, "--index", "none"], root)
        run(command, ["diff", thin, packed, "--logical"], root)
        invalid = directory / "invalid.a"
        run(command, ["create", invalid, source, "--thin", "--index", "none"], root, expected=2)
        assert not invalid.exists() and source.read_bytes() == payload
        print(f"PASS {label}: POSIX literal backslashes, thin parent directories and portable-reference rejection")


def verify_long_output_names(label, command, root, place):
    # Keep Windows destinations below MAX_PATH while leaving too little room
    # for a suffix on the destination. POSIX exercises the component limit.
    length = 245 - len(str(place)) - 1 if os.name == "nt" else os.pathconf(place, "PC_NAME_MAX")
    assert length >= 80, place
    archive = place / ("a" * (length - 2) + ".a")
    output = place / ("b" * (length - 4) + ".bin")
    # Establish that the filesystem itself accepts the destination spelling.
    archive.write_bytes(b"original")
    archive.unlink()
    source = place / "long-name-input.bin"
    source.write_bytes(b"long filename payload")
    run(command, ["create", archive, source], root)
    original = archive.read_bytes()
    run(command, ["create", archive, "--json"], root, expected=2)
    assert archive.read_bytes() == original
    run(command, ["rename", archive, 0, "renamed.bin"], root)
    assert ordinary_names(command, root, archive) == [b"renamed.bin"]
    run(command, ["extract", archive, 0, output], root)
    assert output.read_bytes() == source.read_bytes()
    run(command, ["create", archive, "--force"], root)
    run(command, ["check", archive], root)
    assert not list(place.glob("*.moonar-*"))
    print(f"PASS {label}: long output names, atomic replacement, no-clobber failure and temporary cleanup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True)
    parser.add_argument("--node-entry")
    parser.add_argument("--node", default=shutil.which("node"))
    args = parser.parse_args()
    commands = [("native", [str(Path(args.moonar).resolve())])]
    if args.node_entry:
        if not args.node:
            parser.error("--node-entry requires Node.js")
        commands.append(("node", [args.node, str(Path(args.node_entry).resolve())]))
    with tempfile.TemporaryDirectory(prefix="moonar-io-") as temporary:
        root = Path(temporary).resolve()
        assert root.parent == Path(tempfile.gettempdir()).resolve()
        for label, command in commands:
            place = verify_publication(label, command, root)
            verify_containment(label, command, root, place)
            verify_alias_protection(label, command, root, place)
            verify_external_queries(label, command, root, place)
            verify_nested_dependencies(label, command, root, place)
            verify_path_spellings(label, command, root, place)
            verify_long_output_names(label, command, root, place)


if __name__ == "__main__":
    main()
