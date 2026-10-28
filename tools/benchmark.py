"""Measure checked MoonAr workloads using a release native driver.

Each sample is a new process. The driver times only warmed in-memory operations;
OS peak resident memory includes runtime, fixture setup, warmup and measurements.
No performance threshold is inferred from shared CI hardware.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess


REGULAR = ("parse", "edit", "duplicate_compare", "unique_compare")
NESTED = ("nested_validate", "nested_materialize", "nested_compare")


def run(args, cwd):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, capture_output=True, timeout=180)
    if result.returncode:
        raise AssertionError((args, result.returncode, result.stdout.decode(errors="replace"),
                              result.stderr.decode(errors="replace")))
    return result.stdout.decode("utf-8")


def bounded_list(value, low, high):
    try:
        numbers = [int(item) for item in value.split(",")]
    except ValueError as error:
        raise argparse.ArgumentTypeError("use comma-separated integers") from error
    if not numbers or len(set(numbers)) != len(numbers) or any(n < low or n > high for n in numbers):
        raise argparse.ArgumentTypeError(f"use distinct integers from {low} to {high}")
    return numbers


def validate_sample(sample, case, members, depth, iterations, payload):
    expected = {"case": case, "members": members, "depth": depth,
                "iterations": iterations, "payload_bytes": payload}
    if any(sample.get(key) != value for key, value in expected.items()):
        raise AssertionError(("driver workload differs from request", expected, sample))
    for key in ("elapsed_us", "peak_rss_bytes", "input_bytes"):
        value = sample.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise AssertionError(("invalid measurement", key, value))
    checksum = sample.get("checksum")
    if not isinstance(checksum, str) or not checksum.isdecimal() or int(checksum) <= 0:
        raise AssertionError(("invalid operation checksum", checksum))


def markdown(report):
    lines = ["# MoonAr native benchmark", "",
             f"Version: {report['version']}; revision: {report['revision']}; source modified: {report['source_modified']}.",
             f"Host: {report['platform']} / {report['architecture']}; CPU: {report['processor']}.", "",
             "Times are medians of process samples, in milliseconds per operation. Each sample uses one warmup.",
             "Peak RSS is the largest process lifetime resident-memory peak across samples, including setup and warmup.",
             "Results depend on host, compiler and workload; no cross-host speed claim is implied.", "",
             "| Case | Members | Depth | Input bytes | Median ms | Min ms | Max ms | Peak MiB |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report["results"]:
        lines.append(f"| {row['case']} | {row['members']} | {row['depth']} | {row['input_bytes']} | "
                     f"{row['median_us'] / 1000:.3f} | {row['min_us'] / 1000:.3f} | "
                     f"{row['max_us'] / 1000:.3f} | {row['peak_rss_bytes'] / 1048576:.2f} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", default=shutil.which("moon"))
    parser.add_argument("--benchmark", type=Path, help="use an already-built driver (build profile is caller-provided)")
    parser.add_argument("--cases", nargs="+", choices=REGULAR + NESTED,
                        help="run only the selected workloads (default: all)")
    parser.add_argument("--sizes", type=lambda s: bounded_list(s, 3, 10000), default=[100, 1000, 10000])
    parser.add_argument("--depths", type=lambda s: bounded_list(s, 1, 16), default=[1, 4, 16])
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--payload-bytes", type=int, default=128)
    parser.add_argument("--report", type=Path, default=Path("_build/verification/benchmark.json"))
    args = parser.parse_args()
    if not args.moon:
        parser.error("MoonBit's moon executable is required")
    if not 1 <= args.samples <= 20 or not 1 <= args.iterations <= 1000 or not 4 <= args.payload_bytes <= 4096:
        parser.error("samples: 1..20; iterations: 1..1000; payload-bytes: 4..4096")
    root = Path(__file__).resolve().parent.parent
    if args.benchmark:
        exe = args.benchmark.resolve(strict=True)
    else:
        print(run([args.moon, "build", "benchmarks", "--target", "native", "--release", "--deny-warn"], root).strip())
        exe = root / "_build/native/release/build/benchmarks/benchmarks.exe"
    metadata = (root / "moon.mod").read_text(encoding="utf-8")
    probe = json.loads(run([exe, "--memory-probe"], root))
    if probe.get("probe_bytes") != 67108864 or not 67108864 <= probe.get("peak_rss_bytes", 0) < 1073741824:
        raise AssertionError(("peak resident-memory unit calibration failed", probe))
    revision = run(["git", "rev-parse", "HEAD"], root).strip()
    modified = bool(run(["git", "status", "--porcelain", "--untracked-files=normal"], root).strip())
    report = {
        "schema_version": 1, "version": re.search(r'^version\s*=\s*"([^"]+)"', metadata, re.M).group(1),
        "revision": revision, "source_modified": modified,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "architecture": platform.machine(),
        "processor": platform.processor() or os.environ.get("PROCESSOR_IDENTIFIER", "unspecified"),
        "logical_cpus": os.cpu_count(), "python_version": platform.python_version(),
        "moon_toolchain": run([args.moon, "version", "--all"], root).strip(),
        "driver_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
        "build_profile": "caller-provided" if args.benchmark else "release",
        "cases": [case for case in REGULAR + NESTED if not args.cases or case in args.cases],
        "samples": args.samples, "iterations_per_sample": args.iterations,
        "memory_calibration": probe,
        "warmups_per_sample": 1, "payload_bytes": args.payload_bytes,
        "timing": "monotonic operation loop; excludes fixture setup, process launch and JSON output",
        "memory": "process lifetime peak resident bytes, including runtime, setup and warmup",
        "loader": "in-memory map; cached containers checked once per batch; no filesystem I/O",
        "results": [],
    }
    jobs = [(case, n, 1) for n in args.sizes for case in REGULAR]
    jobs += [(case, n, depth) for n in args.sizes for depth in args.depths for case in NESTED]
    if args.cases:
        jobs = [job for job in jobs if job[0] in args.cases]
    for case, members, depth in jobs:
        samples = []
        for _ in range(args.samples):
            sample = json.loads(run([exe, case, members, depth, args.iterations, args.payload_bytes], root))
            validate_sample(sample, case, members, depth, args.iterations, args.payload_bytes)
            samples.append(sample)
        if len({(s["input_bytes"], s["checksum"]) for s in samples}) != 1:
            raise AssertionError(("workload output changed across samples", samples))
        times = [s["elapsed_us"] / args.iterations for s in samples]
        row = {"case": case, "members": members, "depth": depth,
               "input_bytes": samples[0]["input_bytes"], "median_us": statistics.median(times),
               "min_us": min(times), "max_us": max(times),
               "peak_rss_bytes": max(s["peak_rss_bytes"] for s in samples), "samples": samples}
        report["results"].append(row)
        print(f"PASS {case}: members={members}, depth={depth}, median={row['median_us'] / 1000:.3f} ms, "
              f"peak={row['peak_rss_bytes'] / 1048576:.2f} MiB", flush=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    args.report.with_suffix(".md").write_text(markdown(report), encoding="utf-8")
    print(f"PASS {len(jobs)} workloads; report: {args.report}")


if __name__ == "__main__":
    main()
