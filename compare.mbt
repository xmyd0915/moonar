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
  occurrence : Int32
  before_index : Int32?
  after_index : Int32?
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
  ambiguities : Array[MatchAmbiguity]
} derive(Eq, Debug)

///|
/// Several member identities fit the observed data; pairing is deterministic.
pub(all) struct MatchAmbiguity {
  name : Bytes
  member_kind : MemberKind
  before_indices : Array[Int32]
  after_indices : Array[Int32]
} derive(Eq, Debug)

///|
/// Logical members exclude name/symbol table records. Payload bytes are exact;
/// embedded Darwin padding is not guessed or removed. Symbol mappings preserve
/// the order of targets for each symbol name.
pub(all) struct LogicalComparison {
  bytes_equal : Bool
  content_equal : Bool
  metadata_changed : Bool
  order_changed : Bool
  symbols_equal : Bool
  symbol_index_presence_changed : Bool
  changes : Array[MemberChange]
  ambiguities : Array[MatchAmbiguity]
} derive(Eq, Debug)

///|
pub extend MatchAmbiguity with Eq::{equal, not_equal}

///|
pub extend MatchAmbiguity with Debug::{to_repr}

///|
pub extend LogicalComparison with Eq::{equal, not_equal}

///|
pub extend LogicalComparison with Debug::{to_repr}

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
fn record_keys(entries : Array[Member]) -> Array[((Int32, Bytes), Int32)] {
  let counts : Map[(Int32, Bytes), Int32] = Map([])
  entries.map(fn(entry) {
    let kind = match entry.kind {
      Regular => 0
      SymbolTable => 1
      NameTable => 2
    }
    let base = (kind, entry.name)
    let occurrence = counts.get(base).unwrap_or(0) + 1
    counts[base] = occurrence
    (base, occurrence)
  })
}

///|
priv struct RecordMatches {
  pairs : Array[Int32?]
  ambiguities : Array[MatchAmbiguity]
  left_keys : Array[((Int32, Bytes), Int32)]
  right_keys : Array[((Int32, Bytes), Int32)]
}

///|
fn payload(archive : Archive, index : Int32) -> BytesView {
  let entry = archive.records[index]
  archive.data[entry.data_offset:entry.data_offset + entry.size]
}

///|
// Equal payloads are matched first using byte-view keys (hash collisions still
// require byte equality). Remaining same-name members pair in occurrence order.
// No quadratic matrix, payload copies, or reliance on a fingerprint alone.
fn match_records(
  before : Archive,
  after : Archive,
  logical : Bool,
) -> RecordMatches {
  let bytes_equal = before.data == after.data
  let left_keys = record_keys(before.records)
  let right_keys = record_keys(after.records)
  let left_groups : Map[(Int32, Bytes), Array[Int32]] = Map([])
  let right_groups : Map[(Int32, Bytes), Array[Int32]] = Map([])
  for i, (key, _) in left_keys {
    if !logical || before.records[i].kind == Regular {
      match left_groups.get(key) {
        Some(group) => group.push(i)
        None => left_groups[key] = [i]
      }
    }
  }
  for i, (key, _) in right_keys {
    if !logical || after.records[i].kind == Regular {
      match right_groups.get(key) {
        Some(group) => group.push(i)
        None => right_groups[key] = [i]
      }
    }
  }
  let pairs : Array[Int32?] = Array::make(before.records.length(), None)
  let ambiguities : Array[MatchAmbiguity] = []
  let seen : Map[(Int32, Bytes), Unit] = Map([])
  let used = Array::make(after.records.length(), false)
  for i, (key, _) in left_keys {
    if seen.get(key) is Some(_) ||
      (logical && before.records[i].kind != Regular) {
      continue
    }
    seen[key] = ()
    let left = left_groups.get(key).unwrap()
    let right = right_groups.get(key).unwrap_or([])
    if right.is_empty() {
      continue
    }
    // Unique names have only one possible pairing. Payload equality is checked
    // by compare_records, so building content buckets would repeat the scan.
    if left.length() == 1 && right.length() == 1 {
      pairs[left[0]] = Some(right[0])
      used[right[0]] = true
      continue
    }
    let buckets : Map[BytesView, Array[Int32]] = Map([])
    let counts : Map[BytesView, Int32] = Map([])
    let cursors : Map[BytesView, Int32] = Map([])
    for j in right {
      let bytes = payload(after, j)
      match buckets.get(bytes) {
        Some(bucket) => bucket.push(j)
        None => buckets[bytes] = [j]
      }
    }
    for j in left {
      let bytes = payload(before, j)
      counts[bytes] = counts.get(bytes).unwrap_or(0) + 1
    }
    let mut ambiguous = false
    for j in left {
      let bytes = payload(before, j)
      if buckets.get(bytes) is Some(bucket) {
        let cursor = cursors.get(bytes).unwrap_or(0)
        if cursor < bucket.length() {
          let target = bucket[cursor]
          pairs[j] = Some(target)
          used[target] = true
          cursors[bytes] = cursor + 1
          if bucket.length() > 1 || counts.get(bytes).unwrap() > 1 {
            ambiguous = true
          }
        }
      }
    }
    let remaining_left = left.filter(fn(j) { pairs[j] is None })
    let remaining_right = right.filter(fn(j) { !used[j] })
    let count = Int32::min(remaining_left.length(), remaining_right.length())
    if count > 0 &&
      (remaining_left.length() > 1 || remaining_right.length() > 1) {
      ambiguous = true
    }
    for j = 0; j < count; j = j + 1 {
      pairs[remaining_left[j]] = Some(remaining_right[j])
      used[remaining_right[j]] = true
    }
    if ambiguous && !bytes_equal {
      ambiguities.push({
        name: before.records[i].name,
        member_kind: before.records[i].kind,
        before_indices: left.copy(),
        after_indices: right.copy(),
      })
    }
  }
  { pairs, ambiguities, left_keys, right_keys, }
}

///|
fn compare_records(
  before : Archive,
  after : Archive,
  logical : Bool,
  matches : RecordMatches,
) -> Comparison {
  let left_keys = matches.left_keys
  let right_keys = matches.right_keys
  let matched = Array::make(after.records.length(), false)
  let changes : Array[MemberChange] = []
  let mut order_changed = false
  let mut previous_index = -1
  for i, (_, occurrence) in left_keys {
    let entry = before.records[i]
    if logical && entry.kind != Regular {
      continue
    }
    match matches.pairs[i] {
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
        let payload_changed = payload(before, i) != payload(after, j)
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
    if !matched[i] && (!logical || after.records[i].kind == Regular) {
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
  {
    bytes_equal: before.data == after.data,
    order_changed,
    changes,
    ambiguities: matches.ambiguities,
  }
}

///|
/// Compare physical records by kind/name, matching identical payloads first.
pub fn compare(before : Archive, after : Archive) -> Comparison {
  compare_records(before, after, false, match_records(before, after, false))
}

///|
fn symbol_mappings(
  archive : Archive,
  pairs : Array[Int32?]?,
) -> Map[Bytes, Array[Int32]]? {
  let mappings : Map[Bytes, Array[Int32]] = Map([])
  for table in archive.indexes {
    for symbol in table.symbols {
      let target = match pairs {
        None => symbol.member_index
        Some(pairs) =>
          match pairs[symbol.member_index] {
            Some(target) => target
            None => return None
          }
      }
      match mappings.get(symbol.name) {
        Some(targets) => targets.push(target)
        None => mappings[symbol.name] = [target]
      }
    }
  }
  Some(mappings)
}

///|
/// Compare regular-member bytes and validated symbol-to-member mappings across
/// encodings. This does not assert executable or ABI equivalence.
pub fn compare_logical(before : Archive, after : Archive) -> LogicalComparison {
  let matches = match_records(before, after, true)
  let result = compare_records(before, after, true, matches)
  let old_symbols = symbol_mappings(before, Some(matches.pairs))
  let new_symbols = symbol_mappings(after, None).unwrap()
  let symbols_equal = match old_symbols {
    None => false
    Some(old) =>
      old.length() == new_symbols.length() &&
      old
      .iter()
      .all(fn(pair) {
        let (name, targets) = pair
        new_symbols.get(name) == Some(targets)
      })
  }
  {
    bytes_equal: result.bytes_equal,
    content_equal: result.changes.all(fn(change) {
      change.change == Modified && !change.payload_changed
    }),
    metadata_changed: result.changes.any(fn(change) { change.metadata_changed }),
    order_changed: result.order_changed,
    symbols_equal,
    symbol_index_presence_changed: before.indexes.is_empty() !=
    after.indexes.is_empty(),
    changes: result.changes,
    ambiguities: result.ambiguities,
  }
}
