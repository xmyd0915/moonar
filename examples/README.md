# Three reproducible scenarios

Run these commands from the repository root after installing MoonBit. The files
in `data/` are small examples authored for this project under its MIT license.
They contain no downloaded software. The `.a` files contain text and binary data,
not object code. Real C object files and symbol indexes are covered separately by
`tools/verify_archives.py` using GNU ar and LLVM ar.

## 1. Inspect an artifact and locate a damaged member

For a build or packaging script that receives an ar file:

```sh
moon run cmd/main --target native -- inspect examples/data/bundle-before.a --json
moon run cmd/main --target native -- check examples/data/bundle-broken.a
```

The first command reports `config.txt` (11 bytes) and `assets.bin` (3 bytes).
The second exits with status 1 and `AR002 at byte 140: truncated member payload`.
The same commands accept ordinary static libraries such as `libexample.a`.

## 2. Explain why two build artifacts differ

```sh
moon run cmd/main --target native -- diff examples/data/bundle-before.a examples/data/bundle-time.a
moon run cmd/main --target native -- diff examples/data/bundle-before.a examples/data/bundle-content.a --json
```

Both commands exit with status 1 because the archive bytes differ. In the first,
both members have changed metadata but identical payloads. In the second,
`config.txt` has changed payload bytes and unchanged metadata. This helps decide
whether to investigate timestamps or the inputs to the build. It does not prove
link equivalence or ABI compatibility.

## 3. Read the outer container of a Debian package

```sh
moon run cmd/main --target native -- inspect examples/data/demo.deb
moon run examples/read_deb --target native
```

The container has `debian-binary`, `control.tar.gz` and `data.tar.gz` records. The
MoonBit consumer calls `parse`, `get_member` and `member_bytes`, then verifies the
`2.0` version marker. This is an example of handing member bytes to another
library. MoonAr itself does not decompress tar streams, validate Debian package
policy or install anything.

The bundled package contains only a control file and a greeting text file. On
Linux, `dpkg-deb --info examples/data/demo.deb` can inspect it without installing
it. No privileges are needed.

## Verify all scenarios

```sh
moon build --target native
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
```

Python 3.9+ is needed only for this verification script. It checks expected exit
codes, JSON values, fixture reproducibility, and reads the two tar payloads using
Python's standard library. It makes no network requests. To regenerate the five
fixtures from their source descriptions, run `python tools/examples.py --generate`.
