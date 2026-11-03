#!/usr/bin/env python3
"""Patch the flutter-create Windows scaffold: name the executable
NaviUpload.exe, title the window "NaviUpload", and install the
NaviUpload app icon."""
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
cmake = ROOT / "windows" / "CMakeLists.txt"
main_cpp = ROOT / "windows" / "runner" / "main.cpp"
icon_src = ROOT / "windows_overlay" / "app_icon.ico"
icon_dst = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

for p in (cmake, main_cpp, icon_src):
    if not p.exists():
        sys.exit(f"missing scaffold file: {p}")
if not icon_dst.parent.exists():
    sys.exit(f"missing scaffold folder: {icon_dst.parent}")

text = cmake.read_text(encoding="utf-8")
text, n = re.subn(r'set\(BINARY_NAME "[^"]*"\)',
                  'set(BINARY_NAME "NaviUpload")', text, count=1)
if n != 1:
    sys.exit("BINARY_NAME not found in windows/CMakeLists.txt")
cmake.write_text(text, encoding="utf-8")

text = main_cpp.read_text(encoding="utf-8")
# Current templates call window.Create(L"…", …); older ones used
# CreateAndShow(L"…", …). Replace just the title string either way.
text, n = re.subn(r'(\bCreate(?:AndShow)?\(L")[^"]*(")',
                  r"\g<1>NaviUpload\g<2>", text, count=1)
if n != 1:
    sys.exit("window title not found in windows/runner/main.cpp")
main_cpp.write_text(text, encoding="utf-8")

shutil.copyfile(icon_src, icon_dst)

print("patched windows scaffold: BINARY_NAME=NaviUpload, "
      "title='NaviUpload', icon installed")
