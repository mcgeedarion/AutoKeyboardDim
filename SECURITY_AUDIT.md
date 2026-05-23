# Security Review: AutoKeyboardDim

Date: 2026-05-23

## Scope
- `ambient_backlight.py`
- `swift/Sources/main.swift`

## Findings

### 1) PATH hijacking of privileged helper binaries (High)
Both implementations execute external tools by name (`kbrightness`, `mac-brightnessctl`, `brightness`, `ddcctl`) and rely on shell PATH resolution (`shutil.which` in Python and `/usr/bin/env` in Swift). If this program runs under elevated privileges (e.g., launchd daemon or root), an attacker who can influence PATH or drop a malicious binary earlier in PATH can get arbitrary code execution.

Affected patterns:
- Python: backend detection and execution by command name.
- Swift: `runCommand` executes `/usr/bin/env <tool>` after only checking `which`.

Recommendation:
- Resolve absolute path once at startup and execute that exact path.
- Use a fixed safe PATH (or no PATH lookup at execution time).
- Refuse to run when tool path is not in an allowlisted directory (`/usr/bin`, `/opt/homebrew/bin`, etc.).

### 2) Untrusted current working directory execution context (Medium)
There is no working-directory hardening before launching helper tools. If any helper indirectly loads config/plugins from CWD, running this app from an untrusted folder could affect behavior.

Recommendation:
- Set `cwd` to a trusted directory before subprocess/process execution.
- Sanitize environment variables passed to child processes.

### 3) Camera privacy exposure through continuous background capture (Low)
The app continuously captures webcam frames in the background. This is expected functionality but still privacy-sensitive; accidental long-running background use can exceed user expectations.

Recommendation:
- Add explicit runtime indicator/state and optional max-runtime timeout.
- Add a “camera active” status output and optional periodic reminder.

## Notes
- No command-injection sink was found from user-controlled strings because commands are passed as argument arrays, not shell strings.
- No network-facing surface was identified in this codebase.
