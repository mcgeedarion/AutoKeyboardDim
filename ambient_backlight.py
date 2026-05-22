#!/usr/bin/env python3
"""
ambient_backlight.py
Reads webcam frames to estimate ambient light, then adjusts
macOS keyboard backlight brightness accordingly.

Dependencies:
    pip install opencv-python numpy

Backend (install one):
    brew install kbrightness
    # OR
    brew tap rakalex/mac-brightnessctl && brew install mac-brightnessctl

macOS Camera Permission:
    System Settings → Privacy & Security → Camera → grant Terminal/IDE access
"""

import cv2
import numpy as np
import subprocess
import time
import logging
import sys
from collections import deque

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# --- Configuration ---
POLL_INTERVAL_SEC   = 2.0    # How often to sample webcam (seconds)
SMOOTHING_WINDOW    = 5      # Rolling average over N samples
BRIGHTNESS_MIN      = 0.0    # Min keyboard brightness (0.0 = off)
BRIGHTNESS_MAX      = 1.0    # Max keyboard brightness (1.0 = full)
# Map ambient lux-proxy [dark=0.0 .. bright=1.0] → keyboard brightness
# Dark room → high backlight; bright room → low backlight (inverse)
INVERT              = True   # Set False if you want brightness to track light
CAMERA_INDEX        = 0      # 0 = default/built-in webcam
CAPTURE_FRAMES      = 3      # Frames to average per sample (reduces noise)

# --- Keyboard brightness backends ---
# Try these in order; first one that works is used.
BACKENDS = [
    # kbrightness: value is 0.0 – 1.0
    lambda v: ["kbrightness", str(round(v, 3))],
    # mac-brightnessctl: value is 0 – 100
    lambda v: ["mac-brightnessctl", str(int(v * 100))],
]


def detect_backend() -> callable:
    """Return the first available brightness-setting backend."""
    import shutil
    names = ["kbrightness", "mac-brightnessctl"]
    for name, fn in zip(names, BACKENDS):
        if shutil.which(name):
            log.info(f"Using backend: {name}")
            return fn
    log.error("No keyboard brightness backend found. Install kbrightness or mac-brightnessctl.")
    sys.exit(1)


def set_keyboard_brightness(value: float, backend_fn: callable):
    """Set keyboard backlight to `value` in [0.0, 1.0]."""
    value = float(np.clip(value, BRIGHTNESS_MIN, BRIGHTNESS_MAX))
    cmd = backend_fn(value)
    try:
        subprocess.run(cmd, check=True, capture_output=True)
        log.debug(f"Set keyboard brightness → {value:.3f}")
    except subprocess.CalledProcessError as e:
        log.warning(f"Failed to set brightness: {e.stderr.decode().strip()}")
    except FileNotFoundError:
        log.error(f"Command not found: {cmd[0]}")


def capture_mean_brightness(cap: cv2.VideoCapture, n_frames: int = 3) -> float:
    """
    Capture n_frames from webcam and return mean pixel brightness in [0.0, 1.0].
    Uses the V channel of HSV to isolate luminance from color.
    """
    values = []
    for _ in range(n_frames):
        ret, frame = cap.read()
        if not ret:
            continue
        # Resize small for speed – we only need global brightness
        small = cv2.resize(frame, (64, 48))
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        v_channel = hsv[:, :, 2]          # Value = luminance
        values.append(np.mean(v_channel) / 255.0)
        time.sleep(0.05)

    if not values:
        return 0.5  # fallback: mid brightness
    return float(np.mean(values))


def ambient_to_keyboard_brightness(ambient: float) -> float:
    """
    Map ambient brightness [0=dark, 1=bright] → keyboard brightness.
    INVERT=True: dark room → full backlight, bright room → off/dim.
    INVERT=False: mirrors ambient (e.g. for display brightness use-case).
    """
    if INVERT:
        return BRIGHTNESS_MAX - ambient * (BRIGHTNESS_MAX - BRIGHTNESS_MIN)
    return BRIGHTNESS_MIN + ambient * (BRIGHTNESS_MAX - BRIGHTNESS_MIN)


def run():
    backend = detect_backend()

    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        log.error(
            "Cannot open webcam. Check camera permissions: "
            "System Settings → Privacy & Security → Camera"
        )
        sys.exit(1)

    # Warm up camera (auto-exposure needs a moment to stabilize)
    log.info("Warming up camera auto-exposure (3 seconds)...")
    for _ in range(15):
        cap.read()
        time.sleep(0.2)

    history = deque(maxlen=SMOOTHING_WINDOW)
    last_set_brightness = -1.0

    log.info("Starting ambient light → keyboard backlight loop. Ctrl+C to stop.")
    try:
        while True:
            ambient = capture_mean_brightness(cap, CAPTURE_FRAMES)
            history.append(ambient)

            smoothed_ambient = float(np.mean(history))
            target_brightness = ambient_to_keyboard_brightness(smoothed_ambient)

            # Only write if change is significant (> 2%) to avoid constant IOKit calls
            if abs(target_brightness - last_set_brightness) > 0.02:
                set_keyboard_brightness(target_brightness, backend)
                last_set_brightness = target_brightness
                log.info(
                    f"Ambient: {smoothed_ambient:.3f} → "
                    f"Keyboard brightness: {target_brightness:.3f}"
                )

            time.sleep(POLL_INTERVAL_SEC)

    except KeyboardInterrupt:
        log.info("Interrupted. Restoring keyboard brightness to 50%.")
        set_keyboard_brightness(0.5, backend)
    finally:
        cap.release()


if __name__ == "__main__":
    run()
