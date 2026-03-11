//
//  ViewController.swift
//  FlamDecodingHaptic
//
//  POC: HLS + MP4 video with synchronized AHAP haptics.
//
//  HLS mode:
//    1. python3 assets/embed_haptics_hls.py --input cars.mp4 --ahap haptic.ahap --output hls_output/
//    2. cd hls_output && python3 -m http.server 8080
//    3. For real device: replace IP below with your Mac's LAN address.
//
//  MP4 mode:
//    Add cars.mp4 and haptic.ahap to the Xcode project bundle (drag-drop, "Copy if needed").
//    Set playbackMode = .mp4 below.
//

import AVFoundation
import CoreHaptics
import QuartzCore
import UIKit

class ViewController: UIViewController {

    // MARK: - Config

    enum PlaybackMode { case hls, mp4 }
    private var playbackMode: PlaybackMode = .hls

    private let hlsURLString     = "http://192.168.1.17:8080/stream.m3u8"
    private let mp4URLString    = "http://192.168.1.17:8080/output_with_haptics.mp4"             // cars.mp4 in bundle
    private let ahapBundleFile   = "haptic"           // haptic.ahap in bundle

    // t0: reference clock set when the player is first created.
    // Every log line prints ms elapsed since t0 so you can read the
    // exact ordering of manifest load / AHAP arrival / first video frame.
    private var t0: CFTimeInterval = 0
    private func ms() -> String {
        let elapsed = (CACurrentMediaTime() - t0) * 1000
        return String(format: "%+.0fms", elapsed)
    }
    // HLS-only: fallback direct fetch URL (same server, haptic.ahap next to stream.m3u8)
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

    private let modeSegment        = UISegmentedControl(items: ["HLS", "MP4"])
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
        player?.pause()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .black

        // Mode toggle — HLS / MP4
        modeSegment.selectedSegmentIndex = 0
        modeSegment.selectedSegmentTintColor = .systemBlue
        modeSegment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        modeSegment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        modeSegment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeSegment)

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
            modeSegment.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            modeSegment.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeSegment.widthAnchor.constraint(equalToConstant: 160),

            playerContainer.topAnchor.constraint(equalTo: modeSegment.bottomAnchor, constant: 8),
            playerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContainer.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.40),

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

    // MARK: - Mode switching

    @objc private func modeChanged() {
        playbackMode = modeSegment.selectedSegmentIndex == 0 ? .hls : .mp4
        print("🔀 [VC] Switching to \(playbackMode)")
        log("[mode] → \(playbackMode == .hls ? "HLS" : "MP4")")
        tearDownPlayer()
        setupPlayer()
    }

    private func tearDownPlayer() {
        // Stop haptics
        hapticScheduler.stop()
        hapticsLoaded      = false
        fallbackScheduled  = false
        wasStalled         = false
        storedAHAPData     = nil

        // Remove time observer before releasing player
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil

        // Cancel KVO
        playerItemObservation  = nil
        timeControlObservation = nil

        // Pause and release
        player?.pause()
        player = nil

        // Remove old player layer
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil

        // Reset metadata delegates
        metadataCollector = nil
        metadataOutput    = nil

        // Reset UI
        seekSlider.value      = 0
        seekSlider.maximumValue = 1
        totalDuration         = 0
        timeLabel.text        = "0:00 / 0:00"
        statusLabel.text      = "Loading…"
        playPauseButton.configuration?.title = "Pause"
        metaLogView.text      = "— log —\n"
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
                let t         = self.player?.currentTime().seconds ?? 0
                let isPlaying = self.player?.timeControlStatus == .playing
                print("🔄 [VC] Engine reset — repreparing at \(String(format: "%.2f", t))s, play=\(isPlaying)")
                self.log("[haptic] 🔄 Engine reset @ \(String(format: "%.1f", t))s")
                self.hapticScheduler.reprepare(at: t, play: isPlaying)
            }
        }
    }

    private func setupPlayer() {
        t0 = CACurrentMediaTime()
        switch playbackMode {
        case .hls: setupHLSPlayer()
        case .mp4: setupMP4Player()
        }
    }

    // MARK: - HLS player

    private func setupHLSPlayer() {
        print("🟢 [VC] setupHLSPlayer url=\(hlsURLString)")
        log("[\(ms())] HLS player — \(hlsURLString)")
        guard let url = URL(string: hlsURLString) else { return }

        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))

        // Primary: AVPlayerItemMetadataCollector for EXT-X-DATERANGE
        let collector = AVPlayerItemMetadataCollector()
        collector.setDelegate(self, queue: .main)
        playerItem.add(collector)
        metadataCollector = collector

        // Secondary: AVPlayerItemMetadataOutput for ID3 in TS
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        playerItem.add(output)
        metadataOutput = output

        player = AVPlayer(playerItem: playerItem)
        attachPlayerObservers(to: playerItem, scheduleFallback: true)
        attachPlayerLayer()
        player?.play()
        print("🟢 [VC] HLS play() called")
    }

    // MARK: - MP4 player

    private var mp4AHAPFallbackURLString: String {
        mp4URLString.replacingOccurrences(of: "output_with_haptics.mp4", with: "haptic.ahap")
    }

    private func setupMP4Player() {
        guard let videoURL = URL(string: mp4URLString) else {
            log("[mp4] ❌ Invalid URL: \(mp4URLString)")
            statusLabel.text = "Invalid MP4 URL"
            return
        }

        print("🟢 [VC] setupMP4Player url=\(videoURL.lastPathComponent)")
        log("[\(ms())] MP4 player — \(videoURL.lastPathComponent)")

        let asset      = AVURLAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        attachPlayerObservers(to: playerItem, scheduleFallback: false)
        attachPlayerLayer()

        // Read AHAP from the embedded 'mett' timed metadata track
        readHapticTrack(from: asset)

        player?.play()
        print("🟢 [VC] MP4 play() called")
    }

    /// Read AHAP JSON from the ISOBMFF 'mett' timed metadata track injected by embed_haptics_hls.py.
    ///
    /// Strategy:
    ///   • Local file:// URL  → AVAssetReader reads the mett track sample directly.
    ///   • HTTP/HTTPS URL     → Parse moov from the file header, find the mett track's
    ///                          stco offset + stsz size, then fetch just those bytes with
    ///                          a Range request.  Falls back to sidecar if parsing fails.
    private func readHapticTrack(from asset: AVURLAsset) {
        Task {
            // ── Local file: use AVAssetReader ────────────────────────────────────
            if asset.url.isFileURL {
                await readMettTrackLocal(asset: asset)
                return
            }

            // ── Remote URL: parse moov header, then Range-fetch the AHAP bytes ──
            log("[\(ms())] 📎 Fetching AHAP from mett track (range request)…")
            let fetched = await fetchAHAPFromRemoteMett(url: asset.url)
            if fetched { return }

            // Fallback to sidecar
            log("[mp4] ⚠️ mett range parse failed — fetching sidecar…")
            await fetchAHAPSidecar()
        }
    }

    /// AVAssetReader path — only valid for local file:// assets.
    private func readMettTrackLocal(asset: AVURLAsset) async {
        do {
            let allTracks = try await asset.load(.tracks)
            let mettTrack = allTracks.first { $0.mediaType != .video && $0.mediaType != .audio }

            guard let track = mettTrack else {
                log("[mp4] ⚠️ No mett track in local file — fetching sidecar…")
                await fetchAHAPSidecar()
                return
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()

            var ahapData = Data()
            while let sample = output.copyNextSampleBuffer() {
                if let buf = CMSampleBufferGetDataBuffer(sample) {
                    var len = 0
                    var ptr: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(buf, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &len, dataPointerOut: &ptr)
                    if let p = ptr, len > 0 { ahapData.append(Data(bytes: p, count: len)) }
                }
            }

            await MainActor.run {
                if ahapData.isEmpty {
                    self.log("[mp4] ⚠️ mett track empty — fetching sidecar…")
                    Task { await self.fetchAHAPSidecar() }
                } else {
                    self.log("[\(self.ms())] ✅ AHAP from mett track (\(ahapData.count) bytes)")
                    self.processAHAPData(ahapData)
                }
            }
        } catch {
            print("🔴 [MP4] local mett read error: \(error)")
            await fetchAHAPSidecar()
        }
    }

    /// HTTP path: download just the moov header, parse mett stco/stsz, then
    /// fetch the AHAP sample bytes with a single Range request.
    /// Returns true if AHAP was successfully loaded.
    private func fetchAHAPFromRemoteMett(url: URL) async -> Bool {
        // Step 1 — download the first 512 KB (covers ftyp + moov for most files)
        let headerSize = 512 * 1024
        var headerReq  = URLRequest(url: url)
        headerReq.setValue("bytes=0-\(headerSize - 1)", forHTTPHeaderField: "Range")

        guard let (headerData, _) = try? await URLSession.shared.data(for: headerReq),
              headerData.count > 16 else { return false }

        // Step 2 — locate moov inside the downloaded header
        guard let (ahapOffset, ahapSize) = parseMettStcoStsz(from: headerData) else {
            print("⚠️  [MP4] Could not parse mett stco/stsz from moov header")
            return false
        }
        print("🟢 [MP4] mett stco offset=\(ahapOffset) size=\(ahapSize)")

        // Step 3 — Range-fetch the AHAP sample bytes
        var ahapReq = URLRequest(url: url)
        let endByte = ahapOffset + ahapSize - 1
        ahapReq.setValue("bytes=\(ahapOffset)-\(endByte)", forHTTPHeaderField: "Range")

        guard let (ahapData, resp) = try? await URLSession.shared.data(for: ahapReq),
              (resp as? HTTPURLResponse)?.statusCode == 206,
              !ahapData.isEmpty else { return false }

        print("🟢 [MP4] AHAP fetched via Range: \(ahapData.count) bytes")
        await MainActor.run {
            self.log("[\(self.ms())] ✅ AHAP from mett range (\(ahapData.count) bytes)")
            self.processAHAPData(ahapData)
        }
        return true
    }

    /// Parse the stco and stsz boxes belonging to the 'mett' handler track
    /// inside raw ISOBMFF bytes (the beginning of a faststart MP4 file).
    /// Returns (ahapFileOffset, ahapByteCount) or nil if not found.
    ///
    /// stbl box order (ISO 14496-12):  stsd → stts → stsc → stsz → stco
    /// So stsz always appears BEFORE stco — we search in that order.
    private func parseMettStcoStsz(from data: Data) -> (Int, Int)? {
        // 1. Find the 'mett' handler type string in the hdlr box.
        //    This marks the start of our injected metadata track's mdia.
        guard let mettRange = data.range(of: Data("mett".utf8)) else {
            print("⚠️  parseMettStcoStsz: 'mett' not found in header bytes")
            return nil
        }
        let afterMett = mettRange.upperBound

        // 2. Find stsz AFTER the mett hdlr.
        //    stsz FullBox layout (offsets from box start):
        //      [0 ] size          (4 bytes)
        //      [4 ] 'stsz'        (4 bytes)
        //      [8 ] version+flags (4 bytes)  ← FullBox header
        //      [12] sample_size   (4 bytes)  ← 0 = variable per-sample sizes
        //      [16] sample_count  (4 bytes)
        //      [20] entry_size[0] (4 bytes)  ← first (and only) entry for mett
        guard let stszRange = data.range(of: Data("stsz".utf8),
                                          in: afterMett..<data.endIndex),
              stszRange.lowerBound >= 4 else {
            print("⚠️  parseMettStcoStsz: 'stsz' not found after mett")
            return nil
        }
        let stszBoxStart = stszRange.lowerBound - 4
        guard stszBoxStart + 24 <= data.count else { return nil }

        let uniformSampleSize = data.readUInt32BE(at: stszBoxStart + 12)
        let ahapSize: Int
        if uniformSampleSize > 0 {
            ahapSize = Int(uniformSampleSize)           // all samples same size
        } else {
            ahapSize = Int(data.readUInt32BE(at: stszBoxStart + 20))  // entry_size[0]
        }
        guard ahapSize > 0 else { return nil }

        // 3. Find stco AFTER stsz.
        //    stco FullBox layout:
        //      [0 ] size          (4 bytes)
        //      [4 ] 'stco'        (4 bytes)
        //      [8 ] version+flags (4 bytes)
        //      [12] entry_count   (4 bytes)
        //      [16] offset[0]     (4 bytes)  ← absolute file offset of AHAP bytes
        guard let stcoRange = data.range(of: Data("stco".utf8),
                                          in: stszRange.upperBound..<data.endIndex),
              stcoRange.lowerBound >= 4 else {
            print("⚠️  parseMettStcoStsz: 'stco' not found after stsz")
            return nil
        }
        let stcoBoxStart = stcoRange.lowerBound - 4
        guard stcoBoxStart + 20 <= data.count else { return nil }

        let entryCount = data.readUInt32BE(at: stcoBoxStart + 12)
        guard entryCount >= 1 else { return nil }
        let ahapOffset = Int(data.readUInt32BE(at: stcoBoxStart + 16))

        return (ahapOffset, ahapSize)
    }

    /// Fallback for MP4 mode: fetch haptic.ahap from the same server as the MP4.
    @MainActor
    private func fetchAHAPSidecar() {
        guard let url = URL(string: mp4AHAPFallbackURLString) else { return }
        log("[mp4] Fetching sidecar \(url.lastPathComponent)…")
        fetchAHAP(from: url, tag: "mp4-sidecar")
    }

    // MARK: - Shared player setup

    private func attachPlayerLayer() {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        playerContainer.layer.insertSublayer(layer, at: 0)
        playerLayer = layer
    }

    private func attachPlayerObservers(to playerItem: AVPlayerItem, scheduleFallback: Bool) {
        playerItemObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("🟢 [VC] PlayerItem readyToPlay")
                    self?.log("[\(self?.ms() ?? "?")] ✅ PlayerItem readyToPlay")
                    self?.onPlayerReady(item: item)
                case .failed:
                    let msg = item.error?.localizedDescription ?? "unknown"
                    print("🔴 [VC] PlayerItem failed: \(msg)")
                    self?.log("[player] ❌ \(msg)")
                    self?.statusLabel.text = "Error: \(msg)"
                case .unknown:
                    print("🟡 [VC] PlayerItem unknown")
                    self?.log("[player] ⏳ Loading…")
                @unknown default: break
                }
            }
        }

        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                switch p.timeControlStatus {
                case .playing:
                    print("▶️  [VC] playing")
                    self?.log("[\(self?.ms() ?? "?")] ▶️ playing")
                    if scheduleFallback { self?.scheduleFallbackIfNeeded() }
                    if self?.wasStalled == true {
                        self?.wasStalled = false
                        let t = p.currentTime().seconds
                        self?.log("[sync] ▶️ Stall recovered — haptics → \(String(format: "%.1f", t))s")
                        self?.hapticScheduler.seek(to: t)
                    }
                case .paused:
                    print("⏸  [VC] paused")
                case .waitingToPlayAtSpecifiedRate:
                    let r = p.reasonForWaitingToPlay?.rawValue ?? "?"
                    print("⏳ [VC] waiting: \(r)")
                    self?.log("[player] ⏳ \(r)")
                    // Only pause haptics for a real buffer-empty stall.
                    // "ToMinimizeStalls" = normal post-seek buffering (not a stall).
                    // "NoItemToPlay"     = transient init state (not a stall).
                    let isRealStall = !r.contains("ToMinimizeStalls") && !r.contains("NoItemToPlay")
                    if isRealStall {
                        self?.wasStalled = true
                        self?.hapticScheduler.pause()
                    }
                @unknown default: break
                }
            }
        }
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
            if hapticScheduler.isReady {
                hapticScheduler.resume()
            } else {
                // Engine stopped while paused — rebuild and start
                print("🔄 [VC] Engine was down on resume — repreparing at \(String(format: "%.2f", offset))s")
                hapticScheduler.reprepare(at: offset, play: true)
            }
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
        fetchAHAP(from: url, tag: "fallback")
    }

    private func fetchAHAP(from url: URL, tag: String = "DATERANGE") {
        print("⬇️  [VC] Fetching AHAP from \(url)")
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error {
                print("🔴 [VC] AHAP fetch error: \(error)")
                DispatchQueue.main.async { self?.log("[\(tag)] ❌ \(error.localizedDescription)") }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("⬇️  [VC] AHAP HTTP \(status), bytes=\(data?.count ?? 0)")
            guard let data, status == 200 else {
                DispatchQueue.main.async { self?.log("[\(tag)] ❌ HTTP \(status)") }
                return
            }
            DispatchQueue.main.async {
                self?.log("[\(tag)] ✅ \(data.count) bytes")
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

                guard key == "X-HAPTICS-URL", let urlString = item.stringValue else { continue }

                print("  ↳ Found X-HAPTICS-URL: \(urlString)")
                // Resolve relative URL against the HLS manifest base
                let base    = URL(string: hlsURLString)!.deletingLastPathComponent()
                let ahapURL = URL(string: urlString, relativeTo: base)?.absoluteURL
                    ?? base.appendingPathComponent(urlString)
                log("[\(ms())] 📎 AHAP URL from manifest — fetching…")
                fetchAHAP(from: ahapURL)
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

// MARK: - Data helper

private extension Data {
    /// Read a big-endian UInt32 at the given byte offset.
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var val: UInt32 = 0
            memcpy(&val, ptr.baseAddress!.advanced(by: offset), 4)
            return val.bigEndian
        }
    }
}
