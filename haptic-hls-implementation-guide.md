# HLS Haptic Injection and Playback Guide

This document breaks down the end-to-end pipeline of embedding AHAP haptic patterns into an HLS video stream and reactively extracting and playing them on iOS using `AVFoundation` and `CoreHaptics`.

## 1. Generation (Server-Side)

The generation script (`embed_haptics_hls.py`) processes an MP4 video and an AHAP file to output a segmented HLS stream (`.m3u8` playlist + `.ts` segments) with the haptic data embedded. It does this using three fallback-ready methods:

### Method 1: EXT-X-DATERANGE in Manifest (Primary, Seek-Safe)
The script calculates the total duration of the media and injects an `#EXT-X-DATERANGE` tag into the `#EXTM3U` playlist (`stream.m3u8`).
- An `X-HAPTICS-URL` attribute is added, pointing to a sidecar file (`haptic.ahap`) containing the complete AHAP JSON pattern.
- This represents a highly reliable approach for VOD (Video on Demand) where seeking is important, because the client learns about the haptic location before downloading any `.ts` segments.

### Method 2: ID3 Timed Metadata PES inside MPEG-TS (Live Streaming, Secondary)
For low-latency or live streaming cases where `EXT-X-DATERANGE` may not be appropriate, the script manually injects an **ID3** metadata packet into the first video segment (`segment_000.ts`).
- It extracts the `PAT` (Program Association Table) and `PMT` (Program Map Table) from the `.ts` segment.
- It allocates a new PID and injects a new metadata stream (`stream_type=0x15`).
- It parses the AHAP file and packages it inside an ID3 `TXXX` (User defined text information) frame.
- It writes the ID3 payload as a PES (Packetized Elementary Stream) packet exactly at `PTS=0` (Presentation Time Stamp zero) so it synchronizes with the first video frame.

### Method 3: Sidecar AHAP (Fallback)
A physical `haptic.ahap` is placed in the output directory.

---

## 2. Consumption (iOS / Xcode)

The Xcode project (`FlamDecodingHaptic`) provides the client-side implementation across three main areas: Extracting the metadata, Scheduling the haptics, and Synchronizing playback state.

### Extracting the Metadata (`ViewController.swift`)

The player defines two simultaneous metadata listeners attached to the `AVPlayerItem`:

1. **`AVPlayerItemMetadataCollector` (Primary — EXT-X-DATERANGE)**
   This collector listens for date range metadata in the manifest. When it detects the `#EXT-X-DATERANGE` block containing the `X-HAPTICS-URL` key, it:
   - Resolves the relative URL of the AHAP sidecar file. 
   - Downloads the AHAP file directly using an async `URLSession` data task.
   - Decodes the JSON to `AHAPPattern`.

2. **`AVPlayerItemMetadataOutput` (Secondary — ID3 PES)**
   This observer demuxes inside the `.ts` stream to intercept the `TXXX` ID3 tag injected at presentation time zero (`PTS=0`). Because this is intrinsically linked to the PTS, it's highly robust against seeking. Once the video playback reaches the timestamp, it retrieves the JSON payload and builds the `AHAPPattern`.

If the haptic payload fails to trigger, a 2-second timeout (`scheduleFallbackIfNeeded()`) acts as a safeguard to fetch the `.ahap` manually using a fallback endpoint.

### Scheduling and Playback (`HapticScheduler.swift`)

Once extracted, the raw data is passed into a single `HapticScheduler` responsible for interacting with the hardware.

- **`prepare(with: ahapData)`:** 
  It temporarily writes the AHAP to a local file (since `CHHapticPattern` requires a file/URL), instantiates a `CHHapticPattern`, and creates a `CHHapticAdvancedPatternPlayer`. The pattern is natively scheduled sequentially over time.

- **Playback Controls:**
  The scheduler encapsulates matching control over `stop()`, `pause()`, and `resume()`. More importantly, it uses **`seek(to: time)`**, passing the video offset to `patternPlayer.seek(toOffset:)`.

- **Handling Engine Interruption:**
  The iOS `CoreHaptics` engine can shut down during backgrounding or phone calls. `HapticScheduler` listens to `resetHandler` and `stoppedHandler` and calls a callback triggering `ViewController` to reprepare the player right at the video's current `currentTime()`.

### Continuous Synchronization (`ViewController.swift`)

The crucial detail in the player view is connecting video seeking and drifting to the Haptic scheduler.

- **Seek Slider (`sliderTouchUp`):**
  When the user seeks the `AVPlayer`, `ViewController` listens via `player.seek(to:)`. Since it's synced with a single `AHAPPattern` player rather than chunked ID3 tags for every 4-second segment, it just relays the new timestamp directly to the `HapticScheduler` via `scheduler.seek(to: targetTime)`.

- **Drift Correction (`checkHapticDrift`):**
  An `AVPlayer` periodic time observer runs every 0.5 seconds. It calculates the offset between the exact `videoTime` timestamp and the estimated play position of the `CHHapticAdvancedPatternPlayer` (based on system wall-clock elapsed time).
  If it strays by more than `0.5s` (driftThreshold), it seamlessly resyncs the haptic engine back to the video frame via `scheduler.seek(to: videoTime)`.

- **Stall Recovery (`timeControlStatus` Observer):**
  If the video buffers (`.waitingToPlayAtSpecifiedRate`), it pauses the haptics. When playback resumes, it recovers from the stall and re-aligns the timestamps.

## Summary

This architecture solves the complexity of haptic tracking by separating extraction and execution:
1. Embed references (`EXT-X-DATERANGE`) and physical tags (`ID3 TXXX`) at `t=0` to guarantee the device gains knowledge of the `AHAP` pattern as early as possible.
2. Rely on a single Continuous Pattern approach (`CHHapticAdvancedPatternPlayer`) to manage timelines natively, avoiding the stutter of chopping haptic patterns up strictly per-chunk. 
3. Bridge synchronization using regular drift telemetry checks (`checkHapticDrift`), so they remain coupled dynamically throughout buffer stalls and user scrubbing.
