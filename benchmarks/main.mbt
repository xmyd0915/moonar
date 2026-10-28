///|
extern "C" fn peak_rss_bytes() -> Double = "moonar_benchmark_peak_rss"

///|
extern "C" fn memory_probe() -> Double = "moonar_benchmark_memory_probe"

///|
fn[T] parsed(value : Result[T, @ar.ParseError]) -> T raise {
  match value {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
fn[T] written(value : Result[T, @ar.WriteError]) -> T raise {
  match value {
    Ok(value) => value
    Err(error) => fail("\{error.code}: \{error.message}")
  }
}

///|
fn number(value : String, low : Int, high : Int) -> Int raise {
  let mut result = 0
  if value.is_empty() {
    fail("empty benchmark parameter")
  }
  for c in value.iter() {
    let digit = c.to_int() - 48
    if digit < 0 || digit > 9 || result > (high - digit) / 10 {
      fail("benchmark parameter is outside its permitted range")
    }
    result = result * 10 + digit
  }
  if result < low || result > high {
    fail("benchmark parameter is outside its permitted range")
  }
  result
}

///|
struct Workload {
  run : () -> Int raise
  input_bytes : Int
}

///|
fn fixture(
  count : Int,
  size : Int,
  duplicate : Bool,
) -> @ar.ArchiveBuilder raise {
  written(
    @ar.ArchiveBuilder::from_members(
      Array::makei(count, fn(i) {
        let data = Bytes::makei(size, fn(j) {
          if j < 4 {
            ((i >> (j * 8)) & 255).to_byte()
          } else {
            ((i + j) % 251).to_byte()
          }
        })
        @ar.WriteMember::new(
          if duplicate {
            b"same.o"
          } else {
            @utf8.encode("file\{i}.o")
          },
          data,
        )
      }),
    ),
  )
}

///|
fn regular_workload(kind : String, count : Int, size : Int) -> Workload raise {
  let builder = fixture(count, size, kind == "duplicate_compare")
  let data = written(builder.write())
  let archive = parsed(@ar.parse(data))
  assert_eq(archive.member_count(), count)
  let run = match kind {
    "parse" =>
      fn() raise {
        let result = parsed(@ar.parse(data))
        assert_eq(result.member_count(), count)
        result.member_count()
      }
    "edit" => {
      let replacement = @ar.WriteMember::new(
        b"changed.o",
        Bytes::make(size, b'\xff'),
      )
      let operation = fn() raise {
        let edited = written(archive.edit())
        let edited = written(edited.replace(count / 2, replacement))
        let edited = written(edited.move_member(0, count - 1))
        written(edited.write())
      }
      let check = parsed(@ar.parse(operation()))
      assert_eq(check.member_count(), count)
      assert_eq(check.member_bytes(count / 2 - 1), Some(replacement.data))
      assert_eq(check.get_member(count - 1).unwrap().name, b"file0.o")
      fn() raise { operation().length() }
    }
    "duplicate_compare" => {
      let entries = builder.members()
      let reversed = Array::makei(count, fn(i) { entries[count - i - 1] })
      reversed[count / 2] = @ar.WriteMember::new(
        b"same.o",
        Bytes::make(size, b'\xff'),
      )
      let after = parsed(
        @ar.parse(
          written(written(@ar.ArchiveBuilder::from_members(reversed)).write()),
        ),
      )
      fn() raise {
        let result = @ar.compare_logical(archive, after)
        assert_false(result.content_equal)
        assert_true(result.order_changed && result.ambiguities.is_empty())
        assert_eq(result.changes.length(), 1)
        result.changes.length()
      }
    }
    _ => fail("unknown regular benchmark")
  }
  {
    run,
    input_bytes: data.length() *
    (if kind == "duplicate_compare" { 2 } else { 1 }),
  }
}

///|
fn nested_workload(
  kind : String,
  count : Int,
  depth : Int,
  size : Int,
) -> Workload raise {
  let base = written(fixture(count, size, false).write())
  let ordinary = parsed(@ar.parse(base))
  let files : Map[Bytes, Bytes] = Map([])
  let mut previous = base
  let mut offsets = Array::makei(count, fn(i) {
    ordinary.get_member(i).unwrap().header_offset
  })
  let mut total = base.length()
  for level = 0; level < depth; level = level + 1 {
    let name = @utf8.encode("container-\{level}.a")
    files[name] = previous
    let entries = offsets.map(fn(offset) {
      @ar.ThinWriteMember::new(name, size, archive_member_offset=Some(offset))
    })
    previous = written(
      written(@ar.ThinArchiveBuilder::from_members(entries)).write(),
    )
    total += previous.length()
    let thin = parsed(@ar.parse_thin(previous))
    offsets = []
    for i = 0; i < thin.member_count(); i = i + 1 {
      let entry = thin.get_member(i).unwrap()
      if entry.kind == @ar.Regular {
        offsets.push(entry.header_offset)
      }
    }
    assert_eq(offsets.length(), count)
  }
  let thin = parsed(@ar.parse_thin(previous))
  let mut calls = 0
  let loader = fn(path, _) {
    calls += 1
    match files.get(path) {
      Some(data) => Ok(data)
      None => Err("unexpected benchmark dependency")
    }
  }
  let limits = @ar.NestedLimits::new(
    max_depth=depth,
    max_members=(count + 1) * depth,
  )
  let expected = ordinary.snapshot()
  let snapshot = parsed(thin.snapshot(loader, nested_limits=limits))
  let check = snapshot.compare_logical(expected)
  assert_true(
    check.content_equal && check.symbols_equal && !check.order_changed,
  )
  assert_eq(calls, depth)
  if kind == "nested_materialize" {
    let packed = parsed(thin.materialize(loader, nested_limits=limits))
    assert_eq(written(packed.write()), base)
  }
  let run = fn() raise {
    calls = 0
    let result = match kind {
      "nested_validate" => {
        let total = parsed(thin.validate_members(loader, nested_limits=limits))
        assert_eq(total, count * size)
        total
      }
      "nested_materialize" => {
        let builder = parsed(thin.materialize(loader, nested_limits=limits))
        assert_eq(builder.member_count(), count)
        written(builder.write()).length()
      }
      "nested_compare" => {
        let value = parsed(thin.snapshot(loader, nested_limits=limits)).compare_logical(
          expected,
        )
        assert_true(
          value.content_equal && value.symbols_equal && !value.order_changed,
        )
        count
      }
      _ => fail("unknown nested benchmark")
    }
    assert_eq(calls, depth)
    result
  }
  { run, input_bytes: total, }
}

///|
fn execute(args : Array[String]) -> Unit raise {
  if args.length() == 2 && args[1] == "--memory-probe" {
    println(
      Json::object({
        "probe_bytes": Json(67108864),
        "peak_rss_bytes": Json(memory_probe()),
      }).stringify(),
    )
    return
  }
  if args.length() != 6 {
    fail("Usage: benchmarks CASE MEMBERS DEPTH ITERATIONS PAYLOAD_BYTES")
  }
  let kind = args[1]
  let count = number(args[2], 3, 10000)
  let depth = number(args[3], 1, 16)
  let iterations = number(args[4], 1, 1000)
  let size = number(args[5], 4, 4096)
  let work = if kind.has_prefix("nested_") {
    nested_workload(kind, count, depth, size)
  } else {
    regular_workload(kind, count, size)
  }
  let expected = (work.run)()
  let start = @bench.monotonic_clock_start()
  let mut checksum = 0L
  for i = 0; i < iterations; i = i + 1 {
    let value = (work.run)()
    assert_eq(value, expected)
    checksum += value.to_int64()
  }
  let elapsed = @bench.monotonic_clock_end(start)
  let peak = peak_rss_bytes()
  if peak <= 0.0 || elapsed <= 0.0 {
    fail("host metrics are unavailable")
  }
  println(
    Json::object({
      "case": Json(kind),
      "members": Json(count),
      "depth": Json(depth),
      "iterations": Json(iterations),
      "payload_bytes": Json(size),
      "input_bytes": Json(work.input_bytes),
      "elapsed_us": Json(elapsed),
      "peak_rss_bytes": Json(peak),
      "checksum": Json(checksum.to_string()),
    }).stringify(),
  )
}

///|
fn main {
  execute(@env.args()) catch {
    error => {
      eprintln(error)
      @sys.exit(2)
    }
  }
}
