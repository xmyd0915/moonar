"""Build upstream zlib and link real consumers through MoonAr-created archives.

Requires Python 3.9+, a built MoonAr CLI and GCC (Linux or Windows/MinGW).
The official source archive is pinned by SHA-256. No source patches, system
zlib, reference archiver, or manually supplied symbol mappings are used.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


VERSION = "1.3.1"
URL = f"https://zlib.net/fossils/zlib-{VERSION}.tar.gz"
SHA256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
SOURCE_FILES = [
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "infback.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
]

CONSUMER = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zlib.h"

int main(void) {
    const size_t length = 131072;
    unsigned char *original = (unsigned char *)malloc(length);
    unsigned char *restored = (unsigned char *)malloc(length);
    uLongf capacity = compressBound((uLong)length);
    unsigned char *compressed = (unsigned char *)malloc(capacity);
    if (!original || !restored || !compressed) return 10;
    unsigned state = 0x12345678u;
    for (size_t i = 0; i < length; ++i) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        original[i] = i % 3 == 0 ? (unsigned char)state : (unsigned char)(i % 251);
    }
    if (strcmp(zlibVersion(), ZLIB_VERSION) != 0) return 11;
    for (int level = Z_BEST_SPEED; level <= Z_BEST_COMPRESSION; level += 8) {
        uLongf packed_length = capacity;
        int status = compress2(compressed, &packed_length, original, (uLong)length, level);
        if (status != Z_OK) return 12;
        uLongf restored_length = (uLongf)length;
        status = uncompress(restored, &restored_length, compressed, packed_length);
        if (status != Z_OK || restored_length != length ||
            memcmp(original, restored, length) != 0) return 13;
        if (crc32(0, original, (uInt)length) != crc32(0, restored, (uInt)length)) return 14;
        printf("zlib %s level %d: %lu -> %lu -> %lu bytes, exact roundtrip\n",
               zlibVersion(), level, (unsigned long)length,
               (unsigned long)packed_length, (unsigned long)restored_length);
    }
    free(original);
    free(restored);
    free(compressed);
    return 0;
}
"""


def run(arguments, cwd, environment):
    result = subprocess.run(
        [str(argument) for argument in arguments],
        cwd=cwd,
        env=environment,
        capture_output=True,
        check=False,
        timeout=180,
    )
    if result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {arguments!r}\n"
            + result.stdout.decode("utf-8", errors="replace")
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout


def download(destination):
    with urllib.request.urlopen(URL, timeout=60) as response, destination.open("xb") as output:
        total = 0
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            total += len(block)
            if total > 16 * 1024 * 1024:
                raise RuntimeError("zlib source download exceeds the expected size limit")
            output.write(block)


def unpack(archive, destination):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SHA256:
        raise RuntimeError(f"zlib {VERSION} source checksum mismatch: {digest}")
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        total = 0
        if len(members) > 4096:
            raise RuntimeError("too many source archive entries")
        # Validate the entire archive before creating any extracted file.
        for member in members:
            path = PurePosixPath(member.name)
            if (
                path.is_absolute()
                or ".." in path.parts
                or "\\" in member.name
                or ":" in member.name
                or not path.parts
                or path.parts[0] != f"zlib-{VERSION}"
                or not (member.isfile() or member.isdir())
            ):
                raise RuntimeError(f"unexpected source archive entry: {member.name!r}")
            total += member.size
            if member.size < 0 or total > 64 * 1024 * 1024:
                raise RuntimeError("expanded source archive exceeds its size limit")
        for member in members:
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("source archive path escapes the extraction directory")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = source.extractfile(member)
                if stream is None:
                    raise RuntimeError(f"cannot read source archive entry: {member.name!r}")
                with stream, target.open("xb") as output:
                    shutil.copyfileobj(stream, output)
    print(f"PASS upstream zlib {VERSION} SHA-256: {SHA256}", flush=True)


def inventory(executable, archive, working, environment, thin):
    report = json.loads(run([executable, "inspect", archive, "--json"], working, environment))
    ordinary = [entry for entry in report["members"] if entry["kind"] == "regular"]
    if len(ordinary) != len(SOURCE_FILES):
        raise RuntimeError(f"{archive}: wrong ordinary member count")
    indexes = report["symbol_indexes"]
    if len(indexes) != 1 or indexes[0]["format"] != "gnu32":
        raise RuntimeError(f"{archive}: expected an automatically generated GNU32 index")
    symbols = {bytes.fromhex(entry["name_hex"]) for entry in indexes[0]["symbols"]}
    # i686 MinGW uses leading underscores; x86-64 and ELF use undecorated names.
    if not all(name in symbols or b"_" + name in symbols for name in (b"compress2", b"uncompress", b"deflate", b"inflate")):
        raise RuntimeError(f"{archive}: public zlib definitions are missing from the index")
    expected_magic = b"!<thin>\n" if thin else b"!<arch>\n"
    if (working / archive).read_bytes()[:8] != expected_magic:
        raise RuntimeError(f"{archive}: unexpected archive encoding")
    return ordinary


def link_and_run(cc, archive, label, working, environment):
    output = working / (label + (".exe" if os.name == "nt" else ""))
    run([cc, "consumer.o", archive, "-o", output], working, environment)
    result = run([output], working, environment).decode("ascii")
    if result.count("exact roundtrip") != 2:
        raise RuntimeError(f"{label}: consumer did not complete both compression levels")
    print(f"PASS {label}: {result.strip()}", flush=True)


def verify(executable, cc, archive, working, environment):
    unpack(archive, working)
    source = working / f"zlib-{VERSION}"
    objects = working / "objects"
    objects.mkdir()
    names = []
    for filename in SOURCE_FILES:
        target = "objects/" + Path(filename).with_suffix(".o").name
        run([cc, "-O2", "-I", source, "-c", source / filename, "-o", target], working, environment)
        names.append(target)
    (working / "consumer.c").write_text(CONSUMER, encoding="ascii")
    run([cc, "-O2", "-I", source, "-c", "consumer.c", "-o", "consumer.o"], working, environment)
    print(f"PASS compiled {len(SOURCE_FILES)} unchanged upstream zlib sources", flush=True)

    for thin, archive_name in [(False, "zlib-regular.a"), (True, "zlib-thin.a")]:
        command = [executable, "create", archive_name, *names]
        if thin:
            command.append("--thin")
        # No --index or explicit mappings: this exercises the production default.
        run(command, working, environment)
        inventory(executable, archive_name, working, environment, thin)
        link_and_run(cc, archive_name, "thin-before-edit" if thin else "regular-before-edit", working, environment)

    recompiled = objects / "recompiled"
    recompiled.mkdir()
    replacement = "objects/recompiled/deflate.o"
    run([cc, "-O0", "-I", source, "-c", source / "deflate.c", "-o", replacement], working, environment)
    replacement_bytes = (working / replacement).read_bytes()
    if replacement_bytes == (objects / "deflate.o").read_bytes():
        raise RuntimeError("the replacement object must differ from its original build")
    position = SOURCE_FILES.index("deflate.c")
    for thin, archive_name in [(False, "zlib-regular.a"), (True, "zlib-thin.a")]:
        before = (working / archive_name).read_bytes()
        run([executable, "replace", archive_name, position, replacement], working, environment)
        if (working / archive_name).read_bytes() == before:
            raise RuntimeError(f"{archive_name}: replacement did not change the archive")
        inventory(executable, archive_name, working, environment, thin)
        extracted = "thin-replacement.o" if thin else "regular-replacement.o"
        run([executable, "extract", archive_name, position, extracted], working, environment)
        if (working / extracted).read_bytes() != replacement_bytes:
            raise RuntimeError(f"{archive_name}: replacement payload does not match its source object")
        link_and_run(cc, archive_name, "thin-after-edit" if thin else "regular-after-edit", working, environment)

    run([executable, "convert", "zlib-thin.a", "zlib-materialized.a"], working, environment)
    inventory(executable, "zlib-materialized.a", working, environment, thin=False)
    link_and_run(cc, "zlib-materialized.a", "materialized-after-edit", working, environment)
    print("PASS zlib integration: regular/thin creation, automatic indexes, replacement, extraction and materialization", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True, type=Path, help="built MoonAr CLI")
    parser.add_argument("--cc", default=shutil.which("cc") or shutil.which("gcc"), help="GCC executable")
    parser.add_argument("--source-archive", type=Path, help="optional local zlib-1.3.1.tar.gz; checksum remains mandatory")
    args = parser.parse_args()
    if not args.cc:
        parser.error("GCC is required; specify --cc if it is not on PATH")
    executable = args.moonar.resolve(strict=True)
    compiler = shutil.which(str(args.cc))
    if compiler is None:
        parser.error(f"C compiler was not found: {args.cc}")
    cc = Path(compiler).resolve(strict=True)
    environment = dict(os.environ)
    environment["PATH"] = str(cc.parent) + os.pathsep + environment.get("PATH", "")
    source_archive = args.source_archive.resolve(strict=True) if args.source_archive else None
    temporary_root = Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix="moonar-zlib-", dir=temporary_root) as temporary:
        working = Path(temporary).resolve()
        if working.parent != temporary_root:
            raise RuntimeError("unexpected temporary workspace location")
        archive = source_archive or working / f"zlib-{VERSION}.tar.gz"
        if source_archive is None:
            download(archive)
        print(run([cc, "--version"], working, environment).decode(errors="replace").splitlines()[0], flush=True)
        try:
            verify(executable, cc, archive, working, environment)
        finally:
            # Only this freshly created workspace is recursively removed.
            if working.resolve().parent != temporary_root:
                raise RuntimeError("temporary workspace moved outside its cleanup boundary")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, tarfile.TarError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
