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


if __name__ == "__main__":
    main()
