# API and JSON notes

The public library API is generated in `pkg.generated.mbti`. `Archive` is an
abstract type: only successful parsing constructs one, and callers cannot access
its internal record array. Offsets are zero-based byte positions in the original
input. A member index refers to physical archive order, including special records.

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

Metadata values are **decimal strings or null**, not JSON numbers. This preserves
integer values in JavaScript consumers. The header mode is octal, so header `644`
becomes decimal string `"420"`. A blank field is null. Numeric fields reject signs,
non-digits and internal whitespace. Sizes and offsets fit signed 32-bit integers;
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
match; `bytes_equal` still reports false. Symbol table byte changes do not identify
which symbols changed, and there is no object-code equivalence analysis.

## Errors

```json
{"schema_version":1,"error":{"code":"AR002","offset":140,"message":"truncated member payload"}}
```

| Code | Meaning |
| --- | --- |
| AR001 | Missing or invalid ordinary archive signature |
| AR002 | Truncated header or payload |
| AR003 | Invalid header trailer or alignment byte |
| AR004 | Invalid or missing numeric field |
| AR005 | Number exceeds the supported range |
| AR006 | Invalid name, embedded name length or GNU table reference |
| AR007 | Thin archive; external files are not loaded |
| AR008 | Invalid or exceeded resource limit |
| IO001 | CLI filesystem read failure; no offset |

The offset identifies the field or position where parsing stopped, not always the
byte that originally caused the corruption. JSON diff parse errors also contain
an `input` field identifying the failing path. Both success and failure in JSON
mode are one JSON value followed by a newline. Argument errors use stderr text.

Parsing validates a useful subset of ar container structure. It does not verify
symbol index targets, member executable formats, cryptographic signatures or
Debian policy. Passing `check` makes none of those promises.
