#!/usr/bin/env python3
"""
ambient_backlight.py
Reads webcam frames to estimate ambient light, then adjusts
macOS keyboard and screen brightness accordingly.

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
from dataclasses import dataclass
from collections import deque
from typing import Callable, Optional

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# --- Configuration ---
POLL_INTERVAL_SEC = 2.0
SMOOTHING_WINDOW = 5
CAMERA_INDEX = 0
CAPTURE_FRAMES = 3
CHANGE_THRESHOLD = 0.02

# Keyboard output range
KEYBOARD_MIN = 0.0
KEYBOARD_MAX = 1.0

# Screen output range (avoid full black unless you intentionally want it)
SCREEN_MIN = 0.2
SCREEN_MAX = 1.0

# Mapping behavior
# Dark room -> brighter keyboard + dimmer screen
# Bright room -> dimmer keyboard + brighter screen
INVERT_KEYBOARD = True
INVERT_SCREEN = False


@dataclass
class BrightnessBackend:
    name: str
    setter: Callable[[float], list[str]]
    min_value: float
    max_value: float

    def clamp(self, value: float) -> float:
        return float(np.clip(value, self.min_value, self.max_value))


def _which(name: str) -> bool:
    import shutil

    return bool(shutil.which(name))


def detect_keyboard_backend() -> Optional[BrightnessBackend]:
    candidates = [
        BrightnessBackend("kbrightness", lambda v: ["kbrightness", f"{v:.3f}"], 0.0, 1.0),
        BrightnessBackend("mac-brightnessctl", lambda v: ["mac-brightnessctl", str(int(v * 100))], 0.0, 1.0),
    ]
    for backend in candidates:
        if _which(backend.name):
            log.info("Using keyboard backend: %s", backend.name)
            return backend
    log.warning("No keyboard backend found (kbrightness/mac-brightnessctl). Keyboard control disabled.")
    return None


def detect_screen_backend() -> Optional[BrightnessBackend]:
    candidates = [
        BrightnessBackend("brightness", lambda v: ["brightness", "-l", f"{v:.3f}"], 0.0, 1.0),
        BrightnessBackend("ddcctl", lambda v: ["ddcctl", "-b", str(int(v * 100))], 0.0, 1.0),
    ]
    for backend in candidates:
        if _which(backend.name):
            log.info("Using screen backend: %s", backend.name)
            return backend
    log.warning("No screen backend found (brightness/ddcctl). Screen control disabled.")
    return None


def run_backend(backend: BrightnessBackend, value: float, label: str) -> None:
    clamped = backend.clamp(value)
    cmd = backend.setter(clamped)
    try:
        subprocess.run(cmd, check=True, capture_output=True)
        log.debug("Set %s via %s -> %.3f", label, backend.name, clamped)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode(errors="ignore").strip()
        log.warning("Failed to set %s via %s: %s", label, backend.name, stderr)


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


def map_value(ambient: float, out_min: float, out_max: float, invert: bool) -> float:
    if invert:
        return out_max - ambient * (out_max - out_min)
    return out_min + ambient * (out_max - out_min)


def run():
    keyboard_backend = detect_keyboard_backend()
    screen_backend = detect_screen_backend()

    if keyboard_backend is None and screen_backend is None:
        log.error("No output backends available. Install at least one keyboard or screen brightness backend.")
        sys.exit(1)

    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        log.error("Cannot open webcam. Check camera permissions in System Settings -> Privacy & Security -> Camera.")
        sys.exit(1)

    log.info("Warming up camera auto-exposure (3 seconds)...")
    for _ in range(15):
        cap.read()
        time.sleep(0.2)

    history = deque(maxlen=SMOOTHING_WINDOW)
    last_keyboard = -1.0
    last_screen = -1.0

    log.info("Starting ambient loop. Ctrl+C to stop.")
    try:
        while True:
            ambient = capture_mean_brightness(cap, CAPTURE_FRAMES)
            history.append(ambient)
            smoothed_ambient = float(np.mean(history))

            keyboard_target = map_value(smoothed_ambient, KEYBOARD_MIN, KEYBOARD_MAX, INVERT_KEYBOARD)
            screen_target = map_value(smoothed_ambient, SCREEN_MIN, SCREEN_MAX, INVERT_SCREEN)

            if keyboard_backend and abs(keyboard_target - last_keyboard) > CHANGE_THRESHOLD:
                run_backend(keyboard_backend, keyboard_target, "keyboard brightness")
                last_keyboard = keyboard_target

            if screen_backend and abs(screen_target - last_screen) > CHANGE_THRESHOLD:
                run_backend(screen_backend, screen_target, "screen brightness")
                last_screen = screen_target

            log.info(
                "Ambient: %.3f -> Keyboard: %.3f | Screen: %.3f",
                smoothed_ambient,
                keyboard_target,
                screen_target,
            )

            time.sleep(POLL_INTERVAL_SEC)

    except KeyboardInterrupt:
        log.info("Interrupted. Restoring defaults.")
        if keyboard_backend:
            run_backend(keyboard_backend, 0.5, "keyboard brightness")
        if screen_backend:
            run_backend(screen_backend, 0.7, "screen brightness")
    finally:
        cap.release()


if __name__ == "__main__":
    run()
