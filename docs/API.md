# API and JSON notes

The public library API is generated in `pkg.generated.mbti`. `Archive` is an
abstract type: only successful parsing constructs one, and callers cannot access
its internal record array. Offsets are zero-based byte positions in the original
input. A member index refers to physical archive order, including special records.

Creation, editing and the separate `ThinArchive` API are documented in
[Writing and thin members](WRITING.md). Editor positions count ordinary members
only; parsed archive and symbol-index positions count physical records.

## JSON version 1

All JSON results contain `schema_version: 1`. Field ordering is not contractual.
Human-readable messages may improve between versions; consumers should branch on
error codes, kinds and change kinds instead of matching message text.

Inspection (and successful JSON `check`) returns:

```json
{
  "schema_version": 1,
  "format": "ar",
  "byte_length": 144,
  "members": [
    {
      "index": 0,
      "name_display": "config.txt",
      "name_hex": "636f6e6669672e747874",
      "kind": "regular",
      "header_offset": 8,
      "data_offset": 68,
      "size": 11,
      "stored_size": 11,
      "metadata": {"timestamp": "0", "uid": "0", "gid": "0", "mode": "420"}
    }
  ]
}
```

This excerpt omits the second member. `kind` is `regular`, `name_table` or
`symbol_table`. `name_display` is a lossy UTF-8 display string; `name_hex` preserves
every name byte. `stored_size` comes from the header, while `size` excludes BSD
embedded name bytes. Neither includes the ordinary odd-byte alignment after a
record. Darwin padding declared inside the payload is retained.

Thin inspection uses `"format": "thin"`. Ordinary records have `"external": true`
and their declared external `size`; no inline `data_offset` is exposed.
`archive_member_offset` is null for direct references and special records; an
integer identifies a member header in the referenced archive. Inspection retains
the container path; resolution and logical snapshots use the final member name.
`check` validates container/index metadata without loading external files.
`check --external` also validates every thin external member. Successful thin JSON
adds `external_checked: true` and `external_byte_length` (cumulative bytes, counting
repeated references). Loading failures include the archive `input`, error code
and the original thin member's header offset. This check does not rediscover
object symbols or establish that the index names match actual definitions.

`list --json` is a distinct selector view. It contains `schema_version`, `format`,
`byte_length`, `index_kind: "ordinary_member"` and `members`. Only ordinary members
appear. Their `index` is the zero-based selector accepted by `extract`, `replace`,
`delete`, `move` and `rename`; `record_index` retains the physical record position.
Use `inspect --json` for physical symbol-index mappings. Never pass an inspection
physical index directly to an edit command.

Successful mutation JSON contains `schema_version`, `operation`, `output`
and `byte_length`. Mutation failure returns exit code 2 and an `error` object.
New output paths require `--force` to replace an existing file; in-place edits
replace atomically.

Metadata values are **decimal strings or null**, not JSON numbers. This preserves
integer values in JavaScript consumers. The header mode is octal, so header `644`
becomes decimal string `"420"`. A blank field is null. Numeric fields reject signs,
non-digits and internal whitespace, except that Microsoft COFF library timestamps
of `-1` represent unknown time and decode to null. Sizes and offsets fit signed 32-bit integers;
metadata is represented as signed 64-bit nonnegative values.

Comparison returns `bytes_equal`, `order_changed` and `changes`. Each change has:

| Field | Meaning |
| --- | --- |
| `change` | `added`, `removed`, `modified` |
| `name_display`, `name_hex` | Display and lossless names |
| `member_kind` | The record kind |
| `occurrence` | One-based occurrence of this kind/name pair |
| `before_index`, `after_index` | Physical index or null if absent |
| `payload_changed`, `metadata_changed` | Flags for modified records; false for added/removed |

Changes follow the old archive's order, followed by new-only records in the new
archive's order. Header spelling and layout may differ while logical records
match; `bytes_equal` still reports false. Physical symbol table changes describe
bytes; use `compare_logical` for symbol-to-member mapping equality. Neither API
analyzes object-code equivalence.

## Errors

```json
{"schema_version":1,"error":{"code":"AR002","offset":140,"message":"truncated member payload"}}
```

| Code | Meaning |
| --- | --- |
| AR001 | Missing or invalid archive signature for the selected parser |
| AR002 | Truncated header or payload |
| AR003 | Invalid header trailer or alignment byte |
| AR004 | Invalid or missing numeric field |
| AR005 | Number exceeds the supported range |
| AR006 | Invalid name, embedded name length or GNU table reference |
| AR007 | Thin input passed to `parse`; use `parse_thin` |
| AR008 | Invalid or exceeded resource limit |
| AR009 | Invalid symbol index, string or member reference |
| AR010 | Ambiguous byte order or unsupported multiple-index layout |
| AR011–AR015 | Thin reference, path, loading or declared-size error; see WRITING.md |
| WR001–WR006 | Editing, metadata, budget, index policy, symbol or object error |
| OB001–OB003 | Object structure, unsupported format or symbol discovery budget |
| IO001 | CLI filesystem read failure; no offset |
| IO002 | CLI filesystem publication failure |
| IO003 | CLI unsafe output alias or path resolution failure |

The offset identifies the field or position where parsing stopped, not always the
byte that originally caused the corruption. JSON diff parse errors also contain
an `input` field identifying the failing path. Both success and failure in JSON
mode are one JSON value followed by a newline. Argument errors use stderr text.

Parsing validates container structure and symbol index targets. It does not
parse object internals to establish that referenced definitions exist, or verify
executable compatibility, cryptographic signatures or Debian policy.

## Symbol index API and JSON

`parse` accepts `max_symbols` (default 1000000) and `max_symbol_name_bytes`
(default 67108864), in addition to `max_bytes`, `max_members`, `max_name_bytes`.
All limits are nonnegative and repeated names count towards expanded budgets.

`symbol_indexes()` returns copies of both array levels. Each index contains
`record_index`, `format`, and `symbols`. JSON adds `symbol_indexes` alongside
`members`. Formats are `gnu32`, `gnu64`, `bsd32-le`, `bsd32-be`, `bsd64-le`,
`bsd64-be`, and `bsd32-neutral`/`bsd64-neutral` when both byte orders give the
same result. Different valid interpretations return `AR010`.

Each symbol contains `name` (JSON: `name_display`/`name_hex`), `member_index`,
`name_offset` and `offset_field_offset`. The last two fields locate name bytes
and the target-offset field in the original archive. Targets must resolve to
exact ordinary-member headers. Counts, string boundaries, termination, padding
and SORTED name order are checked using bytewise lexical comparison. Microsoft
COFF libraries have two leading `/` records with cross-checked mappings. Both
records count toward resource limits, while `symbol_indexes` exposes the canonical
second table with `format: "coff"`. Other multiple-index layouts return `AR010`.

## Matching and logical comparison

Both modes group by kind and raw name. Full payload equality is matched first,
then remaining entries pair in occurrence order. Hash collisions still require
byte equality. `occurrence` refers to the old group for paired/removed entries,
and to the new group for additions. Insertions alone are not relative reordering.

Both results add `ambiguities`: entries have raw/display names, `member_kind`,
`before_indices`, and `after_indices`. They identify interchangeable exact
matches or multiple remaining candidates. Pairing is deterministic; observed
correspondence does not prove historical identity. Identical complete inputs
have no ambiguity report.

`compare_logical` excludes special records from member matching and returns:

| Field | Meaning |
| --- | --- |
| `comparison_mode` | `logical`; default comparison uses `physical` |
| `bytes_equal` | Equality of every input byte |
| `content_equal` | Same ordinary names and payload multiset, excluding order/metadata |
| `metadata_changed` | At least one paired ordinary member has different metadata |
| `order_changed` | Relative order of paired ordinary members changed |
| `symbols_equal` | Equal symbol-to-paired-member mappings, preserving target order per symbol |
| `symbol_index_presence_changed` | Only one archive has an index |
| `changes`, `ambiguities` | Ordinary-member changes and pairing ambiguities |

Different widths, absolute offsets, and order between distinct symbol names can
preserve mappings. Same-name target precedence remains significant. An empty
index and absent index have equal mappings but different presence. Results use
the reported correspondence, so inspect `ambiguities` as well.

`diff --logical` exits 0 only when content, paired metadata/order, mappings and
index presence match and there are no ambiguities. It can exit 0 with
`bytes_equal=false`. No mode asserts executable, ABI or link equivalence.

## Snapshot comparison

`Archive.snapshot()` and `ThinArchive.snapshot(loader, ...)` produce an abstract
`ArchiveSnapshot`. `before.compare_logical(after)` accepts any combination of
ordinary/thin snapshots and returns `LogicalComparison` with the existing JSON
schema. All change and ambiguity positions refer to original physical records.

For thin snapshots, `bytes_equal` measures the original container bytes, while
`content_equal` measures loaded member contents. Identical containers can have
different external contents. `diff --logical` supports these combinations;
physical `diff` continues to require ordinary archives. Each thin input has its
own cumulative external byte budget, in addition to its container parser budget.
The original parsed symbol mappings are retained, not regenerated.

`cli.Request` now includes `external` and `allow_parent_paths` booleans. The query
parser accepts `--external` only with `check`, and `--allow-parent-paths` only with
`check --external` or `diff --logical`. Check failures in external members exit 1;
logical comparison loading failures exit 2 and identify the archive input.
