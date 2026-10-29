"""Check MoonAr's compiler requirement and record the installed toolchain."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


MINIMUM = (0, 10, 16)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", default=shutil.which("moon"))
    parser.add_argument("--expected-version", help="require an exact compiler version, including build hash")
    parser.add_argument("--report", type=Path, default=Path("_build/verification/toolchain.json"))
    args = parser.parse_args()
    moon = shutil.which(args.moon) if args.moon else None
    if not moon:
        parser.error("MoonBit's moon executable is required")
    root = Path(__file__).resolve().parent.parent
    try:
        result = subprocess.run(
            [moon, "version", "--all"], cwd=root, capture_output=True,
            check=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        parser.error(f"cannot read the installed toolchain: {error}")
    output = result.stdout.decode("utf-8", errors="replace").strip()
    matches = re.findall(r"^moonc v(\d+\.\d+\.\d+(?:\+[A-Za-z0-9.]+)?)(?=\s|$)", output, re.M)
    if len(matches) != 1:
        parser.error("moon version --all did not report one recognized moonc version")
    version = matches[0]
    minimum = ".".join(map(str, MINIMUM))
    if tuple(map(int, version.split("+")[0].split("."))) < MINIMUM:
        parser.error(f"moonc {version} is below the required {minimum}")
    if args.expected_version and version != args.expected_version:
        parser.error(f"moonc {version} differs from the required build {args.expected_version}")
    report = args.report if args.report.is_absolute() else root / args.report
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({
        "compiler_version": version,
        "minimum_compiler_version": minimum,
        "expected_compiler_version": args.expected_version,
        "moon_executable": str(Path(moon).resolve()),
        "toolchain": output,
        "passed": True,
    }, indent=2) + "\n", encoding="utf-8")
    print(f"PASS moonc {version} (minimum {minimum})")


if __name__ == "__main__":
    main()
