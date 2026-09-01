#!/usr/bin/env python3

"""Make Android TV's non-clickable top tabs usable with touch and mouse."""

import os
from pathlib import Path
import subprocess
import threading
import time

import gi
import cairo

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402


LAUNCHER_PACKAGE = "com.google.android.tvlauncher"
KWIN_INPUT_Y_OFFSET = 28
TABS = {
    "Home": (201, 38, 97, 42, 0),
    "Discover": (298, 38, 124, 42, 1),
    "Apps": (422, 38, 89, 42, 2),
}
SCRIPT_DIR = Path(__file__).resolve().parent
ADB = next(
    (
        candidate
        for candidate in (
            SCRIPT_DIR / "platform-tools" / "adb",
            Path("/tmp/waydroid-adb/platform-tools/adb"),
        )
        if candidate.is_file() and os.access(candidate, os.X_OK)
    ),
    None,
)
ADB_SERIAL = ""
ADB_SERVER_PORT = "5038"


def waydroid_status() -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["waydroid", "status"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=5,
    )


def adb_command(*arguments: str) -> subprocess.CompletedProcess[str]:
    if ADB is None or not ADB_SERIAL:
        return subprocess.CompletedProcess([], 1, "", "")
    environment = os.environ.copy()
    key = SCRIPT_DIR / "adbkey"
    if key.is_file():
        environment["ADB_VENDOR_KEYS"] = str(key)
    return subprocess.run(
        [str(ADB), "-P", ADB_SERVER_PORT, "-s", ADB_SERIAL, *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=5,
        env=environment,
    )


def select_tab(right_presses: int) -> None:
    # Home always returns focus to the launcher's content. Two Up presses move
    # it to the Home tab; focus changes switch Android TV tabs immediately.
    adb_command("shell", "input", "keyevent", "3")
    time.sleep(1)
    keycodes = ["19", "19"] + ["22"] * right_presses
    for keycode in keycodes:
        adb_command("shell", "input", "keyevent", keycode)
        time.sleep(0.3)


def forward_pointer(start: tuple[int, int], end: tuple[int, int], duration_ms: int) -> None:
    if (
        abs(end[0] - start[0]) < 10
        and abs(end[1] - start[1]) < 10
        and duration_ms < 500
    ):
        adb_command("shell", "input", "tap", str(end[0]), str(end[1]))
    else:
        adb_command(
            "shell",
            "input",
            "swipe",
            str(start[0]),
            str(start[1]),
            str(end[0]),
            str(end[1]),
            str(max(duration_ms, 50)),
        )


class TouchNav:
    def __init__(self) -> None:
        self.window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.window.set_title("Waydroid Touch Navigation")
        self.window.set_decorated(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        self.window.set_keep_above(True)
        self.window.set_accept_focus(True)
        self.window.set_default_size(1280, 800)
        self.window.set_app_paintable(True)
        screen = self.window.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.window.set_visual(visual)
        self.window.connect("draw", self.draw_transparent)
        self.window.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
            | Gdk.EventMask.TOUCH_MASK
        )
        self.window.connect("button-press-event", self.pointer_pressed)
        self.window.connect("button-release-event", self.pointer_released)
        self.window.connect("touch-event", self.touch_event)
        self.window.connect("scroll-event", self.scroll_event)
        self.pointer_start: tuple[int, int, float] | None = None
        self.touch_start: tuple[int, int, float] | None = None

        GLib.timeout_add_seconds(1, self.update_visibility)
        self.update_visibility()

    @staticmethod
    def activate_tab(right_presses: int) -> None:
        threading.Thread(target=select_tab, args=(right_presses,), daemon=True).start()

    @staticmethod
    def draw_transparent(_window: Gtk.Window, context: cairo.Context) -> bool:
        context.set_operator(cairo.OPERATOR_SOURCE)
        context.set_source_rgba(0, 0, 0, 0.01)
        context.paint()
        return False

    @staticmethod
    def is_tab_coordinate(x: int, y: int) -> bool:
        return any(
            tab_x <= x < tab_x + width and tab_y <= y < tab_y + height
            for tab_x, tab_y, width, height, _right_presses in TABS.values()
        )

    def android_coordinates(self, event: Gdk.EventButton) -> tuple[int, int]:
        # GTK's client-side shadow is part of KWin's 1280x800 frame but not its
        # widget allocation. Translate widget events back to Android pixels.
        x_offset = max(0, (1280 - self.window.get_allocated_width()) // 2)
        source = event.get_source_device().get_source()
        mouse_offset = KWIN_INPUT_Y_OFFSET if source == Gdk.InputSource.MOUSE else 0
        y_offset = max(0, 800 - self.window.get_allocated_height()) + mouse_offset
        return round(event.x + x_offset), round(event.y + y_offset)

    def pointer_pressed(self, _window: Gtk.Window, event: Gdk.EventButton) -> bool:
        if event.button != 1 or event.get_pointer_emulated():
            return True
        x, y = self.android_coordinates(event)
        self.pointer_start = (x, y, time.monotonic())
        return True

    def pointer_released(self, _window: Gtk.Window, event: Gdk.EventButton) -> bool:
        if event.get_pointer_emulated():
            return True
        if event.button == 3:
            threading.Thread(
                target=adb_command,
                args=("shell", "input", "keyevent", "4"),
                daemon=True,
            ).start()
            return True
        if self.pointer_start is None:
            return False
        start_x, start_y, started = self.pointer_start
        self.pointer_start = None
        end = self.android_coordinates(event)
        self.activate_coordinate((start_x, start_y), end, started)
        return True

    @staticmethod
    def scroll_event(_window: Gtk.Window, event: Gdk.EventScroll) -> bool:
        if event.direction == Gdk.ScrollDirection.UP:
            keycode = "19"
        elif event.direction == Gdk.ScrollDirection.DOWN:
            keycode = "20"
        elif event.direction == Gdk.ScrollDirection.LEFT:
            keycode = "21"
        elif event.direction == Gdk.ScrollDirection.RIGHT:
            keycode = "22"
        else:
            _has_deltas, _delta_x, delta_y = event.get_scroll_deltas()
            keycode = "20" if delta_y > 0 else "19"
        threading.Thread(
            target=adb_command,
            args=("shell", "input", "keyevent", keycode),
            daemon=True,
        ).start()
        return True

    def activate_coordinate(
        self, start: tuple[int, int], end: tuple[int, int], started: float
    ) -> None:
        if self.is_tab_coordinate(*end):
            right_presses = next(
                count
                for _x, _y, _width, _height, count in TABS.values()
                if _x <= end[0] < _x + _width and _y <= end[1] < _y + _height
            )
            self.activate_tab(right_presses)
            return
        duration_ms = round((time.monotonic() - started) * 1000)
        threading.Thread(
            target=forward_pointer,
            args=(start, end, duration_ms),
            daemon=True,
        ).start()

    def touch_event(self, _window: Gtk.Window, event: Gdk.EventTouch) -> bool:
        point = (round(event.x), round(event.y))
        if event.type == Gdk.EventType.TOUCH_BEGIN:
            self.touch_start = (*point, time.monotonic())
        elif event.type == Gdk.EventType.TOUCH_END and self.touch_start is not None:
            start_x, start_y, started = self.touch_start
            self.touch_start = None
            self.activate_coordinate((start_x, start_y), point, started)
        elif event.type == Gdk.EventType.TOUCH_CANCEL:
            self.touch_start = None
        return True

    def update_visibility(self) -> bool:
        global ADB_SERIAL
        try:
            status = waydroid_status()
            ip_line = next(
                line for line in status.stdout.splitlines() if line.startswith("IP address:")
            )
            ADB_SERIAL = f"{ip_line.split(':', 1)[1].strip()}:5555"
            environment = os.environ.copy()
            key = SCRIPT_DIR / "adbkey"
            if key.is_file():
                environment["ADB_VENDOR_KEYS"] = str(key)
            subprocess.run(
                [str(ADB), "-P", ADB_SERVER_PORT, "connect", ADB_SERIAL],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                env=environment,
            )
            result = adb_command("shell", "dumpsys", "activity", "activities")
            visible = result.returncode == 0 and LAUNCHER_PACKAGE in result.stdout.split(
                "topResumedActivity=", 1
            )[-1].splitlines()[0]
        except (IndexError, StopIteration, subprocess.TimeoutExpired, TypeError):
            visible = False

        if visible:
            self.window.show_all()
        else:
            self.window.hide()
        return True


if __name__ == "__main__":
    os.environ.setdefault("GDK_BACKEND", "wayland")
    TouchNav()
    Gtk.main()
