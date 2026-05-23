import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit
import Accelerate

// MARK: - Configuration

let pollIntervalSeconds: Double = 2.0
let smoothingWindow = 5
let changeThreshold: Float = 0.02

let keyboardMin: Float = 0.0
let keyboardMax: Float = 1.0
let invertKeyboard = true   // dark room -> brighter keyboard

let screenMin: Float = 0.2
let screenMax: Float = 1.0
let invertScreen = false    // dark room -> dimmer screen

// Privacy / reminder configuration
let maxCameraRuntimeSeconds: TimeInterval = 60 * 60   // 1 hour default; set 0 to disable auto-stop
let reminderIntervalSeconds: TimeInterval = 15 * 60   // periodic reminder cadence

// MARK: - Keyboard Brightness Backends (CLI)

let trustedWorkingDirectory = NSHomeDirectory()
let safePathEntries = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

func resolveExecutable(_ command: String) -> String? {
    let fm = FileManager.default
    for base in safePathEntries {
        let candidate = URL(fileURLWithPath: base).appendingPathComponent(command).path
        if fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        }
    }
    return nil
}

struct KeyboardBackend {
    let name: String
    let executablePath: String
    let commandBuilder: (Float) -> [String]
}

func detectKeyboardBackend() -> KeyboardBackend? {
    if let path = resolveExecutable("kbrightness") {
        print("Using keyboard backend: kbrightness (\(path))")
        return KeyboardBackend(name: "kbrightness", executablePath: path) { value in
            [String(format: "%.3f", value)]
        }
    }

    if let path = resolveExecutable("mac-brightnessctl") {
        print("Using keyboard backend: mac-brightnessctl (\(path))")
        return KeyboardBackend(name: "mac-brightnessctl", executablePath: path) { value in
            [String(Int(value * 100))]
        }
    }

    fputs("Warning: No keyboard backend found (kbrightness/mac-brightnessctl). Keyboard control disabled.\n", stderr)
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

func setKeyboardBrightness(_ value: Float, backend: KeyboardBackend?) {
    guard let backend else { return }
    let clamped = min(max(value, keyboardMin), keyboardMax)
    let ok = runCommand(executablePath: backend.executablePath, arguments: backend.commandBuilder(clamped))
    if !ok {
        fputs("Warning: failed to set keyboard brightness via \(backend.name)\n", stderr)
    }
}

// MARK: - Screen Brightness Backends (CLI)

struct ScreenBackend {
    let name: String
    let executablePath: String
    let commandBuilder: (Float) -> [String]
}

func detectScreenBackend() -> ScreenBackend? {
    if let path = resolveExecutable("brightness") {
        print("Using screen backend: brightness (\(path))")
        return ScreenBackend(name: "brightness", executablePath: path) { value in
            ["-l", String(format: "%.3f", value)]
        }
    }

    if let path = resolveExecutable("ddcctl") {
        print("Using screen backend: ddcctl (\(path))")
        return ScreenBackend(name: "ddcctl", executablePath: path) { value in
            ["-b", String(Int(value * 100))]
        }
    }

    fputs("Warning: No screen backend found (brightness/ddcctl). Screen control disabled.\n", stderr)
    return nil
}

@discardableResult
func runCommand(executablePath: String, arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: trustedWorkingDirectory)
    process.environment = sanitizedEnvironment()

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        fputs("Warning: failed to run \(executablePath) \(arguments.joined(separator: " ")): \(error.localizedDescription)\n", stderr)
        return false
    }
}

func setScreenBrightness(_ value: Float, backend: ScreenBackend?) {
    guard let backend else { return }
    let clamped = min(max(value, 0.0), 1.0)
    let ok = runCommand(executablePath: backend.executablePath, arguments: backend.commandBuilder(clamped))
    if !ok {
        fputs("Warning: failed to set screen brightness via \(backend.name)\n", stderr)
    }
}

// MARK: - Webcam Brightness Sampling

final class BrightnessSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.ambientbacklight.camera", qos: .utility)
    private var latestBrightness: Float = 0.5
    private let lock = NSLock()

    var currentBrightness: Float {
        lock.lock(); defer { lock.unlock() }
        return latestBrightness
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
        let count = height * stride

        var floatBuf = [Float](repeating: 0, count: count)
        vDSP_vfltu8(lumaBase.assumingMemoryBound(to: UInt8.self), 1, &floatBuf, 1, vDSP_Length(count))

        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))

        lock.lock()
        latestBrightness = mean / 255.0
        lock.unlock()
    }
}

func mapAmbient(_ ambient: Float, minValue: Float, maxValue: Float, invert: Bool) -> Float {
    if invert {
        return maxValue - ambient * (maxValue - minValue)
    }
    return minValue + ambient * (maxValue - minValue)
}

// MARK: - Entry Point

let keyboardBackend = detectKeyboardBackend()
let screenBackend = detectScreenBackend()

if keyboardBackend == nil && screenBackend == nil {
    fputs("Error: no output backends available. Install keyboard and/or screen brightness control tools.\n", stderr)
    exit(1)
}

let semaphore = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { granted in
    if !granted {
        fputs("Camera access denied. Grant access in:\nSystem Settings → Privacy & Security → Camera\n", stderr)
    }
    semaphore.signal()
}
semaphore.wait()

if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
    exit(1)
}

let sampler = BrightnessSampler()
do {
    try sampler.start()
} catch {
    fputs("Camera error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

var history = [Float]()
var lastKeyboard: Float = -1.0
var lastScreen: Float = -1.0

let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigSrc.setEventHandler {
    print("\nRestoring defaults…")
    if keyboardBackend != nil { setKeyboardBrightness(0.5, backend: keyboardBackend) }
    if screenBackend != nil { setScreenBrightness(0.7, backend: screenBackend) }
    sampler.stop()
    exit(0)
}
sigSrc.resume()

print("Ambient backlight running (camera active). Press Ctrl+C to stop.\n")

let startTime = Date()
var lastReminderTime = Date()

while true {
    let now = Date()

    // Enforce optional max runtime
    if maxCameraRuntimeSeconds > 0 && now.timeIntervalSince(startTime) >= maxCameraRuntimeSeconds {
        print("Max camera runtime reached (\(Int(maxCameraRuntimeSeconds)) s). Stopping.")
        if keyboardBackend != nil { setKeyboardBrightness(0.5, backend: keyboardBackend) }
        if screenBackend != nil { setScreenBrightness(0.7, backend: screenBackend) }
        sampler.stop()
        exit(0)
    }

    // Optional periodic reminder while camera is active
    if reminderIntervalSeconds > 0 && now.timeIntervalSince(lastReminderTime) >= reminderIntervalSeconds {
        print("[Reminder] AutoKeyboardDim is currently using the camera to adjust keyboard brightness. Press Ctrl+C to stop.")
        lastReminderTime = now
    }

    let ambient = sampler.currentBrightness
    history.append(ambient)
    if history.count > smoothingWindow { history.removeFirst() }

    let smoothed = history.reduce(0, +) / Float(history.count)
    let keyboardTarget = mapAmbient(smoothed, minValue: keyboardMin, maxValue: keyboardMax, invert: invertKeyboard)
    let screenTarget = mapAmbient(smoothed, minValue: screenMin, maxValue: screenMax, invert: invertScreen)

    if keyboardBackend != nil && abs(keyboardTarget - lastKeyboard) > changeThreshold {
        setKeyboardBrightness(keyboardTarget, backend: keyboardBackend)
        lastKeyboard = keyboardTarget
    }

    if screenBackend != nil && abs(screenTarget - lastScreen) > changeThreshold {
        setScreenBrightness(screenTarget, backend: screenBackend)
        lastScreen = screenTarget
    }

    print(String(format: "Ambient: %.3f → Keyboard: %.0f%% | Screen: %.0f%%",
                 smoothed,
                 keyboardTarget * 100,
                 screenTarget * 100))

    Thread.sleep(forTimeInterval: pollIntervalSeconds)
}
