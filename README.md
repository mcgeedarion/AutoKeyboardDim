# AutoKeyboardDim

Automatically adjusts macOS keyboard backlight and display brightness based
on ambient light estimated from the built-in webcam.

## Implementations

| Path | Language | Recommended use |
|---|---|---|
| `swift/` | Swift (native) | **Primary — use this for daily use / LaunchAgent** |
| `ambient_backlight.py` | Python | Reference / developer script |

Both share the same algorithm and security model.  Prefer the Swift binary
for production because it uses AVFoundation natively (no pip dependencies,
no OpenCV), integrates with Notification Center, and compiles to a standalone
executable.

## How It Works

1. **Webcam → ambient light**: Samples camera frames, extracts luma (Y plane
   in Swift, HSV-V in Python), averages across a rolling window.
2. **Policy mapping**: Maps the smoothed ambient value to keyboard/screen
   brightness with configurable min/max and optional inversion.
3. **Threshold guard**: Only writes when brightness changes by > 2% to avoid
   constant subprocess churn.
4. **Privacy guard**: Sends a Notification Center banner on start and
   periodic reminders while the camera is active. Optionally auto-stops
   after a configurable runtime limit.
5. **CLI backends**: Shells out to `kbrightness`/`mac-brightnessctl` (keyboard)
   and `brightness`/`ddcctl` (screen). Executable paths are resolved at
   startup and validated against an allow-list of safe directories.

## Security Model

- **No PATH hijacking**: helper executables are resolved once at startup via
  an allow-list (`/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`). The
  resolved absolute path is stored and used for all subsequent invocations.
- **Sanitized subprocess environment**: child processes receive only a
  minimal, fixed environment (`PATH`, `HOME`, locale). `LD_PRELOAD`,
  `DYLD_INSERT_LIBRARIES`, and `PYTHONPATH` are explicitly stripped.
- **Trusted CWD**: subprocesses are always launched with `cwd` set to `$HOME`.
- **No shell expansion**: all commands are passed as argument arrays, never
  through a shell, so there is no command-injection surface.
- **Camera privacy**: Notification Center banner on start and configurable
  periodic reminders. Optional auto-stop (`maxCameraRuntimeSeconds`).

## Requirements

### Swift binary (recommended)
- macOS 13 (Ventura) or later
- Swift toolchain (`xcode-select --install` or Xcode)

### Python script
- Python 3.8+
- `pip install opencv-python numpy`

## Brightness Backends

### Keyboard (install one)

```bash
# Option 1 — kbrightness
brew install kbrightness

# Option 2 — mac-brightnessctl
brew tap rakalex/mac-brightnessctl
brew install mac-brightnessctl
```

### Screen (install one)

```bash
# Option 1 — brightness (built-in display)
brew install brightness

# Option 2 — ddcctl (external DDC display)
brew install ddcctl
```

## Camera Permission

Grant your terminal / app camera access:
**System Settings → Privacy & Security → Camera**

## Usage

### Swift (recommended)

```bash
cd swift
swift build -c release
.build/release/AmbientBacklight
```

Press `Ctrl+C` to stop. Keyboard and screen brightness restore to defaults.

### Python (script / dev)

```bash
pip install opencv-python numpy
python3 ambient_backlight.py
```

### Configuration

Edit the `Settings` struct in `swift/Sources/main.swift` (or the `Settings`
dataclass in `ambient_backlight.py`):

| Field | Default | Description |
|---|---|---|
| `pollIntervalSeconds` | `2.0` | Seconds between samples |
| `smoothingWindow` | `5` | Rolling-average window size |
| `changeThreshold` | `0.02` | Min brightness delta to trigger a write |
| `keyboardMin/Max` | `0.0 / 1.0` | Keyboard output range |
| `screenMin/Max` | `0.2 / 1.0` | Screen output range |
| `invertKeyboard` | `true` | Dark room → brighter keyboard |
| `invertScreen` | `false` | Dark room → dimmer screen |
| `maxCameraRuntimeSeconds` | `3600` | Auto-stop after N seconds (0 = unlimited) |
| `reminderIntervalSeconds` | `900` | Notification reminder cadence (0 = off) |

## Run as a Background Service (LaunchAgent)

1. Build the Swift binary: `cd swift && swift build -c release`
2. Edit `com.user.ambientbacklight.plist` — set the `ProgramArguments` path
   to the compiled binary, e.g. `/Users/you/AutoKeyboardDim/swift/.build/release/AmbientBacklight`.
3. Install and load:

```bash
cp com.user.ambientbacklight.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```

To stop:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```
