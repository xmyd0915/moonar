"""Verify the published MoonCakes package against the current source package.

Run after publishing the version in moon.mod. A temporary consumer installs that
exact version with moon update, exercises the public API on all four backends,
and compares every installed package file with a fresh moon package ZIP.
Requires Python 3.9+, MoonBit, a native C compiler and registry access.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import zipfile

from verify_package import CONSUMER, bitcode_fixture, elf_fixture, run


def metadata_field(metadata, field):
    match = re.search(r'^' + re.escape(field) + r'\s*=\s*"([^"]+)"', metadata, re.M)
    if match is None:
        raise AssertionError(f"moon.mod is missing {field}")
    return match.group(1)


def match_package(archive, provider):
    count = 0
    names = set()
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            if entry.is_dir():
                continue
            name = PurePosixPath(entry.filename.replace("\\", "/"))
            if name.is_absolute() or ".." in name.parts or ":" in entry.filename:
                raise AssertionError(f"invalid package path: {entry.filename}")
            if name in names:
                raise AssertionError(f"duplicate package path: {entry.filename}")
            names.add(name)
            target = provider.joinpath(*name.parts)
            if not target.resolve().is_relative_to(provider.resolve()):
                raise AssertionError(f"installed path escapes package: {entry.filename}")
            if not target.is_file() or target.read_bytes() != package.read(entry):
                raise AssertionError(f"installed package differs from source ZIP: {entry.filename}")
            count += 1
    if not count:
        raise AssertionError("source package is empty")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", default=shutil.which("moon"), help="MoonBit moon executable")
    parser.add_argument("--archive", type=Path, help="existing release ZIP (default: run moon package)")
    parser.add_argument(
        "--report", type=Path,
        help="report path (default: _build/verification/registry-consumer-VERSION.json)",
    )
    args = parser.parse_args()
    moon = shutil.which(args.moon) if args.moon else None
    if not moon:
        parser.error("MoonBit's moon executable is required")
    moon = str(Path(moon).resolve())
    root = Path(__file__).resolve().parent.parent
    metadata = (root / "moon.mod").read_text(encoding="utf-8")
    module = metadata_field(metadata, "name")
    version = metadata_field(metadata, "version")
    if args.archive is None:
        run([moon, "package"], root)
        archive = root / "_build/publish" / (module.replace("/", "-") + "-" + version + ".zip")
    else:
        archive = args.archive.resolve(strict=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()

    # Keep the consumer outside the source checkout so local workspace lookup
    # cannot redirect its dependency to the development copy.
    with tempfile.TemporaryDirectory(prefix="moonar-registry-consumer-") as temporary:
        consumer = Path(temporary).resolve()
        for directory in (consumer, *consumer.parents):
            if (directory / "moon.work").exists():
                raise AssertionError(f"registry consumer must not inherit moon.work: {directory}")
        (consumer / "moon.mod").write_text(
            'name = "verification/moonar-registry"\nversion = "0.1.0"\n'
            f'import {{ "{module}@{version}", }}\n', encoding="utf-8",
        )
        (consumer / "moon.pkg").write_text(
            f'import {{ "{module}" @ar, "{module}/cli" @cli, }} for "test"\n',
            encoding="utf-8",
        )
        fixture = 'b"' + "".join(f"\\x{byte:02x}" for byte in elf_fixture()) + '"'
        bitcode = 'b"' + "".join(f"\\x{byte:02x}" for byte in bitcode_fixture()) + '"'
        (consumer / "consumer_test.mbt").write_text(
            CONSUMER.replace("__OBJECT__", fixture).replace("__BITCODE__", bitcode).lstrip(),
            encoding="utf-8",
        )
        print(run([moon, "update"], consumer).strip())
        # update refreshes the registry index; the build resolves and downloads
        # dependencies. Do not inspect .mooncakes before that has happened.
        print(run([
            moon, "test", "--target", "all", "--deny-warn",
            "--package", "verification/moonar-registry",
        ], consumer).strip())
        provider = consumer / ".mooncakes" / module
        installed = (provider / "moon.mod").read_text(encoding="utf-8")
        if metadata_field(installed, "name") != module or metadata_field(installed, "version") != version:
            raise AssertionError("registry installed a different module or version")
        matching_files = match_package(archive, provider)

    record = {
        "module": module, "version": version,
        "archive": str(archive), "archive_sha256": digest,
        "registry_install": True, "local_workspace_override": False,
        "consumer_tests_per_target": len(re.findall(r'^test "', CONSUMER, re.M)),
        "targets": ["wasm", "wasm-gc", "js", "native"],
        "matching_package_files": matching_files, "passed": True,
    }
    report = args.report or Path("_build/verification") / f"registry-consumer-{version}.json"
    if not report.is_absolute():
        report = root / report
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"PASS MoonCakes public API consumer: {module}@{version}, "
          f"{matching_files} files match source ZIP, SHA-256 {digest}")


if __name__ == "__main__":
    main()
