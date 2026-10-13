"""Generate or verify small, self-authored examples; optionally exercise the CLI.

The .a examples contain data, not object code. GNU/LLVM object archives are tested
separately by verify_archives.py. This fixture writer is not a library feature.
"""

import argparse
import gzip
import io
import json
from pathlib import Path
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "examples" / "data"


def archive(entries, timestamp=0):
    out = bytearray(b"!<arch>\n")
    for name, payload in entries:
        assert len(name) <= 15 and name.isascii()
        header = f"{name + '/':<16}{timestamp:<12}{0:<6}{0:<6}{'644':<8}{len(payload):<10}`\n"
        assert len(header) == 60
        out.extend(header.encode("ascii"))
        out.extend(payload)
        if len(payload) % 2:
            out.extend(b"\n")
    return bytes(out)


def compressed_tar(name, payload):
    uncompressed = io.BytesIO()
    with tarfile.open(fileobj=uncompressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        entry = tarfile.TarInfo(name)
        entry.size = len(payload)
        entry.mode = 0o644
        entry.mtime = 0
        tar.addfile(entry, io.BytesIO(payload))
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as stream:
        stream.write(uncompressed.getvalue())
    return compressed.getvalue()


def fixtures():
    original = [("config.txt", b"color=blue\n"), ("assets.bin", b"\x00\x01\xff")]
    control = (
        b"Package: moonar-demo\nVersion: 1.0\nArchitecture: all\n"
        b"Maintainer: MoonAr contributors <noreply@example.invalid>\n"
        b"Description: Small archive-reading example\n"
    )
    return {
        "bundle-before.a": archive(original),
        "bundle-time.a": archive(original, timestamp=1700000000),
        "bundle-content.a": archive([("config.txt", b"color=green\n"), original[1]]),
        "bundle-broken.a": archive(original)[:-2],
        "demo.deb": archive([
            ("debian-binary", b"2.0\n"),
            ("control.tar.gz", compressed_tar("./control", control)),
            ("data.tar.gz", compressed_tar("./usr/share/moonar-demo/message.txt", b"Hello from MoonAr.\n")),
        ]),
    }


def cli(exe, command, names, expected):
    result = subprocess.run(
        [str(exe), command, "--json", *[str(DATA / name) for name in names]],
        capture_output=True,
    )
    assert result.returncode == expected, result.stderr.decode(errors="replace")
    return json.loads(result.stdout)


def verify_cli(exe):
    document = cli(exe, "inspect", ["bundle-before.a"], 0)
    assert [e["name_display"] for e in document["members"]] == ["config.txt", "assets.bin"]
    assert [e["size"] for e in document["members"]] == [11, 3]
    error = cli(exe, "check", ["bundle-broken.a"], 1)["error"]
    assert error["code"] == "AR002" and error["offset"] == 140
    print("1. Inspect bundle and reject truncated payload at byte 140: PASS")
    metadata = cli(exe, "diff", ["bundle-before.a", "bundle-time.a"], 1)
    assert len(metadata["changes"]) == 2
    assert all(c["metadata_changed"] and not c["payload_changed"] for c in metadata["changes"])
    content = cli(exe, "diff", ["bundle-before.a", "bundle-content.a"], 1)
    assert len(content["changes"]) == 1
    assert content["changes"][0]["name_display"] == "config.txt"
    assert content["changes"][0]["payload_changed"] and not content["changes"][0]["metadata_changed"]
    print("2. Distinguish timestamps from changed config content: PASS")
    deb = cli(exe, "inspect", ["demo.deb"], 0)
    assert [e["name_display"] for e in deb["members"]] == ["debian-binary", "control.tar.gz", "data.tar.gz"]
    data = (DATA / "demo.deb").read_bytes()
    for entry in deb["members"][1:]:
        part = data[entry["data_offset"]:entry["data_offset"] + entry["size"]]
        with tarfile.open(fileobj=io.BytesIO(part), mode="r:gz") as tar:
            assert len(tar.getmembers()) == 1
    print("3. Locate Debian container members and read their payloads: PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true", help="replace the five known example files")
    parser.add_argument("--moonar", type=Path, help="also run all three CLI scenarios")
    args = parser.parse_args()
    if args.generate:
        DATA.mkdir(parents=True, exist_ok=True)
    for name, data in fixtures().items():
        path = DATA / name
        if args.generate:
            path.write_bytes(data)
        else:
            assert path.read_bytes() == data, f"Example differs from generator: {path}"
    print("Example fixtures verified" if not args.generate else "Example fixtures generated")
    if args.moonar:
        verify_cli(args.moonar.resolve(strict=True))


if __name__ == "__main__":
    main()
