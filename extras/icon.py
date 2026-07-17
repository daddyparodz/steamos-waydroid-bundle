#!/usr/bin/env python3
"""Keep this installer's non-Steam shortcuts unique and apply local artwork."""

import argparse
import os
import re
import shutil
import struct
import sys
import tempfile
import zlib
from pathlib import Path


TARGETS = {
    "waydroid": {
        "name": "Waydroid",
        "executables": ("Android_Waydroid_Cage.sh",),
    },
    "nested-desktop": {
        "name": "steamos-nested-desktop",
        "executables": ("/usr/bin/steamos-nested-desktop", "steamos-nested-desktop"),
    },
}


def read_cstring(fp):
    chars = []
    while (char := fp.read(1)) and char != b"\x00":
        chars.append(char)
    return b"".join(chars).decode("utf-8", errors="replace")


def parse_binary_vdf(fp):
    stack = [{}]
    while True:
        value_type = fp.read(1)
        if not value_type:
            break
        if value_type == b"\x08":
            if len(stack) > 1:
                stack.pop()
                continue
            break

        key = read_cstring(fp)
        current = stack[-1]
        if value_type == b"\x00":
            child = {}
            current[key] = child
            stack.append(child)
        elif value_type == b"\x01":
            current[key] = read_cstring(fp)
        elif value_type == b"\x02":
            current[key] = struct.unpack("<i", fp.read(4))[0]
        elif value_type == b"\x03":
            current[key] = struct.unpack("<f", fp.read(4))[0]
        elif value_type == b"\x07":
            current[key] = struct.unpack("<Q", fp.read(8))[0]
        elif value_type == b"\x0A":
            current[key] = struct.unpack("<q", fp.read(8))[0]
        else:
            raise ValueError(f"unknown VDF type {value_type!r} for key {key!r}")
    return stack[0]


def write_cstring(fp, value):
    fp.write(value.encode("utf-8") + b"\x00")


def write_binary_vdf(fp, values):
    for key, value in values.items():
        if isinstance(value, dict):
            fp.write(b"\x00")
            write_cstring(fp, key)
            write_binary_vdf(fp, value)
            fp.write(b"\x08")
        elif isinstance(value, str):
            fp.write(b"\x01")
            write_cstring(fp, key)
            write_cstring(fp, value)
        elif isinstance(value, int):
            fp.write(b"\x02")
            write_cstring(fp, key)
            fp.write(struct.pack("<i", value))
        elif isinstance(value, float):
            fp.write(b"\x03")
            write_cstring(fp, key)
            fp.write(struct.pack("<f", value))
        else:
            raise ValueError(f"unsupported value type {type(value)} for {key!r}")


def most_recent_steam_id(home):
    login_paths = (
        home / ".steam/root/config/loginusers.vdf",
        home / ".local/share/Steam/config/loginusers.vdf",
    )
    for login_path in login_paths:
        if not login_path.is_file():
            continue
        content = login_path.read_text(encoding="utf-8", errors="ignore")
        matches = re.findall(r'"(\d{17})"\s*\{([^}]+)}', content)
        candidates = []
        for steam_id64, block in matches:
            timestamp_match = re.search(r'"Timestamp"\s+"(\d+)"', block)
            timestamp = int(timestamp_match.group(1)) if timestamp_match else 0
            most_recent = bool(re.search(r'"MostRecent"\s+"1"', block))
            candidates.append((most_recent, timestamp, int(steam_id64)))
        if candidates:
            steam_id64 = max(candidates)[2]
            return steam_id64 - 76561197960265728
    return None


def shortcuts_path(home):
    steam_id3 = most_recent_steam_id(home)
    if steam_id3 is not None:
        return home / f".steam/root/userdata/{steam_id3}/config/shortcuts.vdf"

    # Fallback for a Deck with a usable shortcuts file but stale login metadata.
    candidates = list((home / ".steam/root/userdata").glob("*/config/shortcuts.vdf"))
    if candidates:
        return max(candidates, key=lambda path: path.stat().st_mtime)
    return None


def field(shortcut, name, default=""):
    wanted = name.casefold()
    for key, value in shortcut.items():
        if key.casefold() == wanted:
            return value
    return default


def is_target(shortcut, target):
    definition = TARGETS[target]
    app_name = str(field(shortcut, "AppName")).casefold()
    executable = str(field(shortcut, "Exe")).replace("\\", "/").casefold()
    if app_name == definition["name"].casefold():
        return True
    return any(candidate.casefold() in executable for candidate in definition["executables"])


def load_shortcuts(path):
    with path.open("rb") as fp:
        data = parse_binary_vdf(fp)
    shortcuts = data.get("shortcuts", data)
    if not isinstance(shortcuts, dict):
        raise ValueError("shortcuts.vdf has no shortcuts dictionary")
    return data, shortcuts


def matching_shortcuts(path, target):
    if path is None or not path.is_file():
        return []
    _, shortcuts = load_shortcuts(path)
    return [shortcut for shortcut in shortcuts.values()
            if isinstance(shortcut, dict) and is_target(shortcut, target)]


def write_shortcuts(path, data, shortcuts):
    compacted = {str(index): shortcut for index, shortcut in enumerate(shortcuts)}
    if "shortcuts" in data:
        data["shortcuts"] = compacted
    else:
        data = compacted

    backup = path.with_suffix(path.suffix + ".waydroid-backup")
    if not backup.exists():
        shutil.copy2(path, backup)
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as fp:
        temporary = Path(fp.name)
        write_binary_vdf(fp, data)
        fp.write(b"\x08")
        fp.flush()
        os.fsync(fp.fileno())
    temporary.chmod(mode)
    temporary.replace(path)


def shortcut_app_id(shortcut):
    stored = field(shortcut, "appid", None)
    if isinstance(stored, int):
        return stored & 0xFFFFFFFF
    executable = str(field(shortcut, "Exe"))
    app_name = str(field(shortcut, "AppName"))
    return (zlib.crc32((executable + app_name).encode("utf-8")) | 0x80000000) & 0xFFFFFFFF


def install_artwork(path, shortcut, artwork, icon):
    app_id = shortcut_app_id(shortcut)
    grid = path.parent / "grid"
    grid.mkdir(parents=True, exist_ok=True)

    # Steam's non-Steam artwork names: landscape, portrait and hero.
    for suffix in ("", "p", "_hero"):
        destination = grid / f"{app_id}{suffix}{artwork.suffix.lower()}"
        shutil.copy2(artwork, destination)
    if icon and icon.is_file():
        shutil.copy2(icon, grid / f"{app_id}_icon{icon.suffix.lower()}")
        shutil.copy2(icon, grid / f"{app_id}_logo{icon.suffix.lower()}")
    print(f"Installed local Steam artwork for app {app_id} in {grid}")


def reconcile(home, path, target, artwork=None, icon=None):
    if path is None or not path.is_file():
        print("No shortcuts.vdf found; add the shortcut first.", file=sys.stderr)
        return 1

    data, shortcuts_dict = load_shortcuts(path)
    shortcuts = [value for value in shortcuts_dict.values() if isinstance(value, dict)]
    matches = [shortcut for shortcut in shortcuts if is_target(shortcut, target)]
    if not matches:
        print(f"No {target} Steam shortcut found.", file=sys.stderr)
        return 1

    primary = matches[0]
    definition = TARGETS[target]
    primary["AppName"] = definition["name"]
    if target == "waydroid" and icon and icon.is_file():
        primary["icon"] = str(icon)

    duplicate_ids = {id(shortcut) for shortcut in matches[1:]}
    retained = [shortcut for shortcut in shortcuts if id(shortcut) not in duplicate_ids]
    write_shortcuts(path, data, retained)

    removed = len(matches) - 1
    print(f"Kept one {target} Steam shortcut; removed {removed} duplicate(s).")
    if target == "waydroid" and artwork and artwork.is_file():
        install_artwork(path, primary, artwork, icon)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("has", "reconcile"), nargs="?", default="reconcile")
    parser.add_argument("target", choices=tuple(TARGETS), nargs="?", default="waydroid")
    parser.add_argument("--artwork", type=Path)
    parser.add_argument("--icon", type=Path,
                        default=Path("/usr/share/icons/hicolor/512x512/apps/waydroid.png"))
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args()

    path = shortcuts_path(args.home)
    if args.action == "has":
        return 0 if matching_shortcuts(path, args.target) else 1
    return reconcile(args.home, path, args.target, args.artwork, args.icon)


if __name__ == "__main__":
    sys.exit(main())
