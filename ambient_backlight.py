#!/usr/bin/env python3
"""
ambient_backlight.py  –  reference / developer script

Reads webcam frames to estimate ambient light and adjusts macOS keyboard
and screen brightness accordingly.

For production use, prefer the native Swift binary in swift/.

Dependencies:
    pip install opencv-python numpy

Keyboard backend (install one):
    brew install kbrightness
    # OR
    brew tap rakalex/mac-brightnessctl && brew install mac-brightnessctl

Screen backend (install one):
    brew install brightness          # built-in display
    # OR
    brew install ddcctl              # external DDC-capable displays

macOS Camera Permission:
    System Settings → Privacy & Security → Camera → grant Terminal/IDE access
"""

import cv2
import numpy as np
import subprocess
import time
import logging
import sys
from dataclasses import dataclass, field
from collections import deque
from typing import Callable, Optional, List, Tuple
import os
import shutil

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Policy (everything the user might want to tune)
# ---------------------------------------------------------------------------

@dataclass
class Settings:
    poll_interval_sec: float = 2.0
    smoothing_window: int = 5
    camera_index: int = 0
    capture_frames: int = 3
    change_threshold: float = 0.02

    keyboard_min: float = 0.0
    keyboard_max: float = 1.0
    invert_keyboard: bool = True    # dark room → brighter keyboard

    screen_min: float = 0.2
    screen_max: float = 1.0
    invert_screen: bool = False     # dark room → dimmer screen

    # Privacy / runtime guard
    max_runtime_sec: float = 3600.0     # 0 = unlimited
    reminder_interval_sec: float = 900.0  # 0 = no reminders


DEFAULT_SETTINGS = Settings()


# ---------------------------------------------------------------------------
# Subprocess safety
# ---------------------------------------------------------------------------

SAFE_EXEC_DIRS = ("/usr/bin", "/usr/local/bin", "/opt/homebrew/bin")
SAFE_ENV = {"PATH": ":".join(SAFE_EXEC_DIRS), "HOME": os.path.expanduser("~")}
TRUSTED_CWD = os.path.expanduser("~")


def _resolve_executable(name: str) -> Optional[str]:
    """Resolve a helper name to an absolute path under SAFE_EXEC_DIRS only."""
    resolved = shutil.which(name, path=SAFE_ENV["PATH"])
    if not resolved:
        return None
    real = os.path.realpath(resolved)
    if any(
        real.startswith(prefix + os.sep) or real == prefix
        for prefix in SAFE_EXEC_DIRS
    ):
        return real
    log.warning("Ignoring unsafe executable path for %s: %s", name, real)
    return None


# ---------------------------------------------------------------------------
# Unified brightness backend
# ---------------------------------------------------------------------------

@dataclass
class BrightnessBackend:
    """Wraps a CLI tool that accepts a normalised [0, 1] brightness value."""
    name: str
    executable: str
    # Converts a clamped [0, 1] float to the CLI argument list
    args_builder: Callable[[float], List[str]]
    out_min: float
    out_max: float

    def clamp(self, value: float) -> float:
        return float(np.clip(value, self.out_min, self.out_max))


_KEYBOARD_CANDIDATES: List[BrightnessBackend] = [
    BrightnessBackend("kbrightness",       "", lambda v: [f"{v:.3f}"],          0.0, 1.0),
    BrightnessBackend("mac-brightnessctl", "", lambda v: [str(int(v * 100))],   0.0, 1.0),
]

_SCREEN_CANDIDATES: List[BrightnessBackend] = [
    BrightnessBackend("brightness", "", lambda v: ["-l", f"{v:.3f}"],           0.0, 1.0),
    BrightnessBackend("ddcctl",     "", lambda v: ["-b", str(int(v * 100))],    0.0, 1.0),
]


def detect_backend(
    candidates: List[BrightnessBackend],
    label: str,
) -> Optional[BrightnessBackend]:
    """Return the first candidate whose executable resolves under SAFE_EXEC_DIRS."""
    for backend in candidates:
        resolved = _resolve_executable(backend.name)
        if resolved:
            log.info("Using %s backend: %s (%s)", label, backend.name, resolved)
            backend.executable = resolved
            return backend
    log.warning("No %s backend found. %s control disabled.", label, label.capitalize())
    return None


def run_backend(backend: BrightnessBackend, value: float, label: str) -> None:
    clamped = backend.clamp(value)
    cmd = [backend.executable] + backend.args_builder(clamped)
    try:
        subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            cwd=TRUSTED_CWD,
            env=SAFE_ENV,
        )
        log.debug("Set %s via %s → %.3f", label, backend.name, clamped)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode(errors="ignore").strip()
        log.warning("Failed to set %s via %s: %s", label, backend.name, stderr)


# ---------------------------------------------------------------------------
# Pure control policy
# ---------------------------------------------------------------------------

def _map_value(ambient: float, out_min: float, out_max: float, invert: bool) -> float:
    if invert:
        return out_max - ambient * (out_max - out_min)
    return out_min + ambient * (out_max - out_min)


def compute_targets(
    history: deque,
    ambient_now: float,
    last_keyboard: float,
    last_screen: float,
    s: Settings,
) -> Tuple[Optional[float], Optional[float]]:
    """
    Return (new_keyboard, new_screen) or None for each if change is below
    threshold.  Pure – no I/O.
    """
    history.append(ambient_now)
    smoothed = float(np.mean(history))

    kbd = _map_value(smoothed, s.keyboard_min, s.keyboard_max, s.invert_keyboard)
    scr = _map_value(smoothed, s.screen_min,   s.screen_max,   s.invert_screen)

    new_kbd = kbd if abs(kbd - last_keyboard) > s.change_threshold else None
    new_scr = scr if abs(scr - last_screen)  > s.change_threshold else None
    return new_kbd, new_scr


# ---------------------------------------------------------------------------
# Privacy / runtime guard
# ---------------------------------------------------------------------------

class RuntimeGuard:
    """Centralises camera-runtime reminders and optional auto-stop."""

    def __init__(self, s: Settings) -> None:
        self._max    = s.max_runtime_sec
        self._remind = s.reminder_interval_sec
        self._start  = time.monotonic()
        self._last_reminder = self._start

    def should_exit(self) -> bool:
        return self._max > 0 and (time.monotonic() - self._start) >= self._max

    def maybe_remind(self) -> None:
        if self._remind <= 0:
            return
        now = time.monotonic()
        if now - self._last_reminder >= self._remind:
            log.info(
                "[Reminder] AutoKeyboardDim is using the camera. "
                "Press Ctrl+C to stop."
            )
            self._last_reminder = now


# ---------------------------------------------------------------------------
# Camera sampling
# ---------------------------------------------------------------------------

def capture_mean_brightness(cap: cv2.VideoCapture, n_frames: int = 3) -> float:
    values = []
    for _ in range(n_frames):
        ret, frame = cap.read()
        if not ret:
            continue
        small = cv2.resize(frame, (64, 48))
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        values.append(float(np.mean(hsv[:, :, 2]) / 255.0))
        time.sleep(0.05)
    return float(np.mean(values)) if values else 0.5


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run(s: Settings = DEFAULT_SETTINGS) -> None:
    keyboard_backend = detect_backend(_KEYBOARD_CANDIDATES, "keyboard")
    screen_backend   = detect_backend(_SCREEN_CANDIDATES,   "screen")

    if keyboard_backend is None and screen_backend is None:
        log.error(
            "No output backends available. "
            "Install at least one keyboard or screen brightness backend."
        )
        sys.exit(1)

    cap = cv2.VideoCapture(s.camera_index)
    if not cap.isOpened():
        log.error(
            "Cannot open webcam. Check camera permissions in "
            "System Settings → Privacy & Security → Camera."
        )
        sys.exit(1)

    log.info("Camera active. Warming up auto-exposure (3 s)…")
    for _ in range(15):
        cap.read()
        time.sleep(0.2)

    history: deque = deque(maxlen=s.smoothing_window)
    last_keyboard = -1.0
    last_screen   = -1.0
    guard = RuntimeGuard(s)

    log.info("Ambient loop started. Ctrl+C to stop.")
    try:
        while True:
            if guard.should_exit():
                log.info("Max runtime reached. Stopping.")
                break
            guard.maybe_remind()

            ambient = capture_mean_brightness(cap, s.capture_frames)
            new_kbd, new_scr = compute_targets(
                history, ambient, last_keyboard, last_screen, s
            )

            if new_kbd is not None and keyboard_backend:
                run_backend(keyboard_backend, new_kbd, "keyboard brightness")
                last_keyboard = new_kbd

            if new_scr is not None and screen_backend:
                run_backend(screen_backend, new_scr, "screen brightness")
                last_screen = new_scr

            log.info(
                "Ambient: %.3f → Keyboard: %.3f | Screen: %.3f",
                float(np.mean(history)) if history else ambient,
                last_keyboard,
                last_screen,
            )

            time.sleep(s.poll_interval_sec)

    except KeyboardInterrupt:
        log.info("Interrupted. Restoring defaults.")
    finally:
        if keyboard_backend:
            run_backend(keyboard_backend, 0.5, "keyboard brightness")
        if screen_backend:
            run_backend(screen_backend, 0.7, "screen brightness")
        cap.release()


if __name__ == "__main__":
    run()
