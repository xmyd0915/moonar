///|
fn write_coff(
  builder : ArchiveBuilder,
  metadata : WriteMetadata,
  supplied : Array[WriteSymbol]?,
  max_bytes : Int32,
  max_members : Int32,
  max_name_bytes : Int32,
  max_symbols : Int32,
  max_symbol_name_bytes : Int32,
) -> Result[Bytes, WriteError] {
  try {
    if max_bytes < 0 ||
      max_members < 0 ||
      max_name_bytes < 0 ||
      max_symbols < 0 ||
      max_symbol_name_bytes < 0 {
      write_reject("WR003", None, "limits must be nonnegative")
    }
    let entries = builder.members
    let symbols = supplied.unwrap_or([])
    if entries.length() > 65535 {
      write_reject(
        "WR003",
        None,
        "COFF linker member ordinals support at most 65535 ordinary members",
      )
    }
    if symbols.length() > max_symbols / 2 {
      write_reject(
        "WR003",
        None,
        "COFF symbol budget counts both linker members",
      )
    }
    let mut records = write_add(
      entries.length(),
      2,
      max_members,
      None,
      "archive entry limit exceeded",
    )
    let mut expanded_names = write_add(
      0,
      2,
      max_name_bytes,
      None,
      "expanded entry-name byte limit exceeded",
    )
    let offsets : Map[Bytes, Int32] = Map([])
    let long_names : Array[Bytes] = []
    let mut long_size = 0
    for i, entry in entries {
      write_member_valid(entry, i)
      expanded_names = write_add(
        expanded_names,
        entry.name.length(),
        max_name_bytes,
        Some(i),
        "expanded entry-name byte limit exceeded",
      )
      if !write_gnu_short_name(entry.name) && offsets.get(entry.name) is None {
        offsets[entry.name] = long_size
        long_names.push(entry.name)
        long_size = write_add(
          long_size,
          entry.name.length(),
          max_bytes,
          Some(i),
          "archive byte limit exceeded",
        )
        long_size = write_add(
          long_size,
          1,
          max_bytes,
          Some(i),
          "archive byte limit exceeded",
        )
      }
    }
    if long_size > 0 {
      records = write_add(
        records,
        1,
        max_members,
        None,
        "archive entry limit exceeded",
      )
      expanded_names = write_add(
        expanded_names,
        2,
        max_name_bytes,
        None,
        "expanded entry-name byte limit exceeded",
      )
    }
    ignore(records)
    ignore(expanded_names)
    let mut first_size = 4
    let mut second_size = write_add(
      8,
      entries.length() * 4,
      max_bytes,
      None,
      "archive byte limit exceeded",
    )
    let mut symbol_bytes = 0
    for symbol in symbols {
      if symbol.member_index < 0 || symbol.member_index >= entries.length() {
        write_reject(
          "WR005",
          Some(symbol.member_index),
          "symbol target is outside the ordinary members",
        )
      }
      if symbol.name.is_empty() || symbol.name.find(b"\x00"[:]) is Some(_) {
        write_reject(
          "WR005",
          Some(symbol.member_index),
          "symbol names must be nonempty and contain no NUL",
        )
      }
      for _copy in 0..<2 {
        symbol_bytes = write_add(
          symbol_bytes,
          symbol.name.length(),
          max_symbol_name_bytes,
          Some(symbol.member_index),
          "symbol-name byte limit exceeded",
        )
      }
      first_size = write_add(
        first_size,
        5,
        max_bytes,
        None,
        "archive byte limit exceeded",
      )
      first_size = write_add(
        first_size,
        symbol.name.length(),
        max_bytes,
        None,
        "archive byte limit exceeded",
      )
      second_size = write_add(
        second_size,
        3,
        max_bytes,
        None,
        "archive byte limit exceeded",
      )
      second_size = write_add(
        second_size,
        symbol.name.length(),
        max_bytes,
        None,
        "archive byte limit exceeded",
      )
    }
    ignore(symbol_bytes)
    let mut end = write_add(
      0,
      8,
      max_bytes,
      None,
      "archive byte limit exceeded",
    )
    end = write_record_end(end, first_size, max_bytes, None)
    end = write_record_end(end, second_size, max_bytes, None)
    if long_size > 0 {
      end = write_record_end(end, long_size, max_bytes, None)
    }
    let headers : Array[Int32] = []
    for i, entry in entries {
      headers.push(end)
      end = write_record_end(end, entry.data.length(), max_bytes, Some(i))
    }
    let ordered = Array::makei(symbols.length(), fn(i) { i })
    ordered.sort_by(fn(a, b) {
      let order = symbols[a].name.lexical_compare(symbols[b].name)
      if order == 0 {
        a - b
      } else {
        order
      }
    })
    let out = @buffer.Buffer(size_hint=end)
    out.write_bytes(b"!<arch>\n"[:])
    let special : Metadata = {
      timestamp: None,
      uid: None,
      gid: None,
      mode: None,
    }
    write_header(out, b"/", special, first_size)
    out.write_int_be(symbols.length())
    for symbol in symbols {
      out.write_int_be(headers[symbol.member_index])
    }
    for symbol in symbols {
      out.write_bytes(symbol.name[:])
      out.write_byte(b'\x00')
    }
    write_padding(out, first_size)
    write_header(out, b"/", special, second_size)
    out.write_int_le(entries.length())
    for header in headers {
      out.write_int_le(header)
    }
    out.write_int_le(symbols.length())
    for i in ordered {
      out.write_uint16_le((symbols[i].member_index + 1).to_uint16())
    }
    for i in ordered {
      out.write_bytes(symbols[i].name[:])
      out.write_byte(b'\x00')
    }
    write_padding(out, second_size)
    if long_size > 0 {
      write_header(out, b"//", special, long_size)
      for name in long_names {
        out.write_bytes(name[:])
        out.write_byte(b'\x00')
      }
      write_padding(out, long_size)
    }
    let deterministic : Metadata = {
      timestamp: Some(0L),
      uid: Some(0L),
      gid: Some(0L),
      mode: Some(420L),
    }
    for entry in entries {
      let name = if write_gnu_short_name(entry.name) {
        entry.name + b"/"
      } else {
        @utf8.encode("/\{offsets[entry.name]}")
      }
      write_header(
        out,
        name,
        if metadata == Deterministic {
          deterministic
        } else {
          entry.metadata
        },
        entry.data.length(),
      )
      out.write_bytes(entry.data[:])
      write_padding(out, entry.data.length())
    }
    Ok(out.to_bytes())
  } catch {
    InvalidWrite(error) => Err(error)
  }
}
