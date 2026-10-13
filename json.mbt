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
  })
}

///|
pub fn Comparison::to_json(self : Comparison) -> Json {
  let changes = self.changes.map(fn(change) {
    Json::object({
      "change": Json(change.change.label()),
      "name_display": Json(@utf8.decode_lossy(change.name[:], ignore_bom=false)),
      "name_hex": Json(hex_bytes(change.name)),
      "member_kind": Json(change.member_kind.label()),
      "occurrence": Json(change.occurrence),
      "before_index": index_value(change.before_index),
      "after_index": index_value(change.after_index),
      "payload_changed": Json(change.payload_changed),
      "metadata_changed": Json(change.metadata_changed),
    })
  })
  Json::object({
    "schema_version": Json(1),
    "bytes_equal": Json(self.bytes_equal),
    "order_changed": Json(self.order_changed),
    "changes": Json::array(changes),
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
