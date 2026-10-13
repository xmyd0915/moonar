///|
// Index each GNU name once. Repeated references must not rescan the whole table.
fn gnu_names(
  data : Bytes,
  start : Int,
  size : Int,
) -> Map[Int, Bytes] raise InvalidArchive {
  let names : Map[Int, Bytes] = Map([])
  let mut cursor = start
  let end = start + size
  while cursor < end {
    // GNU ar may include one final newline in the table's declared size.
    if cursor == end - 1 && data[cursor] == b'\n' {
      break
    }
    let mut stop = cursor
    while stop + 1 < end && !(data[stop] == b'/' && data[stop + 1] == b'\n') {
      stop += 1
    }
    if stop + 1 >= end {
      reject("AR006", cursor, "unterminated GNU long name")
    }
    if stop == cursor {
      reject("AR006", cursor, "empty GNU long name")
    }
    names[cursor - start] = data[cursor:stop].to_owned()
    cursor = stop + 2
  }
  names
}
