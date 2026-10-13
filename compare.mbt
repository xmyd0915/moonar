///|
pub(all) enum ChangeKind {
  Added
  Removed
  Modified
} derive(Eq, Debug)

///|
/// Indices refer to physical records, including name and symbol tables.
/// Occurrence is one-based among records with the same kind and raw name.
pub(all) struct MemberChange {
  change : ChangeKind
  name : Bytes
  member_kind : MemberKind
  occurrence : Int
  before_index : Int?
  after_index : Int?
  payload_changed : Bool
  metadata_changed : Bool
} derive(Eq, Debug)

///|
/// `bytes_equal` includes every byte, even header spelling and alignment.
/// `order_changed` compares only the relative order of matched records.
pub(all) struct Comparison {
  bytes_equal : Bool
  order_changed : Bool
  changes : Array[MemberChange]
} derive(Eq, Debug)

///|
pub extend ChangeKind with Eq::{equal, not_equal}

///|
pub extend ChangeKind with Debug::{to_repr}

///|
pub extend MemberChange with Eq::{equal, not_equal}

///|
pub extend MemberChange with Debug::{to_repr}

///|
pub extend Comparison with Eq::{equal, not_equal}

///|
pub extend Comparison with Debug::{to_repr}

///|
fn record_keys(entries : Array[Member]) -> Array[(String, Int)] {
  let counts : Map[String, Int] = Map([])
  entries.map(fn(entry) {
    let prefix = match entry.kind {
      Regular => "r:"
      SymbolTable => "s:"
      NameTable => "n:"
    }
    let base = prefix + entry.name_hex()
    let occurrence = counts.get(base).unwrap_or(0) + 1
    counts[base] = occurrence
    (base + ":" + occurrence.to_string(), occurrence)
  })
}

///|
/// Compare records by kind, raw name and duplicate occurrence. Symbol/name table
/// payloads are included; this is not an ABI or link-equivalence comparison.
pub fn compare(before : Archive, after : Archive) -> Comparison {
  let left_keys = record_keys(before.records)
  let right_keys = record_keys(after.records)
  let right_index : Map[String, Int] = Map([])
  for i, (key, _) in right_keys {
    right_index[key] = i
  }
  let matched = Array::make(after.records.length(), false)
  let changes : Array[MemberChange] = []
  let mut order_changed = false
  let mut previous_index = -1
  for i, (key, occurrence) in left_keys {
    let entry = before.records[i]
    match right_index.get(key) {
      None =>
        changes.push({
          change: Removed,
          name: entry.name,
          member_kind: entry.kind,
          occurrence,
          before_index: Some(i),
          after_index: None,
          payload_changed: false,
          metadata_changed: false,
        })
      Some(j) => {
        matched[j] = true
        if j < previous_index {
          order_changed = true
        }
        previous_index = j
        let other = after.records[j]
        let payload_changed = before.data[entry.data_offset:entry.data_offset +
          entry.size] !=
          after.data[other.data_offset:other.data_offset + other.size]
        let metadata_changed = entry.metadata != other.metadata
        if payload_changed || metadata_changed {
          changes.push({
            change: Modified,
            name: entry.name,
            member_kind: entry.kind,
            occurrence,
            before_index: Some(i),
            after_index: Some(j),
            payload_changed,
            metadata_changed,
          })
        }
      }
    }
  }
  for i, (_, occurrence) in right_keys {
    if !matched[i] {
      let entry = after.records[i]
      changes.push({
        change: Added,
        name: entry.name,
        member_kind: entry.kind,
        occurrence,
        before_index: None,
        after_index: Some(i),
        payload_changed: false,
        metadata_changed: false,
      })
    }
  }
  { bytes_equal: before.data == after.data, order_changed, changes, }
}
