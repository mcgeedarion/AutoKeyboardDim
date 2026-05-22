# ambient-keyboard-backlight

Automatically adjusts your macOS keyboard backlight and display brightness based on an approximation of ambient light measured via the built-in webcam.

## How It Works

1. **Webcam → ambient light**: Captures frames, converts to HSV, and computes mean luminance (V channel) as a 0–1 brightness proxy.
2. **Set keyboard brightness**: Shells out to `kbrightness` or `mac-brightnessctl`.
3. **Set display brightness**: Shells out to `brightness` (built-in display) or `ddcctl` (external DDC display).
4. **Smoothing**: A rolling average over 5 samples prevents strobing from brief shadows.
5. **Threshold guard**: Only writes when brightness changes by >2%.

## Requirements

- macOS (tested on Ventura/Sonoma)
- Python 3.8+
- `opencv-python` and `numpy`

```bash
pip install opencv-python numpy
```

## Brightness Backends

### Keyboard (install one)

```bash
# Option 1 — kbrightness
brew install kbrightness

# Option 2 — mac-brightnessctl
brew tap rakalex/mac-brightnessctl
brew install mac-brightnessctl
```

## Camera Permission

Grant your terminal/IDE camera access:
**System Settings → Privacy & Security → Camera**

## Usage

```bash
python3 ambient_backlight.py
```

Press `Ctrl+C` to stop. Keyboard brightness restores to 50%.

### Configuration

Edit the constants at the top of `ambient_backlight.py`:

| Variable | Default | Description |
|---|---|---|
| `POLL_INTERVAL_SEC` | `2.0` | Seconds between webcam samples |
| `SMOOTHING_WINDOW` | `5` | Rolling average window size |
| `BRIGHTNESS_MIN` | `0.0` | Minimum keyboard brightness |
| `BRIGHTNESS_MAX` | `1.0` | Maximum keyboard brightness |
| `INVERT` | `True` | Dark room → full backlight, bright room → dim |
| `CAMERA_INDEX` | `0` | Webcam index (0 = built-in) |

## Run as a Background Service (LaunchAgent)

1. Edit `com.user.ambientbacklight.plist` — update `/path/to/ambient_backlight.py` to the absolute path of the script.
2. Copy to your LaunchAgents folder:

```bash
cp com.user.ambientbacklight.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```

To stop the service:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```


### Screen (install one)

```bash
# Option 1 — brightness (built-in display)
brew install brightness

# Option 2 — ddcctl (external DDC display)
brew install ddcctl
```
