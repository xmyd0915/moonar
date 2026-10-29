///|
/// OB001: malformed object; OB002: unsupported object format or file kind;
/// OB003: discovery budget exceeded. Offsets are relative to the object bytes.
pub(all) struct ObjectError {
  code : String
  offset : Int32
  message : String
} derive(Eq, Debug)

///|
pub extend ObjectError with Eq::{equal, not_equal}

///|
pub extend ObjectError with Debug::{to_repr}

///|
priv suberror InvalidObject {
  InvalidObject(ObjectError)
}

///|
priv struct ObjectBudget {
  mut symbols_left : Int32
  mut names_left : Int32
}

///|
fn[T] object_reject(
  code : String,
  offset : Int32,
  message : String,
) -> T raise InvalidObject {
  raise InvalidObject({ code, offset, message, })
}

///|
fn object_range(
  data : Bytes,
  offset : Int32,
  size : Int32,
) -> Unit raise InvalidObject {
  if offset < 0 ||
    size < 0 ||
    offset > data.length() ||
    size > data.length() - offset {
    object_reject("OB001", offset, "object range extends beyond its bytes")
  }
}

///|
fn object_number(
  data : Bytes,
  offset : Int32,
  width : Int32,
  little : Bool,
  maximum : Int32,
) -> Int32 raise InvalidObject {
  object_range(data, offset, width)
  let mut value = 0
  for n = 0; n < width; n = n + 1 {
    let digit = data[if little { offset + width - n - 1 } else { offset + n }].to_int()
    if digit > maximum || value > (maximum - digit) / 256 {
      object_reject(
        "OB001", offset, "object integer exceeds its permitted range",
      )
    }
    value = value * 256 + digit
  }
  value
}

///|
fn object_tag(data : Bytes, offset : Int32, little : Bool) -> UInt32 {
  let mut value = 0U
  for n = 0; n < 4; n = n + 1 {
    value = (value << 8) |
      data[if little { offset + 3 - n } else { offset + n }].to_uint()
  }
  value
}

///|
fn object_nonzero(data : Bytes, offset : Int32, width : Int32) -> Bool {
  for n = offset; n < offset + width; n = n + 1 {
    if data[n] != b'\x00' {
      return true
    }
  }
  false
}

///|
fn object_charge_symbols(
  budget : ObjectBudget,
  count : Int32,
  offset : Int32,
) -> Unit raise InvalidObject {
  if count > budget.symbols_left {
    object_reject("OB003", offset, "symbol-table entry limit exceeded")
  }
  budget.symbols_left -= count
}

///|
fn object_string_table(
  data : Bytes,
  offset : Int32,
  size : Int32,
  elf : Bool,
) -> Unit raise InvalidObject {
  object_range(data, offset, size)
  if size > 0 &&
    (data[offset + size - 1] != b'\x00' || (elf && data[offset] != b'\x00')) {
    object_reject("OB001", offset, "invalid object string table terminator")
  }
}

///|
fn object_name(
  data : Bytes,
  offset : Int32,
  size : Int32,
  index : Int32,
  budget : ObjectBudget,
) -> Bytes raise InvalidObject {
  if index < 0 || index >= size {
    object_reject(
      "OB001", offset, "symbol name index is outside its string table",
    )
  }
  let start = offset + index
  let mut end = start
  while end < offset + size && data[end] != b'\x00' {
    if end - start >= budget.names_left {
      object_reject("OB003", start, "expanded symbol-name byte limit exceeded")
    }
    end += 1
  }
  if end == offset + size || end == start {
    object_reject("OB001", start, "missing, empty or unterminated symbol name")
  }
  budget.names_left -= end - start
  data[start:end].to_owned()
}

///|
priv struct ObjectSection {
  kind : UInt32
  offset : Int32
  size : Int32
  link : Int32
  info : Int32
  entry_size : Int32
  header : Int32
}

///|
fn object_elf(
  data : Bytes,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  object_range(data, 0, 16)
  let wide = match data[4] {
    b'\x01' => false
    b'\x02' => true
    _ => object_reject("OB002", 4, "unsupported ELF class")
  }
  let little = match data[5] {
    b'\x01' => true
    b'\x02' => false
    _ => object_reject("OB001", 5, "invalid ELF byte order")
  }
  let width = if wide { 8 } else { 4 }
  let header_size = if wide { 64 } else { 52 }
  let section_size = if wide { 64 } else { 40 }
  object_range(data, 0, header_size)
  if data[6] != b'\x01' || object_number(data, 20, 4, little, 2147483647) != 1 {
    object_reject("OB002", 6, "unsupported ELF version")
  }
  if object_number(data, 16, 2, little, 65535) != 1 {
    object_reject(
      "OB002", 16, "symbol discovery requires a relocatable ELF object",
    )
  }
  let declared_header = object_number(
    data,
    if wide {
      52
    } else {
      40
    },
    2,
    little,
    data.length(),
  )
  if declared_header < header_size {
    object_reject("OB001", 0, "ELF header is smaller than its class requires")
  }
  let shoff = object_number(
    data,
    if wide {
      40
    } else {
      32
    },
    width,
    little,
    data.length(),
  )
  let shstride = object_number(
    data,
    if wide {
      58
    } else {
      46
    },
    2,
    little,
    65535,
  )
  let raw_count = object_number(
    data,
    if wide {
      60
    } else {
      48
    },
    2,
    little,
    65535,
  )
  let raw_strings = object_number(
    data,
    if wide {
      62
    } else {
      50
    },
    2,
    little,
    65535,
  )
  if raw_count >= 65280 || (raw_strings >= 65280 && raw_strings != 65535) {
    object_reject(
      "OB001", 0, "ELF reserved section count requires an extended encoding",
    )
  }
  if shoff == 0 {
    if raw_count != 0 || raw_strings != 0 {
      object_reject("OB001", 0, "ELF section counts lack a section table")
    }
    return []
  }
  if shstride < section_size {
    object_reject("OB001", shoff, "ELF section-header stride is too small")
  }
  object_range(data, shoff, shstride)
  if object_tag(data, shoff + 4, little) != 0U {
    object_reject("OB001", shoff, "ELF section zero must have SHT_NULL type")
  }
  let section_count = if raw_count == 0 {
    object_number(
      data,
      shoff + (if wide { 32 } else { 20 }),
      width,
      little,
      (data.length() - shoff) / shstride,
    )
  } else {
    raw_count
  }
  if section_count == 0 || section_count > (data.length() - shoff) / shstride {
    object_reject("OB001", shoff, "ELF section table is truncated")
  }
  let strings_index = if raw_strings == 65535 {
    object_number(
      data,
      shoff + (if wide { 40 } else { 24 }),
      4,
      little,
      section_count - 1,
    )
  } else {
    raw_strings
  }
  if strings_index >= section_count {
    object_reject("OB001", shoff, "ELF section-name table index is invalid")
  }
  let sections : Array[ObjectSection] = []
  let companions : Map[Int32, Int32] = Map([])
  for n = 0; n < section_count; n = n + 1 {
    let header = shoff + n * shstride
    let kind = object_tag(data, header + 4, little)
    let relevant = kind == 2U || kind == 3U || kind == 18U
    let (offset, size) = if kind == 0U || kind == 8U {
      (0, 0)
    } else {
      let offset = object_number(
        data,
        header + (if wide { 24 } else { 16 }),
        width,
        little,
        data.length(),
      )
      let size = object_number(
        data,
        header + (if wide { 32 } else { 20 }),
        width,
        little,
        data.length() - offset,
      )
      (offset, size)
    }
    let link = if relevant {
      object_number(
        data,
        header + (if wide { 40 } else { 24 }),
        4,
        little,
        section_count - 1,
      )
    } else {
      0
    }
    let info = if kind == 2U {
      object_number(
        data,
        header + (if wide { 44 } else { 28 }),
        4,
        little,
        2147483647,
      )
    } else {
      0
    }
    let entry_size = if kind == 2U || kind == 18U {
      object_number(
        data,
        header + (if wide { 56 } else { 36 }),
        width,
        little,
        data.length(),
      )
    } else {
      0
    }
    sections.push({ kind, offset, size, link, info, entry_size, header, })
    if kind == 18U {
      if companions.get(link) is Some(_) {
        object_reject(
          "OB001", header, "multiple extended-index tables for one symbol table",
        )
      }
      companions[link] = n
    }
  }
  if strings_index != 0 && sections[strings_index].kind != 3U {
    object_reject(
      "OB001",
      sections[strings_index].header,
      "ELF section-name table must be SHT_STRTAB",
    )
  }
  for section in sections {
    if section.kind == 18U && sections[section.link].kind != 2U {
      object_reject(
        "OB001",
        section.header,
        "extended indexes must link to a symbol table",
      )
    }
  }
  let result : Array[Bytes] = []
  let seen : Map[Bytes, Unit] = Map([])
  for table_index, table in sections {
    if table.kind != 2U {
      continue
    }
    let symbol_size = if wide { 24 } else { 16 }
    if table.entry_size < symbol_size || table.size % table.entry_size != 0 {
      object_reject(
        "OB001",
        table.header,
        "invalid ELF symbol-table entry size",
      )
    }
    let count = table.size / table.entry_size
    object_charge_symbols(budget, count, table.header)
    if count == 0 || table.info == 0 || table.info > count {
      object_reject(
        "OB001",
        table.header,
        "ELF symbol table has no valid local/global boundary",
      )
    }
    let strings = sections[table.link]
    if strings.kind != 3U {
      object_reject(
        "OB001",
        table.header,
        "ELF symbol table must link to SHT_STRTAB",
      )
    }
    object_string_table(data, strings.offset, strings.size, true)
    let companion = companions
      .get(table_index)
      .map(fn(index) { sections[index] })
    if companion is Some(extra) &&
      (extra.entry_size != 4 || extra.size / 4 != count || extra.size % 4 != 0) {
      object_reject(
        "OB001",
        extra.header,
        "extended-index table does not match the symbol table",
      )
    }
    for n = 0; n < count; n = n + 1 {
      let pos = table.offset + n * table.entry_size
      if n == 0 && object_nonzero(data, pos, symbol_size) {
        object_reject("OB001", pos, "ELF null symbol must contain zero fields")
      }
      let name_index = object_number(data, pos, 4, little, strings.size)
      if name_index != 0 && name_index >= strings.size {
        object_reject(
          "OB001", pos, "ELF symbol name index is outside its string table",
        )
      }
      let info = data[pos + (if wide { 4 } else { 12 })].to_int()
      let binding = info >> 4
      let kind = info & 15
      if (n < table.info) != (binding == 0) {
        object_reject(
          "OB001", pos, "ELF local symbols do not precede external symbols",
        )
      }
      let raw_section = object_number(
        data,
        pos + (if wide { 6 } else { 14 }),
        2,
        little,
        65535,
      )
      let extra_index = match companion {
        Some(extra) =>
          object_number(
            data,
            extra.offset + n * 4,
            4,
            little,
            section_count - 1,
          )
        None => 0
      }
      let section_index = if raw_section == 65535 {
        if companion is None || extra_index == 0 {
          object_reject(
            "OB001", pos, "ELF SHN_XINDEX lacks a valid extended section index",
          )
        }
        extra_index
      } else {
        if extra_index != 0 {
          object_reject(
            "OB001", pos, "unused ELF extended section index must be zero",
          )
        }
        if raw_section < 65280 && raw_section >= section_count {
          object_reject("OB001", pos, "ELF symbol refers to a missing section")
        }
        raw_section
      }
      if section_index > 0 &&
        (raw_section < 65280 || raw_section == 65535) &&
        sections[section_index].kind == 0U {
        object_reject("OB001", pos, "ELF symbol refers to an inactive section")
      }
      if binding == 0 ||
        section_index == 0 ||
        kind == 3 ||
        kind == 4 ||
        name_index == 0 {
        continue
      }
      if binding != 1 && binding != 2 && binding != 10 {
        object_reject("OB002", pos, "unsupported ELF external symbol binding")
      }
      if raw_section >= 65280 &&
        raw_section != 65535 &&
        raw_section != 65521 &&
        raw_section != 65522 {
        object_reject("OB002", pos, "unsupported ELF special section index")
      }
      let name = object_name(
        data,
        strings.offset,
        strings.size,
        name_index,
        budget,
      )
      if seen.get(name) is None {
        seen[name] = ()
        result.push(name)
      }
    }
  }
  result
}

///|
fn object_macho(
  data : Bytes,
  wide : Bool,
  little : Bool,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  let header_size = if wide { 32 } else { 28 }
  object_range(data, 0, header_size)
  if object_number(data, 12, 4, little, 2147483647) != 1 {
    object_reject(
      "OB002", 12, "symbol discovery requires a Mach-O MH_OBJECT file",
    )
  }
  let command_size = object_number(
    data,
    20,
    4,
    little,
    data.length() - header_size,
  )
  let commands = object_number(data, 16, 4, little, command_size / 8)
  let commands_end = header_size + command_size
  let mut pos = header_size
  let mut symtab : (Int32, Int32, Int32, Int32)? = None
  let sections_no_toc : Array[Bool] = []
  for command_index = 0
      command_index < commands
      command_index = command_index + 1 {
    if commands_end - pos < 8 {
      object_reject("OB001", pos, "truncated Mach-O load command")
    }
    let command = object_tag(data, pos, little)
    let size = object_number(data, pos + 4, 4, little, commands_end - pos)
    if size < 8 || size % (if wide { 8 } else { 4 }) != 0 {
      object_reject("OB001", pos, "invalid Mach-O load-command size")
    }
    if command == 2U {
      if size != 24 || symtab is Some(_) {
        object_reject("OB001", pos, "invalid or duplicate Mach-O LC_SYMTAB")
      }
      let symbol_offset = object_number(data, pos + 8, 4, little, data.length())
      let symbol_count = object_number(
        data,
        pos + 12,
        4,
        little,
        (data.length() - symbol_offset) / (if wide { 16 } else { 12 }),
      )
      let string_offset = object_number(
        data,
        pos + 16,
        4,
        little,
        data.length(),
      )
      let string_size = object_number(
        data,
        pos + 20,
        4,
        little,
        data.length() - string_offset,
      )
      symtab = Some((symbol_offset, symbol_count, string_offset, string_size))
    } else if command == 1U || command == 25U {
      if (command == 25U) != wide {
        object_reject(
          "OB001", pos, "Mach-O segment width differs from its header",
        )
      }
      let base = if wide { 72 } else { 56 }
      let stride = if wide { 80 } else { 68 }
      if size < base {
        object_reject("OB001", pos, "truncated Mach-O segment command")
      }
      let count = object_number(
        data,
        pos + (if wide { 64 } else { 48 }),
        4,
        little,
        (size - base) / stride,
      )
      if size != base + count * stride {
        object_reject(
          "OB001", pos, "Mach-O segment section count does not match command size",
        )
      }
      let file_offset = object_number(
        data,
        pos + (if wide { 40 } else { 32 }),
        if wide {
          8
        } else {
          4
        },
        little,
        data.length(),
      )
      ignore(
        object_number(
          data,
          pos + (if wide { 48 } else { 36 }),
          if wide {
            8
          } else {
            4
          },
          little,
          data.length() - file_offset,
        ),
      )
      for n = 0; n < count; n = n + 1 {
        let section = pos + base + n * stride
        let flags = object_tag(
          data,
          section + (if wide { 64 } else { 56 }),
          little,
        )
        let kind = flags & 255U
        sections_no_toc.push((flags & 0x40000000U) != 0U)
        if kind != 1U && kind != 12U && kind != 18U {
          let offset = object_number(
            data,
            section + (if wide { 48 } else { 40 }),
            4,
            little,
            data.length(),
          )
          ignore(
            object_number(
              data,
              section + (if wide { 40 } else { 36 }),
              if wide {
                8
              } else {
                4
              },
              little,
              data.length() - offset,
            ),
          )
        }
        let relocation_offset = object_number(
          data,
          section + (if wide { 56 } else { 48 }),
          4,
          little,
          data.length(),
        )
        ignore(
          object_number(
            data,
            section + (if wide { 60 } else { 52 }),
            4,
            little,
            (data.length() - relocation_offset) / 8,
          ),
        )
      }
    }
    pos += size
  }
  if pos != commands_end {
    object_reject("OB001", pos, "Mach-O load commands do not fill sizeofcmds")
  }
  guard symtab is Some((symbol_offset, count, string_offset, string_size)) else {
    return []
  }
  object_charge_symbols(budget, count, symbol_offset)
  object_string_table(data, string_offset, string_size, false)
  let result : Array[Bytes] = []
  let seen : Map[Bytes, Unit] = Map([])
  let stride = if wide { 16 } else { 12 }
  for n = 0; n < count; n = n + 1 {
    let symbol = symbol_offset + n * stride
    let name_index = object_number(data, symbol, 4, little, string_size)
    if name_index != 0 && name_index >= string_size {
      object_reject(
        "OB001", symbol, "Mach-O symbol name index is outside its string table",
      )
    }
    let flags = data[symbol + 4].to_int()
    if (flags & 224) != 0 {
      continue
    }
    let kind = flags & 14
    let section = data[symbol + 5].to_int()
    if kind == 14 {
      if section == 0 || section > sections_no_toc.length() {
        object_reject(
          "OB001", symbol, "Mach-O symbol refers to a missing section",
        )
      }
    } else if section != 0 {
      object_reject(
        "OB001", symbol, "Mach-O non-section symbol must use NO_SECT",
      )
    }
    if (flags & 1) == 0 || name_index == 0 {
      continue
    }
    if (
        kind == 0 && !object_nonzero(data, symbol + 8, if wide { 8 } else { 4 })
      ) ||
      kind == 12 ||
      (kind == 14 && sections_no_toc[section - 1]) {
      continue
    }
    if kind != 0 && kind != 2 && kind != 10 && kind != 14 {
      object_reject("OB002", symbol, "unsupported Mach-O external symbol type")
    }
    if kind == 10 {
      let target = object_number(
        data,
        symbol + 8,
        if wide {
          8
        } else {
          4
        },
        little,
        string_size,
      )
      if target == 0 ||
        target >= string_size ||
        data[string_offset + target] == b'\x00' {
        object_reject(
          "OB001",
          symbol + 8,
          "invalid Mach-O indirect symbol target",
        )
      }
    }
    let name = object_name(data, string_offset, string_size, name_index, budget)
    if seen.get(name) is None {
      seen[name] = ()
      result.push(name)
    }
  }
  result
}

///|
fn object_coff_machine(machine : Int32) -> Bool {
  match machine {
    0x014c
    | 0x8664
    | 0x01c0
    | 0x01c2
    | 0x01c4
    | 0xaa64
    | 0x0200
    | 0x5032
    | 0x5064
    | 0x5128
    | 0x6232
    | 0x6264
    | 0x0184
    | 0x0284
    | 0x01d3
    | 0x0ebc
    | 0x9041
    | 0x0266
    | 0x0366
    | 0x0466
    | 0x01f0
    | 0x01f1
    | 0x0162
    | 0x0166
    | 0x0168
    | 0x0169
    | 0x01a2
    | 0x01a3
    | 0x01a6
    | 0x01a8 => true
    _ => false
  }
}

///|
fn object_coff(
  data : Bytes,
  budget : ObjectBudget,
  big~ : Bool = false,
) -> Array[Bytes] raise InvalidObject {
  let header_size = if big { 56 } else { 20 }
  let symbol_size = if big { 20 } else { 18 }
  let storage_offset = if big { 18 } else { 16 }
  let table_field = if big { 48 } else { 8 }
  let count_field = if big { 52 } else { 12 }
  object_range(data, 0, header_size)
  if !big {
    let optional_size = object_number(data, 16, 2, true, 65535)
    let characteristics = object_number(data, 18, 2, true, 65535)
    if optional_size != 0 || (characteristics & 0x2002) != 0 {
      object_reject(
        "OB002", 16, "symbol discovery requires a relocatable COFF object",
      )
    }
  }
  let section_count = object_number(
    data,
    if big {
      44
    } else {
      2
    },
    if big {
      4
    } else {
      2
    },
    true,
    (data.length() - header_size) / 40,
  )
  if !big && section_count > 65279 {
    object_reject("OB002", 2, "COFF section count requires the bigobj format")
  }
  let section_end = header_size + section_count * 40
  for n = 0; n < section_count; n = n + 1 {
    let section = header_size + n * 40
    let flags = object_tag(data, section + 36, true)
    let raw_offset = object_number(data, section + 20, 4, true, data.length())
    if raw_offset != 0 || (flags & 128U) == 0U {
      let raw_size = object_number(
        data,
        section + 16,
        4,
        true,
        data.length() - raw_offset,
      )
      if raw_size > 0 && raw_offset < section_end {
        object_reject(
          "OB001", section, "COFF section data overlaps the file headers",
        )
      }
    }
    let relocation_offset = object_number(
      data,
      section + 24,
      4,
      true,
      data.length(),
    )
    let relocations = object_number(data, section + 32, 2, true, 65535)
    let relocation_count = if (flags & 0x01000000U) != 0U {
      if relocations != 65535 || relocation_offset < section_end {
        object_reject(
          "OB001", section, "invalid COFF extended relocation count",
        )
      }
      let count = object_number(
        data,
        relocation_offset,
        4,
        true,
        (data.length() - relocation_offset) / 10,
      )
      if count <= 65535 {
        object_reject(
          "OB001", relocation_offset, "COFF relocation overflow marker is unnecessary",
        )
      }
      count
    } else {
      relocations
    }
    if relocation_count > (data.length() - relocation_offset) / 10 ||
      (relocation_count > 0 && relocation_offset < section_end) {
      object_reject(
        "OB001", section, "COFF relocation records extend outside the object",
      )
    }
    let lines_offset = object_number(data, section + 28, 4, true, data.length())
    let lines = object_number(data, section + 34, 2, true, 65535)
    if lines > (data.length() - lines_offset) / 6 ||
      (lines > 0 && lines_offset < section_end) {
      object_reject(
        "OB001", section, "COFF line records extend outside the object",
      )
    }
  }
  let table_offset = object_number(data, table_field, 4, true, data.length())
  let count = object_number(
    data,
    count_field,
    4,
    true,
    (data.length() - table_offset) / symbol_size,
  )
  object_charge_symbols(budget, count, count_field)
  if table_offset == 0 {
    if count != 0 {
      object_reject(
        "OB001", table_field, "COFF symbols lack a symbol-table offset",
      )
    }
    return []
  }
  if table_offset < section_end {
    object_reject(
      "OB001", table_field, "COFF symbol table overlaps the file headers",
    )
  }
  let strings_offset = table_offset + count * symbol_size
  let strings_size = object_number(
    data,
    strings_offset,
    4,
    true,
    data.length() - strings_offset,
  )
  if strings_size < 4 {
    object_reject(
      "OB001", strings_offset, "COFF string table is smaller than its size field",
    )
  }
  if strings_size > 4 {
    object_string_table(data, strings_offset, strings_size, false)
  }
  let result : Array[Bytes] = []
  let seen : Map[Bytes, Unit] = Map([])
  let primary : Map[Int32, Unit] = Map([])
  let weak_targets : Array[(Int32, Int32)] = []
  let mut index = 0
  while index < count {
    primary[index] = ()
    let pos = table_offset + index * symbol_size
    let auxiliary_count = data[pos + storage_offset + 1].to_int()
    if auxiliary_count > count - index - 1 {
      object_reject(
        "OB001",
        pos + storage_offset + 1,
        "COFF auxiliary records exceed the symbol table",
      )
    }
    let section_tag = if big {
      object_tag(data, pos + 12, true)
    } else {
      object_number(data, pos + 12, 2, true, 65535).reinterpret_as_uint()
    }
    let section = if section_tag == (if big { 0xffffffffU } else { 65535U }) {
      -1
    } else if section_tag == (if big { 0xfffffffeU } else { 65534U }) {
      -2
    } else {
      let number = object_number(
        data,
        pos + 12,
        if big {
          4
        } else {
          2
        },
        true,
        section_count,
      )
      if !big && number > 65279 {
        object_reject("OB001", pos + 12, "reserved COFF section number")
      }
      number
    }
    let storage = data[pos + storage_offset].to_int()
    let common = section == 0 && object_nonzero(data, pos + 8, 4)
    let mut exported = (storage == 2 || storage == 5) &&
      (common || (section != 0 && section != -2))
    if storage == 105 {
      if auxiliary_count != 1 || section != 0 || common {
        object_reject("OB001", pos, "invalid COFF weak-external symbol record")
      }
      let target = object_number(data, pos + symbol_size, 4, true, count - 1)
      weak_targets.push((target, pos + symbol_size))
      let search = object_number(
        data,
        pos + symbol_size + 4,
        4,
        true,
        2147483647,
      )
      if search < 1 || search > 4 {
        object_reject(
          "OB002",
          pos + symbol_size + 4,
          "unsupported COFF weak-external search mode",
        )
      }
      exported = search == 3
    }
    let name = if !object_nonzero(data, pos, 4) {
      let name_index = object_number(data, pos + 4, 4, true, strings_size)
      if name_index < 4 || name_index >= strings_size {
        object_reject(
          "OB001",
          pos + 4,
          "COFF symbol name index is outside its string table",
        )
      }
      if exported {
        Some(
          object_name(data, strings_offset, strings_size, name_index, budget),
        )
      } else {
        None
      }
    } else if exported {
      let mut length = 0
      while length < 8 && data[pos + length] != b'\x00' {
        length += 1
      }
      if length == 0 {
        object_reject("OB001", pos, "empty COFF external symbol name")
      }
      if length > budget.names_left {
        object_reject("OB003", pos, "expanded symbol-name byte limit exceeded")
      }
      budget.names_left -= length
      Some(data[pos:pos + length].to_owned())
    } else {
      None
    }
    if name is Some(name) && seen.get(name) is None {
      seen[name] = ()
      result.push(name)
    }
    index += 1 + auxiliary_count
  }
  for (target, pos) in weak_targets {
    if primary.get(target) is None {
      object_reject(
        "OB001", pos, "COFF weak target refers to an auxiliary record",
      )
    }
    let storage = data[table_offset + target * symbol_size + storage_offset].to_int()
    if storage != 2 && storage != 5 && storage != 105 {
      object_reject(
        "OB001", pos, "COFF weak target must refer to an external symbol",
      )
    }
  }
  result
}

///|
fn object_discover(
  data : Bytes,
  budget : ObjectBudget,
) -> Array[Bytes] raise InvalidObject {
  if data.length() < 4 {
    if data.length() > 0 && data[0] == b'\x7f' {
      object_reject("OB001", 0, "truncated ELF magic")
    }
    return []
  }
  let magic = data[:4]
  if magic == b"\x7fELF"[:] {
    return object_native_definitions(object_elf(data, budget))
  }
  if magic == b"\xce\xfa\xed\xfe"[:] {
    return object_native_definitions(object_macho(data, false, true, budget))
  }
  if magic == b"\xcf\xfa\xed\xfe"[:] {
    return object_native_definitions(object_macho(data, true, true, budget))
  }
  if magic == b"\xfe\xed\xfa\xce"[:] {
    return object_native_definitions(object_macho(data, false, false, budget))
  }
  if magic == b"\xfe\xed\xfa\xcf"[:] {
    return object_native_definitions(object_macho(data, true, false, budget))
  }
  if magic == b"\x00\x00\xff\xff"[:] {
    return object_coff_anonymous(data, budget)
  }
  if magic == b"BC\xc0\xde"[:] || magic == b"\xde\xc0\x17\x0b"[:] {
    return object_bitcode(data, budget)
  }
  let coff_machine = data[0].to_int() + data[1].to_int() * 256
  if object_coff_machine(coff_machine) {
    return object_native_definitions(object_coff(data, budget))
  }
  if magic == b"\xca\xfe\xba\xbe"[:] ||
    magic == b"\xbe\xba\xfe\xca"[:] ||
    magic == b"\xca\xfe\xba\xbf"[:] ||
    magic == b"\xbf\xba\xfe\xca"[:] ||
    magic == b"\x00asm"[:] ||
    coff_machine == 0x0160 ||
    coff_machine == 0xa641 ||
    coff_machine == 0xa64e ||
    data[:2] == b"MZ"[:] ||
    (
      data.length() >= 8 &&
      (data[:8] == b"!<arch>\n"[:] || data[:8] == b"!<thin>\n"[:])
    ) {
    object_reject(
      "OB002", 0, "object container or format is not supported for symbol discovery",
    )
  }
  []
}

///|
fn object_native_definitions(
  names : Array[Bytes],
) -> Array[Bytes] raise InvalidObject {
  if names.contains(b"__gnu_lto_slim") || names.contains(b"___gnu_lto_slim") {
    object_reject(
      "OB002", 0, "GCC slim LTO requires plugin symbol discovery; use a fat object or explicit symbol mappings",
    )
  }
  names
}

///|
/// Discover archive-index names from relocatable ELF, Mach-O and COFF objects.
/// ELF32/64 and Mach-O32/64 accept both byte orders. Defined external, weak,
/// common and absolute symbols are included; undefined/local/debug symbols
/// are omitted. Duplicate names within one object retain their first position.
/// Standard little-endian COFF includes weak aliases and skips auxiliary records.
/// Bigobj, short import objects and LLVM bitcode with an embedded version-3
/// symbol table are supported. Bitcode wrappers and module groups are decoded
/// without constructing IR. Executable images and universal objects are rejected.
/// GCC slim LTO requires explicit mappings or plugin symbol discovery.
/// Ordinary data returns an empty array; recognized unsupported object formats
/// and malformed supported objects return an error.
/// max_symbols counts inspected symbol-table entries, including filtered entries.
/// max_symbol_name_bytes counts expanded discovered names before deduplication.
pub fn symbols_from_object(
  data : Bytes,
  max_symbols~ : Int32 = 1000000,
  max_symbol_name_bytes~ : Int32 = 67108864,
) -> Result[Array[Bytes], ObjectError] {
  if max_symbols < 0 || max_symbol_name_bytes < 0 {
    return Err({
      code: "OB003",
      offset: 0,
      message: "object discovery limits must not be negative",
    })
  }
  Ok(
    object_discover(data, {
      symbols_left: max_symbols,
      names_left: max_symbol_name_bytes,
    }),
  ) catch {
    InvalidObject(error) => Err(error)
  }
}

///|
/// Discover fresh symbol targets after editing. Budgets are shared by all
/// members. WR006 includes the failing member position and object error offset.
pub fn ArchiveBuilder::discover_symbols(
  self : ArchiveBuilder,
  max_symbols~ : Int32 = 1000000,
  max_symbol_name_bytes~ : Int32 = 67108864,
) -> Result[Array[WriteSymbol], WriteError] {
  if max_symbols < 0 || max_symbol_name_bytes < 0 {
    return Err({
      code: "WR003",
      member_index: None,
      message: "object discovery limits must not be negative",
    })
  }
  let budget : ObjectBudget = {
    symbols_left: max_symbols,
    names_left: max_symbol_name_bytes,
  }
  let result : Array[WriteSymbol] = []
  for member_index, entry in self.members {
    let names = object_discover(entry.data, budget) catch {
      InvalidObject(error) =>
        return Err({
          code: if error.code == "OB003" {
            "WR003"
          } else {
            "WR006"
          },
          member_index: Some(member_index),
          message: "\{error.code} at object byte \{error.offset}: \{error.message}",
        })
    }
    for name in names {
      result.push({ name, member_index, })
    }
  }
  Ok(result)
}
