# Development and acceptance notes

## Scope

MoonAr is a new ar container library and CLI. It reads archive records and
compares member contents, names, order and metadata. It does not parse pkg-config
files or reuse MoonPkgConfig code or Git history. MoonPatch's JSON patch proposal
is also unrelated. No local MoonGitAttrs checkout was found in the workspace.

Initial support: ordinary GNU/BSD archives, including long names and opaque symbol
tables. No writer, thin-archive file loading, object-code/ABI analysis, archive
extraction to directories, or full Debian package validation.

## Rule check: 2026-10-13

- [October site](https://moonbitlang.github.io/Hackathon2026/): October 31 is the
  registration and acceptance deadline; three submissions, editable before
  approval. Use the October form's option to participate in quarterly selection.
- [Charter](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd), marked
  October 10: section 5.1 requires at least 10 meaningful commits **at application**,
  three complete scenarios, and a human-written proposal within one Markdown page.
- Acceptance requires public source, MoonBit as the main language, reproducible
  README and example, core-path tests, CI check/build/test, MoonCakes publication,
  and an OSI license with source attribution.
- The charter still contains September headings and October 24 in its schedule.
  Plan to finish by October 23; do not rely on the extra week without clarification.
- No explicit minimum compiler version or mandatory quarterly attendance rule was
  found in the reviewed sections. These remain unconfirmed, not waived requirements.
- The organizer's reply supplied by the participant says an accepted September
  project enters quarterly selection without reapplying and the participant may
  enter October with a new project. It does not promise acceptance or a prize.

AI may assist implementation; the participant must understand the project and
write the application. This file records facts for discussion, not an application.

## Duplicate search

The October 13 MoonCakes catalog contained 2,966 package records. Metadata searches
and focused GitHub searches did not find a dedicated MoonBit ar inspection/diff
library. This is not proof of absence. The full current registration list was not
available in the public sources checked.

Related projects checked:

- [elf](https://mooncakes.io/docs/moonbit-community/elf): ELF headers, sections,
  symbols and relocation data inside object files, not an ar container interface.
- [dwarfscope](https://github.com/wuhaiting321/moonbit-dwarfscope): ELF/DWARF parsing,
  symbol lookup and crash reports. MoonAr should not duplicate these capabilities.
- [tar](https://github.com/moonbit-community/tar) and
  [zipc](https://github.com/moonbit-community/zipc): different container formats.
- [moon archiver integration](https://github.com/moonbitlang/moon/blob/main/crates/moonutil/src/compiler_flags/archiver.rs):
  Rust build-tool integration with system archivers, not a MoonBit byte parser.
- [Previous OSC results](https://moonbitlang.github.io/OSC2026/): 13 listed projects;
  this is a different event's public results, not an October registration list.

The useful distinction is an embeddable library with structured diagnostics and
comparison results. Merely reproducing `ar t` would offer limited additional value.
Quarterly competitiveness needs evidence of useful integration, not commit counts.

## Work sequence

Complete and verify each change before committing. A feature's basic tests belong
with that feature. Do not split changes or add empty commits to reach a count.

1. Ordinary record parsing, bounded reads and initial tests.
2. GNU long-name tables and references, with malformed-reference tests.
3. BSD embedded names and payload offsets, with compatibility tests.
4. Record comparison, duplicate occurrence matching and order semantics.
5. Stable JSON output preserving byte names and integer metadata.
6. File inspection/check commands and command-line error handling.
7. Archive comparison command and documented exit status behavior.
8. GNU/LLVM differential fixtures and malformed-input regression suite.
9. Runnable consumer examples and CI on declared supported platforms/backends.
10. Documentation, source/license audit and release packaging verification.

This is a plan, not a claim that ten commits have been made or are already valid.
More or fewer implementation stages may be needed; the application must not be
sent until there are ten substantive, reviewable commits.

The participant authorized public repository creation and the first push on
October 13. The independent repository is `xmyd0915/moonar`. Only that account is
in scope. Forms and private identity or bank information remain with the
participant.

## Verification findings

- GNU ar 2.30 on Windows verified long names, duplicate records, payload boundaries
  and real C object archives. Deterministic/non-deterministic archives differed in
  metadata; rebuilding the C function changed its payload.
- The first Linux CI run passed compiler and unit-test checks, GNU ar 2.42 and
  LLVM 18.1.3 GNU/BSD comparisons. Its Darwin comparison failed because the test
  incorrectly assumed the archived size equalled the source file size. LLVM's
  writer includes alignment bytes in Darwin payloads. The oracle now checks
  declared bytes against the archiver's own extraction and print output.
- GNU ar 2.30 on Windows translates LF on standard output in the object-file
  sample. The test uses extraction into a generated scratch directory for binary
  comparisons, without normalizing the archive bytes.
- A consumer-package check showed `pub struct Archive` exposed its mutable record
  array despite preventing field replacement. `Archive` is now abstract, keeping
  validated offsets and storage inside the library.
- Parsing tests include all truncations of a mixed archive, byte mutations and
  limits on expanded names. These are regression tests, not a proof that every
  malformed input or resource-use pattern has been covered.
- GNU name tables are scanned for validity but only referenced entries are kept
  in the lookup map, avoiding one allocation for every unused name.

The corrected GNU/LLVM comparison and both CI platforms passed at commit
`10c2491`. Later commits must pass their own runs before release.

Check the repository's current CI run for the result at a particular commit;
this log does not turn a failed or pending run into a pass.

## AI assistance and verification

Codex assisted the research, design, implementation, tests and documentation.
No claim is made that generated code was manually authored. No old project code
or commit history is imported. Tests and comparisons are recorded only after they
actually run. User understanding and the human-written application are still
separate work to complete.
