import Foundation
import AVFoundation
import CoreMedia
import UserNotifications
import CoreVideo
import IOKit
import Accelerate

// MARK: - Settings (policy)

struct Settings {
    let pollIntervalSeconds: TimeInterval = 2.0
    let smoothingWindow: Int = 5
    let changeThreshold: Float = 0.02

    let keyboardMin: Float = 0.0
    let keyboardMax: Float = 1.0
    let invertKeyboard: Bool = true   // dark room → brighter keyboard

    let screenMin: Float = 0.2
    let screenMax: Float = 1.0
    let invertScreen: Bool = false    // dark room → dimmer screen

    // Privacy / runtime guard
    let maxCameraRuntimeSeconds: TimeInterval = 3600   // 0 = unlimited
    let reminderIntervalSeconds: TimeInterval = 900    // 0 = no reminders
}

let settings = Settings()

// MARK: - Notifications

func configureNotifications() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { fputs("Notification auth error: \(error.localizedDescription)\n", stderr) }
        if !granted  { fputs("Notification access not granted; banners disabled.\n", stderr) }
    }
}

func postNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body  = body
    let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
}

// MARK: - Subprocess safety

let trustedWorkingDirectory = NSHomeDirectory()
let safePathEntries = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

func resolveExecutable(_ command: String) -> String? {
    let fm = FileManager.default
    for base in safePathEntries {
        let candidate = URL(fileURLWithPath: base)
            .appendingPathComponent(command).path
        if fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
                .resolvingSymlinksInPath().path
        }
    }
    return nil
}

func sanitizedEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    let current = ProcessInfo.processInfo.environment
    for key in ["LANG", "LC_ALL", "LC_CTYPE", "HOME"] {
        if let v = current[key] { env[key] = v }
    }
    env["PATH"] = safePathEntries.joined(separator: ":")
    for key in ["LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "PYTHONPATH"] {
        env.removeValue(forKey: key)
    }
    return env
}

/// Single entry-point for all subprocess invocations.
/// Always uses the hardened cwd + sanitized environment.
struct ProcessLauncher {
    private let cwd = URL(fileURLWithPath: trustedWorkingDirectory)
    private let env = sanitizedEnvironment()

    @discardableResult
    func run(executablePath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL      = URL(fileURLWithPath: executablePath)
        process.arguments          = arguments
        process.currentDirectoryURL = cwd
        process.environment        = env
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            fputs("Warning: \(executablePath) \(arguments.joined(separator: " ")): "
                  + "\(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

let launcher = ProcessLauncher()

// MARK: - Unified brightness backend

enum BackendKind { case keyboard, screen }

struct BrightnessBackend {
    let kind: BackendKind
    let name: String
    let executablePath: String
    let commandBuilder: (Float) -> [String]
    let outMin: Float
    let outMax: Float

    func clamped(_ value: Float) -> Float {
        min(max(value, outMin), outMax)
    }

    func set(_ value: Float) {
        let v = clamped(value)
        let ok = launcher.run(executablePath: executablePath,
                               arguments: commandBuilder(v))
        if !ok {
            fputs("Warning: failed to set \(kind) brightness via \(name)\n", stderr)
        }
    }
}

func detectBackend(kind: BackendKind) -> BrightnessBackend? {
    let candidates: [(name: String, builder: (Float) -> [String], min: Float, max: Float)]
    switch kind {
    case .keyboard:
        candidates = [
            ("kbrightness",       { v in [String(format: "%.3f", v)] },          0.0, 1.0),
            ("mac-brightnessctl", { v in [String(Int(v * 100))] },               0.0, 1.0),
        ]
    case .screen:
        candidates = [
            ("brightness", { v in ["-l", String(format: "%.3f", v)] },           0.0, 1.0),
            ("ddcctl",     { v in ["-b", String(Int(v * 100))] },                0.0, 1.0),
        ]
    }

    for c in candidates {
        if let path = resolveExecutable(c.name) {
            print("Using \(kind) backend: \(c.name) (\(path))")
            return BrightnessBackend(
                kind: kind, name: c.name, executablePath: path,
                commandBuilder: c.builder, outMin: c.min, outMax: c.max
            )
        }
    }
    fputs("Warning: no \(kind) backend found. \(kind) control disabled.\n", stderr)
    return nil
}

// MARK: - Pure control policy

func mapAmbient(_ ambient: Float, minValue: Float, maxValue: Float, invert: Bool) -> Float {
    invert ? maxValue - ambient * (maxValue - minValue)
           : minValue + ambient * (maxValue - minValue)
}

/// Pure – no I/O. Returns nil for each target when change is below threshold.
func computeTargets(
    history: inout [Float],
    ambientNow: Float,
    lastKeyboard: Float,
    lastScreen: Float,
    s: Settings
) -> (keyboard: Float?, screen: Float?) {
    history.append(ambientNow)
    if history.count > s.smoothingWindow { history.removeFirst() }
    let smoothed = history.reduce(0, +) / Float(history.count)

    let kbd = mapAmbient(smoothed, minValue: s.keyboardMin, maxValue: s.keyboardMax, invert: s.invertKeyboard)
    let scr = mapAmbient(smoothed, minValue: s.screenMin,   maxValue: s.screenMax,   invert: s.invertScreen)

    return (
        abs(kbd - lastKeyboard) > s.changeThreshold ? kbd : nil,
        abs(scr - lastScreen)   > s.changeThreshold ? scr : nil
    )
}

// MARK: - Runtime guard

final class RuntimeGuard {
    private let maxRuntime: TimeInterval
    private let reminderInterval: TimeInterval
    private let start = Date()
    private var lastReminder = Date()

    init(s: Settings) {
        maxRuntime       = s.maxCameraRuntimeSeconds
        reminderInterval = s.reminderIntervalSeconds
    }

    var shouldExit: Bool {
        maxRuntime > 0 && Date().timeIntervalSince(start) >= maxRuntime
    }

    func maybeRemind() {
        guard reminderInterval > 0,
              Date().timeIntervalSince(lastReminder) >= reminderInterval
        else { return }
        postNotification(
            title: "AutoKeyboardDim",
            body: "Camera is active. Press Ctrl+C to stop."
        )
        lastReminder = Date()
    }
}

// MARK: - Webcam sampling

final class BrightnessSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue   = DispatchQueue(label: "com.ambientbacklight.camera", qos: .utility)
    private var _brightness: Float = 0.5
    private let lock = NSLock()

    var currentBrightness: Float {
        lock.lock(); defer { lock.unlock() }
        return _brightness
    }

    func start() throws {
        session.beginConfiguration()
        session.sessionPreset = .low

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .unspecified
        ) else {
            throw NSError(domain: "AmbientBacklight", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "AmbientBacklight", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "AmbientBacklight", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        print("Warming up camera auto-exposure (3 s)…")
        session.startRunning()
        Thread.sleep(forTimeInterval: 3.0)
        print("Ready.\n")
    }

    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let count  = height * stride

        var floatBuf = [Float](repeating: 0, count: count)
        vDSP_vfltu8(lumaBase.assumingMemoryBound(to: UInt8.self), 1, &floatBuf, 1, vDSP_Length(count))
        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))

        lock.lock()
        _brightness = mean / 255.0
        lock.unlock()
    }
}

// MARK: - Entry point

configureNotifications()

let keyboardBackend = detectBackend(kind: .keyboard)
let screenBackend   = detectBackend(kind: .screen)

if keyboardBackend == nil && screenBackend == nil {
    fputs("Error: no output backends available. Install keyboard/screen brightness tools.\n", stderr)
    exit(1)
}

// Request camera permission
let semaphore = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { granted in
    if !granted {
        fputs("Camera access denied.\nSystem Settings → Privacy & Security → Camera\n", stderr)
    }
    semaphore.signal()
}
semaphore.wait()

guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { exit(1) }

let sampler = BrightnessSampler()
do {
    try sampler.start()
} catch {
    fputs("Camera error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

postNotification(
    title: "AutoKeyboardDim",
    body: "Camera is now active to adjust keyboard and screen brightness."
)

var history   = [Float]()
var lastKeyboard: Float = -1.0
var lastScreen:   Float = -1.0
let guard_ = RuntimeGuard(s: settings)

// Graceful shutdown on Ctrl+C
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigSrc.setEventHandler {
    print("\nRestoring defaults…")
    keyboardBackend?.set(0.5)
    screenBackend?.set(0.7)
    sampler.stop()
    exit(0)
}
sigSrc.resume()

print("Ambient backlight running (camera active). Press Ctrl+C to stop.\n")

while true {
    if guard_.shouldExit {
        print("Max runtime reached. Stopping.")
        keyboardBackend?.set(0.5)
        screenBackend?.set(0.7)
        sampler.stop()
        break
    }
    guard_.maybeRemind()

    let ambientNow = sampler.currentBrightness
    let (newKbd, newScr) = computeTargets(
        history: &history,
        ambientNow: ambientNow,
        lastKeyboard: lastKeyboard,
        lastScreen: lastScreen,
        s: settings
    )

    if let v = newKbd {
        keyboardBackend?.set(v)
        lastKeyboard = v
    }
    if let v = newScr {
        screenBackend?.set(v)
        lastScreen = v
    }

    let smoothed = history.isEmpty ? ambientNow : history.reduce(0, +) / Float(history.count)
    print(String(format: "Ambient: %.3f → Keyboard: %.0f%% | Screen: %.0f%%",
                 smoothed, lastKeyboard * 100, lastScreen * 100))

    Thread.sleep(forTimeInterval: settings.pollIntervalSeconds)
}
