# Changes

## Main branch — 2026-10-20

- Add a separate GNU thin archive API with GNU32/64 symbol references,
  caller-controlled member loading, relative-path policy and byte limits.
- Create deterministic GNU/BSD archives and edit individual duplicate members
  through immutable append, replace, remove and move operations.
- Require an explicit decision when importing indexed archives for editing;
  write fresh GNU32 indexes from caller-provided final member mappings.
- Add a public workflow example and GNU/LLVM creation, editing, thin
  materialization and real-object linking checks.
- Define the general Unix ar library scope, delivery stages and acceptance
  criteria, including thin creation, file operations and automatic indexes.

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
