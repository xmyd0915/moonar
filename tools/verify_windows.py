"""Verify Microsoft COFF libraries, bigobj and real DLL import consumers.

Runs on Windows with MSVC. No Windows SDK headers or runtime libraries are
needed: fixtures use plain C and explicit entry points without a C runtime.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(args, cwd, expected=0):
    result = subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True,
                            timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
    allowed = expected if isinstance(expected, tuple) else (expected,)
    assert result.returncode in allowed, (args, result.returncode,
        result.stdout.decode(errors="replace"), result.stderr.decode(errors="replace"))
    return result.stdout


def find_msvc(explicit):
    if explicit:
        root = Path(explicit).resolve(strict=True)
    elif shutil.which("cl.exe"):
        root = Path(shutil.which("cl.exe")).resolve().parent
    else:
        locator = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        result = subprocess.run([str(locator), "-latest", "-products", "*", "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-find",
            "VC/Tools/MSVC/*/bin/Hostx64/x64/cl.exe"], capture_output=True, check=True)
        choices = result.stdout.decode("utf-8-sig").strip().splitlines()
        assert choices, "MSVC x64 compiler not found"
        root = Path(choices[-1]).parent
    for name in ("cl.exe", "lib.exe", "link.exe", "dumpbin.exe"):
        assert (root / name).is_file(), name
    return root


def verify(exe, tools, cwd):
    def cli(*args, expected=0):
        return run([exe, *args], cwd, expected)
    def document(path):
        return json.loads(cli("inspect", path, "--json"))
    def compile(source, output, extra=()):
        run([tools / "cl.exe", "/nologo", "/c", "/O2", "/GS-", "/Zl",
             "/Fo" + output, *extra, source], cwd)
    def consume(source, library, name):
        compile(source, name + ".obj")
        run([tools / "link.exe", "/nologo", "/nodefaultlib", "/entry:main",
             "/subsystem:console", "/out:" + name + ".exe", name + ".obj", library], cwd)
        run([cwd / (name + ".exe")], cwd)
    for name, value in (("alpha", 19), ("beta", 23)):
        (cwd / (name + ".c")).write_text(f"int moon_{name}(void) {{ return {value}; }}\n")
    compile("alpha.c", "long_alpha_big_object_member.obj", ("/bigobj",))
    compile("beta.c", "beta.obj")
    run([tools / "lib.exe", "/nologo", "/out:reference.lib",
         "long_alpha_big_object_member.obj", "beta.obj"], cwd)
    ref = document("reference.lib")
    assert ref["symbol_indexes"][0]["format"] == "coff"
    assert len([m for m in ref["members"] if m["kind"] == "symbol_table"]) == 2
    cli("create", "created.lib", "long_alpha_big_object_member.obj", "beta.obj", "--format", "coff")
    cli("index", "reference.lib", "--format", "coff", "--output", "rebuilt.lib")
    delta = json.loads(cli("diff", "reference.lib", "rebuilt.lib", "--logical", "--json", expected=(0, 1)))
    assert delta["content_equal"] and delta["symbols_equal"]
    for library in ("created.lib", "rebuilt.lib"):
        listing = run([tools / "lib.exe", "/nologo", "/list", library], cwd)
        assert b"long_alpha_big_object_member.obj" in listing and b"beta.obj" in listing
        symbols = run([tools / "dumpbin.exe", "/nologo", "/linkermember:2", library], cwd)
        assert b"moon_alpha" in symbols and b"moon_beta" in symbols
    (cwd / "main.c").write_text("int moon_alpha(void); int moon_beta(void); int main(void) { return moon_alpha()+moon_beta()==42 ? 0 : 1; }\n")
    consume("main.c", "created.lib", "static-created")
    consume("main.c", "rebuilt.lib", "static-rebuilt")
    print("PASS MSVC: bigobj symbols, dual linker members, NUL long names and real static link/run")
    (cwd / "alpha.c").write_text("int moon_alpha(void) { return 31; }\n")
    compile("alpha.c", "replacement.obj", ("/bigobj",))
    cli("replace", "created.lib", "0", "replacement.obj", "--format", "coff")
    cli("move", "created.lib", "0", "1", "--format", "coff")
    (cwd / "main.c").write_text("int moon_alpha(void); int moon_beta(void); int main(void) { return moon_alpha()+moon_beta()==54 ? 0 : 1; }\n")
    consume("main.c", "created.lib", "static-edited")
    cli("extract", "created.lib", "1", "extracted.obj")
    assert (cwd / "extracted.obj").read_bytes() == (cwd / "replacement.obj").read_bytes()
    print("PASS MSVC: replacement and reordering rebuild target mappings and change executed behavior")
    run([tools / "link.exe", "/nologo", "/dll", "/noentry", "/nodefaultlib",
         "/export:moon_alpha", "/out:sample.dll", "/implib:imports.lib", "replacement.obj"], cwd)
    imported = document("imports.lib")
    assert imported["symbol_indexes"][0]["format"] == "coff"
    assert all(m["metadata"]["timestamp"] is None for m in imported["members"])
    cli("index", "imports.lib", "--format", "coff", "--output", "rebuilt-imports.lib")
    delta = json.loads(cli("diff", "imports.lib", "rebuilt-imports.lib", "--logical", "--json", expected=(0, 1)))
    assert delta["content_equal"] and delta["symbols_equal"]
    (cwd / "import-main.c").write_text("__declspec(dllimport) int moon_alpha(void); int main(void) { return moon_alpha()==31 ? 0 : 1; }\n")
    consume("import-main.c", "rebuilt-imports.lib", "dll-rebuilt")
    original = (cwd / "rebuilt-imports.lib").read_bytes()
    cli("index", "rebuilt-imports.lib", "--format", "coff", "--max-symbols", "1", expected=2)
    assert (cwd / "rebuilt-imports.lib").read_bytes() == original
    print("PASS MSVC: short-import discovery, unknown timestamps, rebuilt DLL import library and DLL execution")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moonar", required=True)
    parser.add_argument("--msvc-bin")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("this integration check requires Windows and MSVC")
    exe = Path(args.moonar).resolve(strict=True)
    tools = find_msvc(args.msvc_bin)
    parent = Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix="moonar-msvc-") as directory:
        cwd = Path(directory).resolve()
        assert cwd.parent == parent
        verify(exe, tools, cwd)


if __name__ == "__main__":
    main()
