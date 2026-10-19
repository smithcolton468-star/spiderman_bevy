"""Builds roblox_port/build/ from roblox_port/src/: the Luau that runs in Studio and in the CLI tests.

    python roblox_port/tools/build.py [--f32ify PATH] [--luau-src DIR]

- SpiderMan/Traversal/*.luau (the port of crates/sm_traversal) is rewritten by tools/f32ify so every arithmetic
  result is rounded to f32, as the Rust computes it (see f32ify.cpp). Everything else is copied as it is.
- Packaging build/ into Studio (an .rbxmx, or through the Studio MCP) is not written yet: see roblox_port/STATUS.md.

f32ify is a small C++ program over Luau's own parser. Give its path with --f32ify, or a Luau source checkout with
--luau-src (built with CMake: the libLuau.Ast.a and libLuau.Common.a it links against) and it is compiled here.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

PORT = Path(__file__).resolve().parents[1]
SRC = PORT / "src"
OUT = PORT / "build"
F32_DIRS = {"SpiderMan/Traversal"}


def compile_f32ify(luau_src: Path, out: Path) -> Path:
    build = luau_src / "build"
    cmd = [
        "g++", "-std=c++17", "-O2", str(PORT / "tools" / "f32ify.cpp"),
        f"-I{luau_src / 'Ast' / 'include'}", f"-I{luau_src / 'Common' / 'include'}",
        str(build / "libLuau.Ast.a"), str(build / "libLuau.Common.a"), "-o", str(out),
    ]
    subprocess.run(cmd, check=True)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--f32ify", type=Path)
    ap.add_argument("--luau-src", type=Path)
    args = ap.parse_args()
    f32ify = args.f32ify
    if f32ify is None:
        if args.luau_src is None:
            sys.exit("give --f32ify or --luau-src")
        f32ify = compile_f32ify(args.luau_src, PORT / "tools" / "f32ify")
    if OUT.exists():
        shutil.rmtree(OUT)
    count = rewritten = 0
    for f in sorted(SRC.rglob("*")):
        if f.is_dir():
            continue
        rel = f.relative_to(SRC)
        dst = OUT / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if f.suffix == ".luau" and rel.parent.as_posix() in F32_DIRS:
            subprocess.run([str(f32ify), str(f), str(dst)], check=True)
            rewritten += 1
        else:
            shutil.copyfile(f, dst)
        count += 1
    print(f"build: {count} files ({rewritten} rewritten to f32) in {OUT}")


if __name__ == "__main__":
    main()
