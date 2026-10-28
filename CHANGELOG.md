# Changes

## 0.7.0 — 2026-10-28

- Run native macOS Apple Silicon consumers with Apple Clang, libtool, ar and nm:
  four BSD/Darwin layouts, complete archive edits, thin materialization and 16
  linked program executions with checked results.
- Resolve Node filesystem paths through the native OS realpath implementation,
  preserving overwrite protection for case aliases on macOS. Keep distinct
  destinations usable on case-sensitive filesystems. Node CLI requires 20.16+
  or 22.3+ for the built-in module accessor.
- Add 36 checked release-native benchmarks covering up to 10000 members,
  duplicate-name comparison and shared thin containers through depth 16.
- Record raw timing samples, median/range, process peak resident memory,
  toolchain and executable identity. Calibrate memory units in a separate probe.
- Run the complete test and benchmark matrix on Linux, Windows and macOS;
  retain machine-readable reports with CI artifacts and release assets.

Public library signatures and supported archive formats are unchanged.

## 0.6.3 — 2026-10-23

- Run the independent registry consumer before inspecting downloaded files:
  `moon update` refreshes metadata, while the build resolves dependencies.
- Allow `verify_registry.py --archive PATH` to compare an installed release
  against an existing ZIP without rebuilding it from a changed checkout.

Archive and CLI behavior are unchanged from 0.6.2. The registry workflow is
checked by installing a published package and comparing all 99 distributed files.

## 0.6.2 — 2026-10-23

- Validate directly constructed public CLI requests before any filesystem
  callback. Reject missing arguments, invalid selectors, unknown operations,
  unsupported option combinations and invalid budgets with `CLI001` and exit 2.
- Share request validation between argument parsing and execution, preventing
  malformed API calls from panicking or unexpectedly rewriting an archive.
- Create short, independent sibling temporary names so valid long destination
  names remain usable for atomic creation, editing, extraction and replacement.
- Reject impossible BSD byte-order envelopes before applying symbol budgets,
  so an invalid alternate interpretation cannot mask a valid bounded index.
- Add public package regressions and a reproducible MoonCakes installation
  consumer that checks all installed package files against the local release ZIP.

Public method signatures and supported archive formats are unchanged.

## 0.6.1 — 2026-10-21

- Preserve POSIX filenames containing literal backslashes instead of treating
  them as Windows directory separators during creation, extraction or thin I/O.
- Retain Windows drive roots and POSIX roots when locating archive directories;
  avoid creating a UNC path when joining a current-drive root and a member name.
- Normalize Windows filesystem arguments using the host's canonical path syntax,
  retain drive-relative semantics, and preserve literal archive rename values.
- Keep reported output paths in their original argument spelling and avoid
  filesystem access for help/version commands.
- Add native/Node path regressions, packaged public CLI consumers, command-version
  consistency checks, and distribution license/documentation checks.

Public method signatures and portable thin-member path rules are unchanged.

## 0.6.0 — 2026-10-21

- Discover archive symbols from LLVM bitcode carrying an embedded version-3
  IR symbol table, including raw streams, wrappers and multiple module groups.
- Validate summary ranges, strings, comdat references, module partitions,
  uncommon records, VBR fields and block envelopes before publishing indexes.
- Include defined external, weak, common and alias names using compiler-provided
  mangling; filter local, undefined and format-specific records.
- Reuse shared discovery budgets for bitcode alongside ELF, Mach-O and COFF;
  bound summary abbreviations and avoid expanding zero-width arrays.
- Reject GCC slim LTO markers instead of emitting misleading archive indexes;
  retain native definitions in fat objects and explicit mapping support.
- Add compiler-produced full/ThinLTO consumers with LLVM reference maps,
  complete edits, thin materialization, mixed native objects and actual links.

The public method signatures remain unchanged. Bitcode without the supported
embedded summary returns `OB002`; automatic archive discovery reports `WR006`.

## 0.5.0 — 2026-10-21

- Read and write Microsoft COFF libraries with cross-checked dual linker members,
  canonical sorted symbol maps, NUL long names and unknown timestamp handling.
- Discover symbols from bigobj and short import objects; verify rebuilt static
  and DLL import libraries with MSVC linkers and executed consumers.
- Resolve, write and edit GNU nested archive-offset thin references, including
  shared-container caches, manifests, exact target validation and cycle detection.
- Expand regular/thin archive inputs during thin creation and addition; resolve
  logical member names for extraction, materialization and snapshot comparison.
- Add aggregate nested-container budgets and bounded depth, protect transitive
  dependencies from output aliasing and retain in-place broken-reference removal.
- Fix lexical name ordering in BSD SORTED indexes; batch additions and deletions
  without repeatedly copying the whole editing plan.

### API notes

`WriteFormat` adds `Coff`. `ThinMember` and `ThinWriteMember` add optional
`archive_member_offset`; constructor callers keep their existing defaults.
Thin loading methods accept optional `nested_limits`. New `resolve_member` returns
the resolved name, bytes and outer metadata; `member_sources` enumerates dependency
paths without reading direct payloads. Container loader requests carry the remaining
archive-byte budget; direct requests retain their exact declared payload size.
`cli.Request` adds `max_archive_bytes` and `max_depth`. Thin JSON adds
`archive_member_offset` (number or null); COFF indexes use `format: "coff"`.

## 0.4.0 — 2026-10-21

- Add immutable comparison snapshots for ordinary and thin archives, retaining
  original physical positions and symbol mappings without a rewrite.
- Compare thin/thin and thin/regular contents directly with `diff --logical`;
  keep container byte equality separate from loaded external content equality.
- Add `ThinArchive.validate_members` and `check --external` with path preflight,
  cumulative byte budgets, declared-size checks and precise loading diagnostics.
- Apply filesystem root checks and explicit parent-path opt-in to read-only thin
  queries; preserve normal metadata-only checks without external file access.
- Extend native/Node filesystem and packaged public API consumer regressions.

### API notes

`cli.Request` adds `external` and `allow_parent_paths`; code constructing the
record directly must supply them. Existing parser and comparison entry points
remain available. Thin snapshot comparison reports original-container
`bytes_equal`, which may be true while loaded `content_equal` is false.

## 0.3.0 — 2026-10-20

- Add a separate GNU thin archive API with GNU32/64 symbol references,
  caller-controlled member loading, relative-path policy and byte limits.
- Create GNU32/64, BSD32/64 and Darwin32/64 archives with deterministic or preserved
  metadata, both BSD index byte orders, and individual duplicate-member editing.
- Require an explicit decision when importing indexed archives for editing;
  write fresh indexes from caller-provided final member mappings.
- Add a public workflow example and GNU/LLVM creation, editing, thin
  materialization and real-object linking checks.
- Discover symbols from ELF32/64, Mach-O32/64 and standard COFF objects, sharing
  symbol count/name budgets across members.
- Write and edit GNU thin archives with 32/64-bit indexes, relocate references,
  load external members and materialize ordinary archives.
- Add list, create, add/insert, replace, delete, move, rename, extract, convert
  and index commands; rebuild symbols after edits by default.
- Publish native and Node outputs atomically, enforce overwrite policy, protect
  source/dependency path aliases and check real external-member paths.
- Keep JSON list selectors consistent with text output and editor positions.
- Preserve ordinary-member identity for GNU long names matching reserved headers.
- Add full CLI/IO regression workflows and a pinned zlib consumer that builds,
  links, runs, replaces an object and links again through regular and thin output.

## 0.2.0 — 2026-10-16

- Validate GNU 32/64-bit and BSD/Darwin 32/64-bit symbol indexes, resolve targets
  to ordinary-member headers, and expose symbol names and source offsets.
- Check BSD byte order, string boundaries, padding and SORTED index ordering;
  reject ambiguous byte order and unsupported multiple-index layouts.
- Match duplicate members by exact content before occurrence order and report
  ambiguous identities. Same-name insertion no longer cascades into payload changes.
- Add `compare_logical` and `diff --logical`, separating ordinary-member content,
  metadata, order and symbol mappings from physical container encoding.
- Add symbol count/name budgets and expose all five parser budgets in the CLI.
- Extend independent GNU/LLVM tests with real object symbols, duplicate insertion,
  cross-format comparison, damaged references and generated 64-bit indexes.

### API notes

`parse` now rejects structurally invalid symbol indexes rather than exposing
them as opaque payloads. `Comparison` adds `ambiguities`; `cli.Request` adds
logical mode and the extra parser budgets. Code constructing those records must
provide the new fields. Existing JSON version 1 fields remain; new fields are
additive. Default `diff` continues to use byte equality for its exit status.

## 0.1.0

Initial ar reader, physical comparison, CLI, GNU/BSD names, JSON, examples and
GNU/LLVM archive extraction checks.
