import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit
import IOKit.hid
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

// MARK: - IOKit Keyboard Backlight

private var ioService: io_service_t = IO_OBJECT_NULL
private var ioConnect: io_connect_t = IO_OBJECT_NULL
private let kSetLEDBrightness: UInt32 = 1

func openIOKitConnection() -> Bool {
    ioService = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleLMUController")
    )
    guard ioService != IO_OBJECT_NULL else {
        fputs("Warning: AppleLMUController not found. Keyboard control disabled.\n", stderr)
        return false
    }
    let kr = IOServiceOpen(ioService, mach_task_self_, 0, &ioConnect)
    guard kr == KERN_SUCCESS else {
        fputs("Warning: IOServiceOpen failed (\(kr)). Keyboard control disabled.\n", stderr)
        return false
    }
    return true
}

func closeIOKitConnection() {
    if ioConnect != IO_OBJECT_NULL { IOServiceClose(ioConnect) }
    if ioService != IO_OBJECT_NULL { IOObjectRelease(ioService) }
}

func setKeyboardBrightness(_ value: Float) {
    guard ioConnect != IO_OBJECT_NULL else { return }
    let clamped = min(max(value, keyboardMin), keyboardMax)
    var input = UInt64(clamped * 0xfff)
    var output = UInt64(0)
    var outputCount: UInt32 = 1

    let kr = IOConnectCallScalarMethod(
        ioConnect,
        kSetLEDBrightness,
        &input, 1,
        &output, &outputCount
    )
    if kr != KERN_SUCCESS {
        fputs("Warning: Failed to set keyboard brightness (\(kr))\n", stderr)
    }
}

// MARK: - Screen Brightness Backends (CLI)

struct ScreenBackend {
    let name: String
    let commandBuilder: (Float) -> [String]
}

func commandExists(_ command: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [command]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func detectScreenBackend() -> ScreenBackend? {
    if commandExists("brightness") {
        print("Using screen backend: brightness")
        return ScreenBackend(name: "brightness") { value in
            ["brightness", "-l", String(format: "%.3f", value)]
        }
    }

    if commandExists("ddcctl") {
        print("Using screen backend: ddcctl")
        return ScreenBackend(name: "ddcctl") { value in
            ["ddcctl", "-b", String(Int(value * 100))]
        }
    }

    fputs("Warning: No screen backend found (brightness/ddcctl). Screen control disabled.\n", stderr)
    return nil
}

@discardableResult
func runCommand(_ args: [String]) -> Bool {
    guard let executable = args.first else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + args.dropFirst()

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        fputs("Warning: failed to run \(args.joined(separator: " ")): \(error.localizedDescription)\n", stderr)
        return false
    }
}

func setScreenBrightness(_ value: Float, backend: ScreenBackend?) {
    guard let backend else { return }
    let clamped = min(max(value, 0.0), 1.0)
    let ok = runCommand(backend.commandBuilder(clamped))
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

let keyboardEnabled = openIOKitConnection()
let screenBackend = detectScreenBackend()

if !keyboardEnabled && screenBackend == nil {
    fputs("Error: no output backends available. Install keyboard and/or screen brightness control tools.\n", stderr)
    exit(1)
}

let semaphore = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { granted in
    if !granted {
        fputs("Camera access denied. Grant access in:\nSystem Settings → Privacy & Security → Camera\n", stderr)
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()

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
    if keyboardEnabled { setKeyboardBrightness(0.5) }
    if screenBackend != nil { setScreenBrightness(0.7, backend: screenBackend) }
    sampler.stop()
    closeIOKitConnection()
    exit(0)
}
sigSrc.resume()

print("Ambient backlight running. Press Ctrl+C to stop.\n")

while true {
    let ambient = sampler.currentBrightness
    history.append(ambient)
    if history.count > smoothingWindow { history.removeFirst() }

    let smoothed = history.reduce(0, +) / Float(history.count)
    let keyboardTarget = mapAmbient(smoothed, minValue: keyboardMin, maxValue: keyboardMax, invert: invertKeyboard)
    let screenTarget = mapAmbient(smoothed, minValue: screenMin, maxValue: screenMax, invert: invertScreen)

    if keyboardEnabled && abs(keyboardTarget - lastKeyboard) > changeThreshold {
        setKeyboardBrightness(keyboardTarget)
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
