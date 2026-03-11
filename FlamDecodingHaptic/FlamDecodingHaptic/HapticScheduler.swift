//
//  HapticScheduler.swift
//  FlamDecodingHaptic
//

import CoreHaptics
import Foundation
import QuartzCore   // CACurrentMediaTime

class HapticScheduler {

    private var engine: CHHapticEngine?
    private var patternPlayer: CHHapticAdvancedPatternPlayer?
    private var cachedPattern: CHHapticPattern?   // kept so we can rebuild after engine reset

    private var engineStarted = false
    private(set) var isReady = false

    // Wall-clock time when haptics last started/seeked — used for drift detection
    private(set) var hapticStartWallTime: TimeInterval = 0
    private(set) var hapticStartOffset:   TimeInterval = 0   // video position at that moment

    var onStateChange: ((String) -> Void)?

    /// Called when the haptic engine resets (interruption, phone call, etc.).
    /// ViewController should respond by calling reprepare(at:) with current video time.
    var onEngineReset: (() -> Void)?

    // MARK: - Init

    init() {
        let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        print("🎛  [Haptic] Hardware haptics supported: \(supported)")
        guard supported else {
            onStateChange?("Device does not support haptics")
            return
        }
        do {
            engine = try CHHapticEngine()
            print("🟢 [Haptic] Engine object created")
        } catch {
            print("🔴 [Haptic] Failed to create CHHapticEngine: \(error)")
            return
        }

        engine?.resetHandler = { [weak self] in
            print("🔄 [Haptic] Engine reset (interruption) — invalidating player")
            self?.engineStarted = false
            self?.isReady       = false
            self?.patternPlayer = nil          // stale after reset, must rebuild
            self?.startEngine()
            self?.onEngineReset?()             // tell VC to reprepare at current time
        }
        engine?.stoppedHandler = { reason in
            print("⏹  [Haptic] Engine stopped: \(reason.rawValue)")
        }

        startEngine()
    }

    // MARK: - Engine start

    private func startEngine() {
        print("🎛  [Haptic] startEngine()")
        engine?.start(completionHandler: { [weak self] error in
            if let error {
                print("🔴 [Haptic] Engine start failed: \(error)")
                self?.onStateChange?("Engine error: \(error.localizedDescription)")
                return
            }
            self?.engineStarted = true
            print("🟢 [Haptic] Engine ready")
        })
    }

    // MARK: - Prepare / Reprepare

    /// Initial load: parse AHAP data and create the pattern player.
    func prepare(with ahapData: Data) throws {
        print("🎛  [Haptic] prepare() \(ahapData.count) bytes, engineStarted=\(engineStarted)")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".ahap")
        try ahapData.write(to: tempURL)
        cachedPattern = try CHHapticPattern(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        print("🟢 [Haptic] CHHapticPattern cached")

        if !engineStarted {
            let sema = DispatchSemaphore(value: 0)
            engine?.start { [weak self] error in
                if error == nil { self?.engineStarted = true }
                sema.signal()
            }
            sema.wait()
        }

        patternPlayer = try engine?.makeAdvancedPlayer(with: cachedPattern!)
        isReady = true
        print("🟢 [Haptic] Pattern player created — isReady=true")
        onStateChange?("Haptics ready (\(ahapData.count) bytes)")
    }

    /// Called after engine reset: rebuild the pattern player from the cached pattern
    /// and resume at `offset` (current video position).
    func reprepare(at offset: TimeInterval) {
        print("🔄 [Haptic] reprepare(at: \(String(format: "%.3f", offset))s)")
        guard let pattern = cachedPattern else {
            print("⚠️  [Haptic] No cached pattern — cannot reprepare")
            return
        }
        guard engineStarted else {
            print("⚠️  [Haptic] Engine not ready yet — reprepare deferred")
            // Engine is still starting; once it finishes the completion handler
            // calls onEngineReset again — VC will retry.
            return
        }
        do {
            patternPlayer = try engine?.makeAdvancedPlayer(with: pattern)
            isReady = true
            print("🟢 [Haptic] Pattern player rebuilt")
            play(at: offset)
        } catch {
            print("🔴 [Haptic] reprepare failed: \(error)")
        }
    }

    // MARK: - Playback

    func play(at offset: TimeInterval = 0) {
        print("▶️  [Haptic] play(at: \(String(format: "%.3f", offset))s) isReady=\(isReady)")
        guard isReady else { return }
        do {
            if offset > 0 { try patternPlayer?.seek(toOffset: offset) }
            try patternPlayer?.start(atTime: CHHapticTimeImmediate)
            recordPlaybackStart(offset: offset)
            onStateChange?("Playing haptics @ \(String(format: "%.2f", offset))s")
        } catch {
            print("🔴 [Haptic] play() error: \(error)")
            onStateChange?("Haptic play error: \(error.localizedDescription)")
        }
    }

    func pause() {
        print("⏸  [Haptic] pause()")
        try? patternPlayer?.pause(atTime: CHHapticTimeImmediate)
    }

    func resume() {
        print("▶️  [Haptic] resume() isReady=\(isReady)")
        guard isReady else { return }
        try? patternPlayer?.resume(atTime: CHHapticTimeImmediate)
        // Restore drift tracking from where we paused
        hapticStartWallTime = CACurrentMediaTime()
    }

    func seek(to time: TimeInterval) {
        print("⏩ [Haptic] seek(to: \(String(format: "%.3f", time))s) isReady=\(isReady)")
        guard isReady, let pattern = cachedPattern else {
            print("⚠️  [Haptic] Not ready or no pattern — seek() ignored")
            return
        }
        do {
            // Stop old player first
            try patternPlayer?.stop(atTime: CHHapticTimeImmediate)

            // Recreate a fresh player from the cached pattern.
            // Avoids state-machine timing issues where the engine hasn't
            // fully processed stop() before seek(toOffset:) arrives.
            patternPlayer = try engine?.makeAdvancedPlayer(with: pattern)
            print("⏩ [Haptic] Fresh player created for seek")

            try patternPlayer?.seek(toOffset: time)
            try patternPlayer?.start(atTime: CHHapticTimeImmediate)
            recordPlaybackStart(offset: time)
            print("▶️  [Haptic] Playback started from \(String(format: "%.3f", time))s")
            onStateChange?("Haptics @ \(String(format: "%.1f", time))s")
        } catch {
            print("🔴 [Haptic] seek() error: \(error)")
        }
    }

    func stop() {
        print("⏹  [Haptic] stop()")
        try? patternPlayer?.stop(atTime: CHHapticTimeImmediate)
        isReady = false
    }

    // MARK: - Drift tracking

    private func recordPlaybackStart(offset: TimeInterval) {
        hapticStartOffset   = offset
        hapticStartWallTime = CACurrentMediaTime()
    }

    /// Expected haptic position based on wall-clock elapsed time since last sync.
    var expectedPosition: TimeInterval {
        guard isReady else { return 0 }
        return hapticStartOffset + (CACurrentMediaTime() - hapticStartWallTime)
    }
}
