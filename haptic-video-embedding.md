# Embedding & Extracting Haptic Data in Video Containers

---

## Overview

Your AHAP JSON needs to be treated as **timed metadata** — not static file metadata. Each haptic event has a precise `Time` value, so the container must carry that payload in a way that a player can retrieve it either pre-playback (for scheduling) or at a specific timeline position. Three strategies apply, one per format.

---

## Strategy 1 — MP4: Private Timed Metadata Track

### Concept

ISO BMFF (MP4) supports additional tracks beyond video/audio. You add a **timed metadata track** with handler type `mett` and a MIME type of `application/json`. The full AHAP JSON is embedded as a single sample at `t=0` with a duration matching the video. On playback, the player reads the track and you have the full JSON to schedule haptics client-side.

> **Important caveat:** AVFoundation's `AVAssetWriterInputMetadataAdaptor` supports timed metadata tracks natively only in `.mov` (QuickTime) containers. For `.mp4` you must use **Bento4** or **GPAC/MP4Box** to inject the track after the fact.

### Embedding (Tooling — ffmpeg + MP4Box)

The cleanest cross-platform approach uses **GPAC's MP4Box**:

```bash
# Step 1: Write the full AHAP JSON to a file
echo '{ "Version": 1, "Pattern": [...] }' > haptics.json

# Step 2: Inject as a timed text/metadata track
# MP4Box wraps the JSON as a single timed sample covering the full duration
MP4Box -add haptics.json:hdlr=meta:mime=application/json:lang=und \
       -new output.mp4 -add input.mp4

# Or Bento4 approach: use mp4mux with a custom track
mp4mux --track haptics.json#mime=application/json input.mp4 output_with_haptics.mp4
```

Alternatively, with **ffmpeg** you can embed the AHAP as static userdata (non-timed, but sufficient for VOD):

```bash
ffmpeg -i input.mp4 \
  -metadata:s:v:0 "haptics=$(cat haptics.json)" \
  -codec copy output.mp4
```

> For a timed track (preferred), use the MP4Box route. For a simple blob, ffmpeg userdata is easier.

### Embedding (iOS — .mov container, then remux)

For apps generating video, use `AVAssetWriterInputMetadataAdaptor` to write into a `.mov`, then remux to `.mp4` with ffmpeg or Bento4.

```swift
// 1. Build the metadata format description
let identifier = "com.yourapp.haptics"
let spec: [String: Any] = [
    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
        kCMMetadataBaseDataType_RawData as String
]
var formatDesc: CMFormatDescription?
CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
    allocator: kCFAllocatorDefault,
    metadataType: kCMMetadataFormatType_Boxed,
    metadataSpecifications: [spec] as CFArray,
    formatDescriptionOut: &formatDesc
)

// 2. Add to AVAssetWriter (use .mov output type!)
let metaInput = AVAssetWriterInput(
    mediaType: .metadata,
    outputSettings: nil,
    sourceFormatHint: formatDesc
)
metaInput.expectsMediaDataInRealTime = false
assetWriter.add(metaInput)

let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)

// 3. Append JSON as a single timed metadata group spanning full video
let jsonData = try! JSONEncoder().encode(ahapPayload)
let metaItem = AVMutableMetadataItem()
metaItem.identifier = AVMetadataIdentifier(rawValue: identifier)
metaItem.dataType = kCMMetadataBaseDataType_RawData as String
metaItem.value = jsonData as NSData

let timeRange = CMTimeRange(start: .zero, duration: assetDuration)
let group = AVTimedMetadataGroup(items: [metaItem], timeRange: timeRange)
adaptor.append(group)
```

### Extraction

**iOS (AVFoundation)**

```swift
let asset = AVURLAsset(url: videoURL)
let playerItem = AVPlayerItem(asset: asset)

let metaOutput = AVPlayerItemMetadataOutput(identifiers: nil)
metaOutput.setDelegate(self, queue: .main)
playerItem.add(metaOutput)

// Delegate fires once when the metadata track sample is reached
func metadataOutput(
    _ output: AVPlayerItemMetadataOutput,
    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
    from track: AVPlayerItemTrack?
) {
    guard let data = groups.first?.items.first?.dataValue else { return }
    let ahap = try? JSONDecoder().decode(AHAPPattern.self, from: data)
    scheduleHaptics(from: ahap)
}
```

**Android (MediaMetadataRetriever + MediaExtractor)**

```kotlin
val extractor = MediaExtractor()
extractor.setDataSource(videoPath)

for (i in 0 until extractor.trackCount) {
    val format = extractor.getTrackFormat(i)
    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
    if (mime == "application/json" || mime.contains("meta")) {
        extractor.selectTrack(i)
        val buf = ByteBuffer.allocate(1_000_000)
        extractor.readSampleData(buf, 0)
        val json = String(buf.array(), 0, extractor.sampleSize)
        val ahap = Gson().fromJson(json, AHAPPattern::class.java)
        scheduleHaptics(ahap)
        break
    }
}
extractor.release()
```

**Web (mp4box.js)**

```javascript
import MP4Box from 'mp4box';

const mp4 = MP4Box.createFile();
mp4.onReady = (info) => {
    const metaTrack = info.tracks.find(t => t.codec?.includes('mett'));
    if (metaTrack) mp4.setExtractionOptions(metaTrack.id, null, { nbSamples: 1 });
    mp4.start();
};
mp4.onSamples = (id, user, samples) => {
    const json = new TextDecoder().decode(samples[0].data);
    const ahap = JSON.parse(json);
    scheduleHaptics(ahap);
};

fetch(videoUrl).then(r => r.arrayBuffer()).then(buf => {
    buf.fileStart = 0;
    mp4.appendBuffer(buf);
    mp4.flush();
});
```

---

## Strategy 2 — HLS: ID3 Timed Metadata in MPEG-TS Segments

### Concept

HLS (MPEG-TS variant) supports embedding ID3 tags directly inside `.ts` segments. You use a private frame type `TXXX` (or custom `PRIV`) carrying your JSON. Because the JSON's `Time` values are absolute, you can embed a **single ID3 tag in the first segment** at `t=0`. The player surfaces it via its timed metadata API and you schedule haptics client-side.

For fMP4-based HLS (CMAF), use `emsg` boxes instead of ID3 (see DASH section below).

### Embedding

Use **ffmpeg** with a custom ID3 metadata packet injected via a filter or use a streaming packager like **Shaka Packager** or **Wowza**:

```bash
# Method 1: ffmpeg with id3v2 injection at segment time=0
# Create an ID3 tag file containing the JSON
python3 - << 'EOF'
import struct, json

def make_id3_txxx(key, value):
    # TXXX frame: encoding(1) + description + \x00 + value
    payload = b'\x03' + key.encode() + b'\x00' + value.encode()
    frame = b'TXXX' + struct.pack('>I', len(payload)) + b'\x00\x00' + payload
    header = b'ID3' + b'\x03\x00\x00'
    size = len(frame)
    # syncsafe encode size
    syncsafe = bytes([(size >> (7 * i)) & 0x7F for i in range(3, -1, -1)])
    return header + syncsafe + frame

with open('haptics.id3', 'wb') as f:
    ahap_json = open('haptics.json').read()
    f.write(make_id3_txxx('com.yourapp.haptics', ahap_json))
EOF

# Method 2: Use ffmpeg with -metadata_block_size / -id3v2_version
# Most reliable: use a streaming packager to inject at segment boundary
# Shaka Packager example:
packager \
  'in=input.mp4,stream=video,out=video_$Number$.ts' \
  'in=input.mp4,stream=audio,out=audio_$Number$.ts' \
  --hls_base_url '' \
  --hls_master_playlist_output master.m3u8 \
  --hls_segment_duration 6
# Then inject ID3 into first segment with python mutagen or bento4
```

For **VOD HLS**, you can also use `EXT-X-DATERANGE` in the `.m3u8` playlist to embed the JSON as a URI attribute (limited to ~2KB) or reference an external URL. This approach is simpler:

```
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:00Z

#EXT-X-DATERANGE:ID="haptics-0",START-DATE="2024-01-01T00:00:00Z",\
  DURATION=85.9,X-HAPTICS-URI="https://cdn.yourapp.com/haptics.json"
```

### Extraction

**iOS (AVFoundation)**

```swift
// For ID3-in-TS:
let metaOutput = AVPlayerItemMetadataOutput(identifiers: nil)
metaOutput.setDelegate(self, queue: .main)
playerItem.add(metaOutput)

func metadataOutput(
    _ output: AVPlayerItemMetadataOutput,
    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
    from track: AVPlayerItemTrack?
) {
    for group in groups {
        for item in group.items {
            // ID3 TXXX frames come through as .id3 keySpace
            if item.keySpace == .id3 {
                if let data = item.dataValue,
                   let json = String(data: data, encoding: .utf8) {
                    let ahap = try? JSONDecoder().decode(
                        AHAPPattern.self, from: Data(json.utf8))
                    scheduleHaptics(from: ahap)
                }
            }
        }
    }
}

// For EXT-X-DATERANGE:
let collector = AVPlayerItemMetadataCollector()
collector.setDelegate(self, queue: .main)
playerItem.add(collector)

func metadataCollector(
    _ collector: AVPlayerItemMetadataCollector,
    didCollect groups: [AVDateRangeMetadataGroup],
    indexesOfNewGroups: IndexSet,
    indexesOfModifiedGroups: IndexSet
) {
    for group in groups {
        let hapticsURI = group.items.first { 
            ($0.key as? String) == "X-HAPTICS-URI" 
        }?.stringValue
        // Fetch and schedule haptics from URI
    }
}
```

**Android (ExoPlayer Media3)**

```kotlin
val player = ExoPlayer.Builder(context).build()

// Register a MetadataOutput listener
player.addListener(object : Player.Listener {
    override fun onMetadata(metadata: Metadata) {
        for (i in 0 until metadata.length()) {
            val entry = metadata[i]
            if (entry is TextInformationFrame && entry.id == "TXXX") {
                val json = entry.values.firstOrNull() ?: continue
                val ahap = Gson().fromJson(json, AHAPPattern::class.java)
                scheduleHaptics(ahap)
            }
        }
    }
})
```

**Web (hls.js)**

```javascript
import Hls from 'hls.js';

const hls = new Hls();
hls.loadSource(hlsUrl);
hls.attachMedia(videoEl);

hls.on(Hls.Events.FRAG_PARSING_METADATA, (event, data) => {
    data.samples.forEach(sample => {
        // sample.data is a Uint8Array of the raw ID3 tag
        const id3 = parseID3(sample.data);        // use id3js or custom parser
        const txxx = id3.frames.find(f => f.id === 'TXXX');
        if (txxx?.description === 'com.yourapp.haptics') {
            const ahap = JSON.parse(txxx.text);
            scheduleHaptics(ahap);
        }
    });
});
```

---

## Strategy 3 — DASH/MPD: EventStream + `emsg` Boxes

### Concept

DASH supports **inline events** in the MPD manifest via `<EventStream>` elements, and **in-band events** via `emsg` (event message) boxes inside fMP4 segments. For a single-blob AHAP payload, the MPD inline approach is simplest: embed the base64-encoded JSON as an Event at `presentationTime=0`.

### Embedding (MPD — Static)

Add an `<EventStream>` block inside the first `<Period>` of your MPD:

```xml
<MPD ...>
  <Period start="PT0S" duration="PT85.9S">
    
    <EventStream schemeIdUri="urn:yourapp:haptics:2024" timescale="1000">
      <Event presentationTime="0" duration="85900" id="1">
        eyJWZXJzaW9uIjogMSwgIlBhdHRlcm4iOiBbLi4uXX0=
        <!-- base64-encoded AHAP JSON -->
      </Event>
    </EventStream>

    <AdaptationSet ...>
      <!-- video/audio representations -->
    </AdaptationSet>
  </Period>
</MPD>
```

For **in-band emsg** (preferred for live/CMAF), use an ffmpeg or packager step to inject `emsg` boxes into the first fMP4 segment. Shaka Packager and Wowza natively support emsg injection.

### Extraction

**iOS (AVFoundation + AVPlayerItemMetadataOutput)**

For DASH served as fMP4 (CMAF), AVFoundation processes `emsg` boxes automatically and surfaces them through the same `AVPlayerItemMetadataOutput` delegate. Set the `schemeIdUri` as your metadata identifier:

```swift
// Use same AVPlayerItemMetadataOutput delegate as HLS above
// AVFoundation maps emsg schemeIdUri to AVMetadataItem.identifier
func metadataOutput(
    _ output: AVPlayerItemMetadataOutput,
    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
    from track: AVPlayerItemTrack?
) {
    for item in groups.flatMap(\.items) {
        guard let id = item.identifier,
              id.rawValue.contains("urn:yourapp:haptics") else { continue }
        if let b64 = item.stringValue,
           let data = Data(base64Encoded: b64) {
            let ahap = try? JSONDecoder().decode(AHAPPattern.self, from: data)
            scheduleHaptics(from: ahap)
        }
    }
}
```

**Android (ExoPlayer Media3)**

```kotlin
player.addListener(object : Player.Listener {
    override fun onMetadata(metadata: Metadata) {
        for (i in 0 until metadata.length()) {
            val entry = metadata[i]
            if (entry is EventMessage) {
                // emsg box contents
                if (entry.schemeIdUri == "urn:yourapp:haptics:2024") {
                    val json = String(
                        Base64.decode(entry.messageData, Base64.DEFAULT))
                    val ahap = Gson().fromJson(json, AHAPPattern::class.java)
                    scheduleHaptics(ahap)
                }
            }
        }
    }
})
```

**Web (dash.js)**

```javascript
const player = dashjs.MediaPlayer().create();
player.initialize(videoEl, mpdUrl, true);

player.on('urn:yourapp:haptics:2024', (e) => {
    const json = atob(e.event.messageData);
    const ahap = JSON.parse(json);
    scheduleHaptics(ahap);
});
```

---

## Client-Side Haptic Scheduling

Once you have the decoded AHAP JSON on any platform, schedule haptics relative to current playback time:

**iOS (CoreHaptics)**

```swift
func scheduleHaptics(from ahap: AHAPPattern?) {
    guard let ahap, let engine = hapticEngine else { return }
    // Play immediately if current time is ~0, or offset each event
    let currentTime = player.currentTime().seconds
    // Use CHHapticEngine.playPattern(from:) for the full AHAP file
    // Or manually build CHHapticEvent array with adjusted relative times
    try? engine.playPattern(from: ahapFileURL)  // simplest path
}
```

**Android (VibrationEffect / HapticFeedbackConstants)**

Android has no direct AHAP support. Parse the events and schedule `VibrationEffect` calls:

```kotlin
fun scheduleHaptics(ahap: AHAPPattern) {
    val vibrator = context.getSystemService(Vibrator::class.java)
    val handler = Handler(Looper.getMainLooper())
    val baseTime = System.currentTimeMillis()
    
    ahap.pattern.forEach { eventWrapper ->
        val event = eventWrapper.event
        val delayMs = (event.time * 1000).toLong()
        handler.postDelayed({
            val effect = when (event.eventType) {
                "HapticTransient" -> VibrationEffect.createOneShot(
                    50, (event.intensity * 255).toInt()
                )
                "HapticContinuous" -> VibrationEffect.createOneShot(
                    (event.duration * 1000).toLong(),
                    (event.intensity * 255).toInt()
                )
                else -> null
            }
            effect?.let { vibrator.vibrate(it) }
        }, delayMs)
    }
}
```

**Web (Vibration API)**

```javascript
function scheduleHaptics(ahap) {
    const baseTime = performance.now();
    ahap.Pattern.forEach(({ Event: ev }) => {
        const delayMs = ev.Time * 1000;
        setTimeout(() => {
            const durationMs = (ev.EventDuration ?? 0.05) * 1000;
            navigator.vibrate(Math.round(durationMs));
        }, delayMs);
    });
}
```

---

## Comparison Matrix

| Feature | MP4 Timed Track | HLS ID3 | HLS EXT-X-DATERANGE | DASH EventStream |
|---|---|---|---|---|
| Supports VOD | ✅ | ✅ | ✅ | ✅ |
| Supports Live | ❌ | ✅ | ⚠️ (limited) | ✅ |
| iOS extraction | `AVPlayerItemMetadataOutput` | `AVPlayerItemMetadataOutput` | `AVPlayerItemMetadataCollector` | `AVPlayerItemMetadataOutput` |
| Android extraction | `MediaExtractor` | ExoPlayer `onMetadata` | ❌ (manual parse) | ExoPlayer `onMetadata` (emsg) |
| Web extraction | mp4box.js | hls.js `FRAG_PARSING_METADATA` | hls.js manifest parse | dash.js event subscription |
| Embedding tooling | MP4Box / Bento4 | Packager / ffmpeg | Manual m3u8 edit | MPD edit / Shaka |
| Payload limit | Large (MBs) | ~32KB per tag | ~2KB | Moderate (base64) |
| Recommended for | Offline / download | Live streaming | Simple VOD | ABR streaming |

---

## Recommended Architecture for FLAMINSTANT

Given your existing AVPlayer + Metal pipeline:

1. **For local/offline playback**: Embed AHAP as a timed metadata track in `.mov` (written via `AVAssetWriterInputMetadataAdaptor`), then on playback use `AVPlayerItemMetadataOutput`. Schedule haptics using `CHHapticEngine.playPattern(from:)` against a pre-loaded AHAP file derived from the metadata.

2. **For HLS streaming**: Inject the AHAP as a single `TXXX` ID3 frame in the first `.ts` segment at `presentationTime=0`. Use `AVPlayerItemMetadataOutput` on playback; extract once and schedule all events ahead of time using `CHHapticAdvancedPatternPlayer` with a time offset matching `player.currentTime()`.

3. **For DASH**: Use the MPD `EventStream` inline approach with base64-encoded JSON. This requires no segment modification and works with both dash.js and ExoPlayer.
