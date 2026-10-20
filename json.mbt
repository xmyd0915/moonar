///|
pub fn MemberKind::label(self : MemberKind) -> String {
  match self {
    Regular => "regular"
    SymbolTable => "symbol_table"
    NameTable => "name_table"
  }
}

///|
pub fn ChangeKind::label(self : ChangeKind) -> String {
  match self {
    Added => "added"
    Removed => "removed"
    Modified => "modified"
  }
}

///|
// Decimal strings avoid precision loss in consumers that use IEEE-754 numbers.
fn metadata_value(value : Int64?) -> Json {
  match value {
    Some(n) => Json::string(n.to_string())
    None => Json::null()
  }
}

///|
fn index_value(value : Int?) -> Json {
  match value {
    Some(n) => Json(n)
    None => Json::null()
  }
}

///|
fn member_json(entry : Member, index : Int) -> Json {
  Json::object({
    "index": Json(index),
    "name_display": Json(entry.name_text()),
    "name_hex": Json(entry.name_hex()),
    "kind": Json(entry.kind.label()),
    "header_offset": Json(entry.header_offset),
    "data_offset": Json(entry.data_offset),
    "size": Json(entry.size),
    "stored_size": Json(entry.stored_size),
    "metadata": Json::object({
      "timestamp": metadata_value(entry.metadata.timestamp),
      "uid": metadata_value(entry.metadata.uid),
      "gid": metadata_value(entry.metadata.gid),
      "mode": metadata_value(entry.metadata.mode),
    }),
  })
}

///|
/// Thin member sizes describe external files; no inline data offset is exposed.
pub fn ThinArchive::to_json(self : ThinArchive) -> Json {
  let entries : Array[Json] = []
  for i = 0; i < self.member_count(); i = i + 1 {
    let entry = self.get_member(i).unwrap()
    entries.push(
      Json::object({
        "index": Json(i),
        "name_display": Json(entry.name_text()),
        "name_hex": Json(entry.name_hex()),
        "kind": Json(entry.kind.label()),
        "header_offset": Json(entry.header_offset),
        "size": Json(entry.size),
        "external": Json(entry.kind == Regular),
        "metadata": Json::object({
          "timestamp": metadata_value(entry.metadata.timestamp),
          "uid": metadata_value(entry.metadata.uid),
          "gid": metadata_value(entry.metadata.gid),
          "mode": metadata_value(entry.metadata.mode),
        }),
      }),
    )
  }
  let symbols = self.archive.to_json()
  let index_json = match symbols {
    Object(fields) => fields.get("symbol_indexes").unwrap()
    _ => Json::array([])
  }
  Json::object({
    "schema_version": Json(1),
    "format": Json("thin"),
    "byte_length": Json(self.byte_length()),
    "members": Json::array(entries),
    "symbol_indexes": index_json,
  })
}

///|
/// Schema version 1. Display names may be lossy; name_hex is the raw identity.
/// Metadata numbers use decimal strings or null. Offsets and sizes are integers.
pub fn Archive::to_json(self : Archive) -> Json {
  let entries : Array[Json] = []
  for i, entry in self.records {
    entries.push(member_json(entry, i))
  }
  Json::object({
    "schema_version": Json(1),
    "format": Json("ar"),
    "byte_length": Json(self.byte_length()),
    "members": Json::array(entries),
    "symbol_indexes": Json::array(
      self.indexes.map(fn(table) {
        Json::object({
          "record_index": Json(table.record_index),
          "format": Json(table.format),
          "symbols": Json::array(
            table.symbols.map(fn(symbol) {
              Json::object({
                "name_display": Json(
                  @utf8.decode_lossy(symbol.name[:], ignore_bom=false),
                ),
                "name_hex": Json(hex_bytes(symbol.name)),
                "member_index": Json(symbol.member_index),
                "name_offset": Json(symbol.name_offset),
                "offset_field_offset": Json(symbol.offset_field_offset),
              })
            }),
          ),
        })
      }),
    ),
  })
}

///|
fn changes_json(changes : Array[MemberChange]) -> Json {
  Json::array(
    changes.map(fn(change) {
      Json::object({
        "change": Json(change.change.label()),
        "name_display": Json(
          @utf8.decode_lossy(change.name[:], ignore_bom=false),
        ),
        "name_hex": Json(hex_bytes(change.name)),
        "member_kind": Json(change.member_kind.label()),
        "occurrence": Json(change.occurrence),
        "before_index": index_value(change.before_index),
        "after_index": index_value(change.after_index),
        "payload_changed": Json(change.payload_changed),
        "metadata_changed": Json(change.metadata_changed),
      })
    }),
  )
}

///|
fn ambiguities_json(ambiguities : Array[MatchAmbiguity]) -> Json {
  Json::array(
    ambiguities.map(fn(item) {
      Json::object({
        "name_display": Json(@utf8.decode_lossy(item.name[:], ignore_bom=false)),
        "name_hex": Json(hex_bytes(item.name)),
        "member_kind": Json(item.member_kind.label()),
        "before_indices": Json::array(
          item.before_indices.map(fn(i) { Json(i) }),
        ),
        "after_indices": Json::array(item.after_indices.map(fn(i) { Json(i) })),
      })
    }),
  )
}

///|
pub fn Comparison::to_json(self : Comparison) -> Json {
  Json::object({
    "schema_version": Json(1),
    "bytes_equal": Json(self.bytes_equal),
    "comparison_mode": Json("physical"),
    "order_changed": Json(self.order_changed),
    "changes": changes_json(self.changes),
    "ambiguities": ambiguities_json(self.ambiguities),
  })
}

///|
pub fn LogicalComparison::to_json(self : LogicalComparison) -> Json {
  Json::object({
    "schema_version": Json(1),
    "comparison_mode": Json("logical"),
    "bytes_equal": Json(self.bytes_equal),
    "content_equal": Json(self.content_equal),
    "metadata_changed": Json(self.metadata_changed),
    "order_changed": Json(self.order_changed),
    "symbols_equal": Json(self.symbols_equal),
    "symbol_index_presence_changed": Json(self.symbol_index_presence_changed),
    "changes": changes_json(self.changes),
    "ambiguities": ambiguities_json(self.ambiguities),
  })
}

///|
pub fn ParseError::to_json(self : ParseError) -> Json {
  Json::object({
    "schema_version": Json(1),
    "error": Json::object({
      "code": Json(self.code),
      "offset": Json(self.offset),
      "message": Json(self.message),
    }),
  })
}
