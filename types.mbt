///|
/// Structural roles of archive records. Symbol indexes remain opaque bytes.
pub(all) enum MemberKind {
  Regular
  SymbolTable
  NameTable
} derive(Eq, Debug)

///|
/// Blank numeric fields, used by special archive records, are represented by None.
pub(all) struct Metadata {
  timestamp : Int64?
  uid : Int64?
  gid : Int64?
  mode : Int64?
} derive(Eq, Debug)

///|
/// A record in physical archive order. Names are bytes, not assumed to be UTF-8.
/// `size` excludes a BSD embedded name; `stored_size` is the header's size field.
pub(all) struct Member {
  name : Bytes
  kind : MemberKind
  header_offset : Int
  data_offset : Int
  size : Int
  stored_size : Int
  metadata : Metadata
} derive(Eq, Debug)

///|
/// An in-memory archive, including special records in physical order.
struct Archive {
  data : Bytes
  records : Array[Member]
} derive(Debug)

///|
/// A byte offset and stable code explain why parsing stopped.
pub(all) struct ParseError {
  code : String
  offset : Int
  message : String
} derive(Eq, Debug)

///|
/// Lossy display only. Use `name` or `name_hex` for lossless identity.
pub fn Member::name_text(self : Member) -> String {
  @utf8.decode_lossy(self.name[:], ignore_bom=false)
}

///|
/// A lossless name suitable for JSON and comparison keys.
pub fn Member::name_hex(self : Member) -> String {
  hex_bytes(self.name)
}

///|
fn hex_bytes(bytes : Bytes) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let result = StringBuilder()
  for byte in bytes {
    let n = byte.to_int()
    result.write_char(digits[n / 16])
    result.write_char(digits[n % 16])
  }
  result.to_string()
}

///|
/// Return an owned copy of one record's payload, or None for an invalid index.
pub fn Archive::member_bytes(self : Archive, index : Int) -> Bytes? {
  guard self.records.get(index) is Some(entry) else { return None }
  Some(self.data[entry.data_offset:entry.data_offset + entry.size].to_owned())
}

///|
pub fn Archive::byte_length(self : Archive) -> Int {
  self.data.length()
}

///|
/// Number of physical records, including name and symbol tables.
pub fn Archive::member_count(self : Archive) -> Int {
  self.records.length()
}

///|
/// Return one immutable record, or None for an invalid index.
pub fn Archive::get_member(self : Archive, index : Int) -> Member? {
  self.records.get(index)
}

///|
pub extend MemberKind with Eq::{equal, not_equal}

///|
pub extend Metadata with Eq::{equal, not_equal}

///|
pub extend Member with Eq::{equal, not_equal}

///|
pub extend ParseError with Eq::{equal, not_equal}

///|
pub extend MemberKind with Debug::{to_repr}

///|
pub extend Metadata with Debug::{to_repr}

///|
pub extend Member with Debug::{to_repr}

///|
pub extend ParseError with Debug::{to_repr}

///|
pub extend Archive with Debug::{to_repr}
