# MoonAr

MoonAr reads and compares Unix ar archives in MoonBit. It is intended for build
tools that need to inspect static libraries without spawning an archiver.

Development is in progress. The first working stage reads ordinary short-name
members, retains order and duplicate names, and reports malformed headers and
truncated data. GNU/BSD long names, comparison reports and the CLI are planned.

The scope is the archive container. MoonAr does not interpret object code, check
ABI compatibility, link programs, or decide whether an archive is safe to execute.
Thin archives and archive writing are outside the initial release.

## Development

The current local toolchain is moon 0.1.20260915 / moonc v0.10.14.

```sh
moon check --target wasm-gc
moon test --target wasm-gc
moon info
moon fmt
```

The library accepts bytes and has no filesystem dependency. Input defaults to a
64 MiB limit and 100,000 records; callers may choose smaller or larger limits.

## Sources and license

MIT. This is an independent implementation, not a fork of another project.
Format and behavioral references:

- [GNU ar manual](https://sourceware.org/binutils/docs/binutils/ar.html)
- [LLVM ar manual](https://llvm.org/docs/CommandGuide/llvm-ar.html)
- [Debian package container](https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html)

AI assisted research, code, tests and documentation. Tool runs and development
commits record the work actually completed. The project has not yet been submitted
or accepted by the hackathon.
