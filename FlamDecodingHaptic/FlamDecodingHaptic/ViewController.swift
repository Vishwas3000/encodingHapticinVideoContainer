//
//  ViewController.swift
//  FlamDecodingHaptic
//
//  POC: HLS video + AHAP haptics embedded via EXT-X-DATERANGE in the m3u8 manifest.
//  Haptics seek in sync with video seeking.
//
//  Setup:
//    1. python3 assets/embed_haptics_hls.py --input cars.mp4 --ahap haptic.ahap --output hls_output/
//    2. cd hls_output && python3 -m http.server 8080
//    3. For real device: replace IP below with your Mac's LAN address.
//

import AVFoundation
import CoreHaptics
import QuartzCore
import UIKit

class ViewController: UIViewController {

    // MARK: - Config

    private let hlsURLString = "http://192.168.1.87:8080/stream.m3u8"

    // t0: reference clock set when the player is first created.
    // Every log line prints ms elapsed since t0 so you can read the
    // exact ordering of manifest load / AHAP arrival / first video frame.
    private var t0: CFTimeInterval = 0
    private func ms() -> String {
        let elapsed = (CACurrentMediaTime() - t0) * 1000
        return String(format: "%+.0fms", elapsed)
    }
    private var ahapFallbackURLString: String {
        hlsURLString.replacingOccurrences(of: "stream.m3u8", with: "haptic.ahap")
    }

    // MARK: - AV

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var metadataCollector: AVPlayerItemMetadataCollector?   // EXT-X-DATERANGE (primary)
    private var metadataOutput: AVPlayerItemMetadataOutput?          // ID3 TS (secondary)
    private var playerItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?

    // MARK: - Haptics

    private let hapticScheduler = HapticScheduler()
    private var hapticsLoaded = false
    private var fallbackScheduled = false
    private var wasStalled = false
    private var storedAHAPData: Data?              // kept for engine-reset reprepare
    private let driftThreshold: TimeInterval = 0.5 // seconds before resyncing

    // MARK: - UI

    private let playerContainer    = UIView()
    private let timeLabel          = UILabel()
    private let seekSlider         = UISlider()
    private let statusLabel        = UILabel()
    private let playPauseButton    = UIButton(type: .system)
    private let testManifestButton = UIButton(type: .system)  // verification button
    private let metaLogView        = UITextView()

    private var isSeeking = false
    private var totalDuration: Double = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        print("🟢 [VC] viewDidLoad")
        setupUI()
        setupHapticScheduler()
        setupPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = playerContainer.bounds
    }

    deinit {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .black

        // Player container
        playerContainer.backgroundColor = .black
        playerContainer.clipsToBounds = true
        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerContainer)

        // Time label — overlay bottom-left of player
        timeLabel.text = "0:00 / 0:00"
        timeLabel.textColor = .white
        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.addSubview(timeLabel)

        // Seek slider — overlay bottom of player
        seekSlider.minimumValue = 0
        seekSlider.maximumValue = 1
        seekSlider.value = 0
        seekSlider.tintColor = .systemOrange
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.addTarget(self, action: #selector(sliderTouchDown),  for: .touchDown)
        seekSlider.addTarget(self, action: #selector(sliderChanged),    for: .valueChanged)
        seekSlider.addTarget(self, action: #selector(sliderTouchUp),    for: [.touchUpInside, .touchUpOutside])
        playerContainer.addSubview(seekSlider)

        // Status label
        statusLabel.text = "Connecting…"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Play/Pause button
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Pause"
        cfg.baseBackgroundColor = .systemBlue
        playPauseButton.configuration = cfg
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playPauseButton)

        // "Test: Manifest Only" — loads m3u8 but blocks all .ts segments.
        // Proves AHAP arrives from the manifest before any video chunk loads.
        var testCfg = UIButton.Configuration.filled()
        testCfg.title = "Test: Manifest Only"
        testCfg.baseBackgroundColor = .systemOrange
        testCfg.baseForegroundColor = .black
        testManifestButton.configuration = testCfg
        testManifestButton.addTarget(self, action: #selector(runManifestOnlyTest), for: .touchUpInside)
        testManifestButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(testManifestButton)

        // Log view
        metaLogView.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        metaLogView.textColor = .systemGreen
        metaLogView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLogView.isEditable = false
        metaLogView.text = "— log —\n"
        metaLogView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metaLogView)

        NSLayoutConstraint.activate([
            playerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContainer.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.45),

            // Seek slider pinned to player bottom
            seekSlider.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor, constant: 12),
            seekSlider.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor, constant: -12),
            seekSlider.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor, constant: -8),

            timeLabel.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor, constant: 12),
            timeLabel.bottomAnchor.constraint(equalTo: seekSlider.topAnchor, constant: -4),

            statusLabel.topAnchor.constraint(equalTo: playerContainer.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            playPauseButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 120),

            testManifestButton.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 10),
            testManifestButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            metaLogView.topAnchor.constraint(equalTo: testManifestButton.bottomAnchor, constant: 10),
            metaLogView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            metaLogView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            metaLogView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Player Setup

    private func setupHapticScheduler() {
        hapticScheduler.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.statusLabel.text = state
                self?.appendLog("[haptic] \(state)")
            }
        }

        // Fix 1 — engine reset recovery
        // After a phone call / background interruption, CoreHaptics tears down
        // the engine. The resetHandler fires, then calls this block so we can
        // rebuild the pattern player at the current video position.
        hapticScheduler.onEngineReset = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let t = self.player?.currentTime().seconds ?? 0
                print("🔄 [VC] Engine reset — repreparing at \(String(format: "%.2f", t))s")
                self.log("[haptic] 🔄 Engine reset — repreparing @ \(String(format: "%.1f", t))s")
                self.hapticScheduler.reprepare(at: t)
            }
        }
    }

    private func setupPlayer() {
        t0 = CACurrentMediaTime()
        print("🟢 [VC] setupPlayer t0=\(t0) url=\(hlsURLString)")
        log("[\(ms())] Player created — \(hlsURLString)")
        guard let url = URL(string: hlsURLString) else { return }

        let asset     = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        // Primary: AVPlayerItemMetadataCollector for EXT-X-DATERANGE
        let collector = AVPlayerItemMetadataCollector()
        collector.setDelegate(self, queue: .main)
        playerItem.add(collector)
        metadataCollector = collector
        print("🟢 [VC] AVPlayerItemMetadataCollector attached")

        // Secondary: AVPlayerItemMetadataOutput for ID3 in TS
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        playerItem.add(output)
        metadataOutput = output
        print("🟢 [VC] AVPlayerItemMetadataOutput attached")

        player = AVPlayer(playerItem: playerItem)

        // Player item status KVO
        playerItemObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("🟢 [VC] PlayerItem readyToPlay")
                    self?.log("[\(self?.ms() ?? "?")] ✅ PlayerItem readyToPlay")
                    self?.onPlayerReady(item: item)
                case .failed:
                    let msg = item.error?.localizedDescription ?? "unknown"
                    print("🔴 [VC] PlayerItem failed: \(msg)\n  full: \(String(describing: item.error))")
                    self?.log("[player] ❌ \(msg)")
                    self?.statusLabel.text = "Error: \(msg)"
                case .unknown:
                    print("🟡 [VC] PlayerItem unknown")
                    self?.log("[player] ⏳ Loading…")
                @unknown default: break
                }
            }
        }

        // Time control KVO
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                switch p.timeControlStatus {
                case .playing:
                    print("▶️  [VC] playing")
                    self?.log("[\(self?.ms() ?? "?")] ▶️ First video frame / playing")
                    self?.scheduleFallbackIfNeeded()
                    // Fix 2 — stall recovery: resync haptics to video after buffering
                    if self?.wasStalled == true {
                        self?.wasStalled = false
                        let t = p.currentTime().seconds
                        print("▶️  [VC] Resuming after stall — resyncing haptics to \(String(format: "%.2f", t))s")
                        self?.log("[sync] ▶️ Stall recovered — haptics → \(String(format: "%.1f", t))s")
                        self?.hapticScheduler.seek(to: t)
                    }
                case .paused:
                    print("⏸  [VC] paused")
                case .waitingToPlayAtSpecifiedRate:
                    let r = p.reasonForWaitingToPlay?.rawValue ?? "?"
                    print("⏳ [VC] waiting: \(r)")
                    self?.log("[player] ⏳ \(r)")
                    // Only mark as stalled for actual buffer-empty stalls.
                    // AVPlayerWaitingToMinimizeStallsReason is normal post-seek
                    // buffering — pausing haptics here would interrupt events
                    // that are about to fire after the seek.
                    if r.contains("ToMinimizeStalls") == false {
                        self?.wasStalled = true
                        self?.hapticScheduler.pause()
                    }
                @unknown default: break
                }
            }
        }

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        playerContainer.layer.insertSublayer(layer, at: 0)   // below overlays
        playerLayer = layer

        player?.play()
        print("🟢 [VC] play() called")
    }

    private func onPlayerReady(item: AVPlayerItem) {
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return }
        totalDuration = dur
        seekSlider.maximumValue = Float(dur)
        print("🟢 [VC] Duration: \(dur)s")

        // Periodic time observer — updates slider + label, and checks haptic drift every 0.5s
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.updateTimeUI(currentTime: time.seconds)
            self.checkHapticDrift(videoTime: time.seconds)
        }
    }

    // MARK: - Seek UI

    @objc private func sliderTouchDown() {
        isSeeking = true
        print("👆 [VC] Slider touch down")
    }

    @objc private func sliderChanged() {
        let t = Double(seekSlider.value)
        timeLabel.text = "\(formatTime(t)) / \(formatTime(totalDuration))"
    }

    @objc private func sliderTouchUp() {
        let targetTime = Double(seekSlider.value)
        print("👆 [VC] Seek to \(String(format: "%.2f", targetTime))s")
        log("[seek] → \(String(format: "%.2f", targetTime))s")

        let cmTime = CMTime(seconds: targetTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.isSeeking = false
            self?.hapticScheduler.seek(to: targetTime)
            self?.log("[seek] ✅ Haptics seeked to \(String(format: "%.2f", targetTime))s")
        }
    }

    private func updateTimeUI(currentTime: Double) {
        guard !isSeeking, totalDuration > 0 else { return }
        seekSlider.value = Float(currentTime)
        timeLabel.text = "\(formatTime(currentTime)) / \(formatTime(totalDuration))"
    }

    // Fix 3 — periodic drift correction
    // Every 0.5s, compare the video's current time against where we expect
    // the haptic pattern to be (based on wall-clock elapsed since last sync).
    // If drift exceeds the threshold, resync silently.
    private func checkHapticDrift(videoTime: Double) {
        guard hapticScheduler.isReady,
              player?.timeControlStatus == .playing,
              !isSeeking else { return }

        let expected = hapticScheduler.expectedPosition
        let drift    = abs(videoTime - expected)

        if drift > driftThreshold {
            print("⚠️  [sync] Drift \(String(format: "%.3f", drift))s (video=\(String(format: "%.3f", videoTime)) expected=\(String(format: "%.3f", expected))) — resyncing")
            log("[sync] ⚠️ Drift \(String(format: "%.2f", drift))s — correcting")
            hapticScheduler.seek(to: videoTime)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Play / Pause

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            hapticScheduler.pause()
            playPauseButton.configuration?.title = "Play"
            print("⏸ [VC] Paused")
        } else {
            let offset = player.currentTime().seconds
            player.play()
            hapticScheduler.resume()
            playPauseButton.configuration?.title = "Pause"
            print("▶️  [VC] Resumed at \(String(format: "%.2f", offset))s")
            log("[player] Resumed at \(String(format: "%.2f", offset))s")
        }
    }

    // MARK: - Manifest-only verification test

    /// Tap "Test: Manifest Only" to prove AHAP data arrives from the m3u8 manifest
    /// BEFORE any .ts segment is loaded.
    ///
    /// What it does:
    ///  1. Registers DiagnosticURLProtocol which logs every network request.
    ///  2. Sets blockSegments=true so all .ts requests return empty — no video data arrives.
    ///  3. Creates a new AVPlayer pointed at the same HLS URL.
    ///  4. Attaches AVPlayerItemMetadataCollector.
    ///  5. Does NOT call player.play().
    ///
    /// Expected result: AHAP data still arrives via the DATERANGE collector
    /// because the manifest (m3u8) is loaded first and contains the base64 AHAP.
    /// The log will show:
    ///   [DiagProto] 📄 m3u8: stream.m3u8          ← manifest loaded
    ///   [DiagProto] 📦 .ts segment: segment_000.ts ← segment requested (then blocked)
    ///   [+Xms] ✅ AHAP from EXT-X-DATERANGE        ← AHAP received before any segment data
    @objc private func runManifestOnlyTest() {
        print("\n🔬 [TEST] === Manifest-Only Test START ===")
        metaLogView.text = "— manifest-only test —\n"
        t0 = CACurrentMediaTime()

        // Stop existing player
        player?.pause()

        // Register diagnostic protocol — logs + blocks segments
        URLProtocol.registerClass(DiagnosticURLProtocol.self)
        DiagnosticURLProtocol.blockSegments = true
        DiagnosticURLProtocol.onRequest = { [weak self] msg in
            self?.log("[net] \(msg)")
        }

        guard let url = URL(string: hlsURLString) else { return }

        // Use a custom URLSession config so our protocol is active
        let config = URLSessionConfiguration.default
        config.protocolClasses = [DiagnosticURLProtocol.self]

        let asset      = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        // Attach metadata collector only — no output, no play
        let testCollector = AVPlayerItemMetadataCollector()
        testCollector.setDelegate(self, queue: .main)
        playerItem.add(testCollector)

        let testPlayer = AVPlayer(playerItem: playerItem)

        // Observe item status (manifest load = readyToPlay)
        // Explicit types needed because playerItem is a local variable (Swift can't infer root type)
        let obs = playerItem.observe(\.status, options: [.new]) { [weak self] (item: AVPlayerItem, _) in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.log("[\(self?.ms() ?? "?")] ✅ PlayerItem ready (manifest parsed, NO segments)")
                case .failed:
                    self?.log("[\(self?.ms() ?? "?")] ❌ \(item.error?.localizedDescription ?? "?")")
                default: break
                }
            }
        }

        // Hold references
        objc_setAssociatedObject(self, &AssociatedKeys.testPlayer, testPlayer, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(self, &AssociatedKeys.testObs, obs, .OBJC_ASSOCIATION_RETAIN)

        // Do NOT call testPlayer.play() — we want to see if AHAP arrives from manifest alone
        log("[\(ms())] Test player created — segments BLOCKED — waiting for DATERANGE…")
        print("🔬 [TEST] Player created, play() NOT called, segments blocked")
    }

    // MARK: - Fallback direct fetch

    private func scheduleFallbackIfNeeded() {
        guard !fallbackScheduled else { return }
        fallbackScheduled = true
        print("⏱  [VC] Fallback fetch scheduled in 2s from \(ahapFallbackURLString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.hapticsLoaded else {
                print("✅ [VC] Fallback cancelled — haptics already loaded")
                return
            }
            print("⬇️  [VC] Metadata never arrived — falling back to direct fetch")
            self.log("[fallback] Fetching AHAP from server…")
            self.fetchAHAPDirectly()
        }
    }

    private func fetchAHAPDirectly() {
        guard let url = URL(string: ahapFallbackURLString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error {
                print("🔴 [VC] Fallback fetch error: \(error)")
                DispatchQueue.main.async { self?.log("[fallback] ❌ \(error.localizedDescription)") }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("⬇️  [VC] Fallback HTTP \(status), bytes=\(data?.count ?? 0)")
            guard let data, status == 200 else {
                DispatchQueue.main.async { self?.log("[fallback] ❌ HTTP \(status)") }
                return
            }
            DispatchQueue.main.async {
                self?.log("[fallback] ✅ \(data.count) bytes")
                self?.processAHAPData(data)
            }
        }.resume()
    }

    // MARK: - AHAP processing

    private func processAHAPData(_ data: Data) {
        storedAHAPData = data    // keep for engine-reset reprepare
        print("🎵 [AHAP] Processing \(data.count) bytes")
        do {
            let pattern = try JSONDecoder().decode(AHAPPattern.self, from: data)
            print("🎵 [AHAP] Decoded — \(pattern.pattern.count) events")
        } catch {
            print("🔴 [AHAP] Decode error: \(error)")
            log("[AHAP] ❌ \(error.localizedDescription)")
            return
        }
        hapticsLoaded = true
        log("[AHAP] ✅ \(data.count) bytes loaded")
        do {
            try hapticScheduler.prepare(with: data)
            let offset = player?.currentTime().seconds ?? 0
            hapticScheduler.play(at: offset)
            log("[haptic] ▶️ Started at \(String(format: "%.2f", offset))s")
        } catch {
            print("🔴 [AHAP] Haptic engine error: \(error)")
            log("[haptic] ❌ \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async {
            self.metaLogView.text += line + "\n"
            let end = NSRange(location: self.metaLogView.text.count - 1, length: 1)
            self.metaLogView.scrollRangeToVisible(end)
        }
    }

    private func log(_ line: String) {
        print("📋 \(line)")
        appendLog(line)
    }
}

// MARK: - Associated object keys (for manifest-only test references)

private enum AssociatedKeys {
    static var testPlayer = "testPlayer"
    static var testObs    = "testObs"
}

// MARK: - AVPlayerItemMetadataCollectorPushDelegate  (EXT-X-DATERANGE — primary)

extension ViewController: AVPlayerItemMetadataCollectorPushDelegate {

    func metadataCollector(
        _ collector: AVPlayerItemMetadataCollector,
        didCollect groups: [AVDateRangeMetadataGroup],
        indexesOfNewGroups: IndexSet,
        indexesOfModifiedGroups: IndexSet
    ) {
        print("📦 [DATERANGE] didCollect \(groups.count) group(s), hapticsLoaded=\(hapticsLoaded)")
        guard !hapticsLoaded else { return }

        for (gi, group) in groups.enumerated() {
            print("  group[\(gi)] items=\(group.items.count)")
            for item in group.items {
                let key = item.key as? String ?? "\(String(describing: item.key))"
                print("  item key=\(key)")

                guard key == "X-HAPTICS-DATA", let b64 = item.stringValue else { continue }

                print("  ↳ Found X-HAPTICS-DATA, b64 length=\(b64.count)")
                guard let data = Data(base64Encoded: b64) else {
                    print("  ↳ base64 decode failed")
                    log("[DATERANGE] ❌ base64 decode failed")
                    continue
                }
                log("[\(ms())] ✅ AHAP from EXT-X-DATERANGE (\(data.count) bytes)")
                processAHAPData(data)
                return
            }
        }
        print("⚠️  [DATERANGE] No X-HAPTICS-DATA found in groups")
    }
}

// MARK: - AVPlayerItemMetadataOutputPushDelegate  (ID3 in TS — secondary)

extension ViewController: AVPlayerItemMetadataOutputPushDelegate {

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        print("📦 [ID3] didOutputTimedMetadataGroups \(groups.count) group(s), hapticsLoaded=\(hapticsLoaded)")
        guard !hapticsLoaded else { return }

        for group in groups {
            for item in group.items {
                guard item.keySpace == .id3 else { continue }
                let key = item.key as? String ?? "?"
                print("  ID3 item key=\(key)")

                if let json = item.stringValue, json.contains("\"Pattern\""),
                   let data = json.data(using: .utf8) {
                    log("[ID3] ✅ AHAP from TS metadata")
                    processAHAPData(data)
                    return
                }
                if let raw = item.dataValue, let json = parseTXXXPayload(raw),
                   json.contains("\"Pattern\""), let data = json.data(using: .utf8) {
                    log("[ID3] ✅ AHAP from raw TXXX payload")
                    processAHAPData(data)
                    return
                }
            }
        }
    }

    private func parseTXXXPayload(_ data: Data) -> String? {
        guard data.count > 2 else { return nil }
        let enc: String.Encoding = data[0] == 0x03 ? .utf8 : .isoLatin1
        var i = 1
        while i < data.count && data[i] != 0x00 { i += 1 }
        guard i < data.count - 1 else { return nil }
        return String(data: data[(i + 1)...], encoding: enc)
    }
}
