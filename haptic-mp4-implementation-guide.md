# MP4 Haptic Injection and Playback — Deep Dive

This document covers the complete end-to-end pipeline for embedding AHAP haptic data
into an MP4 file (ISOBMFF container) and extracting and playing it on iOS.

---

## 1. Why MP4 Is Different From HLS

HLS uses a **text manifest** (`m3u8`). Injecting haptic metadata is a text edit.
AVFoundation has first-class support for `EXT-X-DATERANGE` and fires a delegate
immediately on manifest parse.

MP4 uses a **binary container** (ISOBMFF — ISO Base Media File Format). There is no
text to edit. Haptic data must be injected as a proper binary track inside the container,
with byte-accurate offset tables. There is no native AVFoundation API that reads a custom
`mett` handler track over HTTP — so extraction requires manual binary parsing and an
HTTP Range request.

---

## 2. ISOBMFF Box Structure Primer

An MP4 file is a sequence of nested **boxes** (also called **atoms**). Every box has:

```
┌─────────────────────────────────────┐
│  size      (4 bytes, big-endian)    │  total byte length including header
│  fourcc    (4 bytes, ASCII)         │  box type identifier
│  payload   (size - 8 bytes)        │  box-specific data
└─────────────────────────────────────┘
```

A **FullBox** adds a version/flags prefix before the payload:

```
┌─────────────────────────────────────┐
│  size      (4 bytes)                │
│  fourcc    (4 bytes)                │
│  version   (1 byte)                 │
│  flags     (3 bytes)                │
│  payload   (size - 12 bytes)       │
└─────────────────────────────────────┘
```

A standard faststart MP4 has this top-level structure:

```
[ftyp]  file type declaration          ~32 bytes
[moov]  movie metadata container       ~78 KB
[free]  padding                        8 bytes
[mdat]  raw video + audio samples      ~50 MB
```

The `moov` box contains everything AVFoundation needs to understand the file: track
geometry, codec parameters, sample timing, and crucially — chunk offset tables (`stco`)
that map each sample to its absolute byte position in the file.

---

## 3. The Injection Pipeline (Python)

### Step 1 — Ensure moov Is at the End

The injection requires moov to be at the **end** of the file so that stco offsets are
stable as we append new data. If the input is already a faststart file (moov at start),
ffmpeg remuxes it first:

```python
# embed_haptics_hls.py — inject_haptic_into_mp4()

if boxes[-1]['fourcc'] != 'moov':
    # moov is at start — remux to move it to end
    subprocess.run(['ffmpeg', '-y', '-i', input_path, '-c', 'copy', tmp_path])
    # reload file and boxes from tmp_path
```

After remux, the layout is:
```
[ftyp] [free] [mdat(video+audio)] [moov]
```

### Step 2 — Parse mvhd to Get Movie Duration and next_track_id

```python
mvhd = parse_mvhd(mvhd_box['payload'])
# Returns: timescale, duration_ticks, duration_sec, next_track_id
```

`mvhd` (Movie Header) is a FullBox inside `moov`. For version=0:

```
offset  field
------  -----
 0      version + flags     (4 bytes)
 4      creation_time       (4 bytes)
 8      modification_time   (4 bytes)
12      timescale           (4 bytes)  ← ticks per second
16      duration            (4 bytes)  ← total ticks
20      rate                (4 bytes)
...
96      next_track_id       (4 bytes)  ← ID to assign to the new track
```

`next_track_id` tells us what track ID to use — it's the counter the MP4 muxer
maintains to assign unique IDs. We use it directly.

### Step 3 — Calculate the AHAP Byte Offset

```python
non_moov = all boxes except moov (ftyp + free + mdat)
ahap_offset = len(non_moov) + 8   # 8 = mdat box header
```

The new file layout will be:
```
[non_moov bytes]  [ahap mdat header (8 bytes)]  [AHAP JSON bytes]  [new moov]
       ↑ len(non_moov)      ↑ + 8 = ahap_offset
```

`ahap_offset` is the **absolute file byte position** where the AHAP JSON starts.
This value goes directly into the `stco` box of the mett track.

### Step 4 — Build the mett Track (build_haptic_trak)

The mett track is a complete `trak` box. Its structure mirrors a standard video or
audio track but with a metadata handler and a single sample covering the entire movie.

```
trak
 ├── tkhd  (Track Header)
 └── mdia  (Media Container)
      ├── mdhd  (Media Header — timescale, duration)
      ├── hdlr  (Handler Reference — declares 'mett' handler type)
      └── minf  (Media Information)
           ├── nmhd  (Null Media Header — required for metadata tracks)
           ├── dinf  (Data Information)
           │    └── dref  (Data Reference — url  box, flags=1 = same file)
           └── stbl  (Sample Table)
                ├── stsd  (Sample Description — mett sample entry)
                ├── stts  (Time-to-Sample — 1 sample, delta = full duration)
                ├── stsc  (Sample-to-Chunk — 1 sample per chunk)
                ├── stsz  (Sample Sizes — 1 sample, size = len(AHAP))
                └── stco  (Chunk Offsets — 1 entry = ahap_offset)
```

#### tkhd — Track Header

```python
isobmff_fullbox('tkhd', version=0, flags=3, payload=(
    creation_time(4) + modification_time(4) +
    track_id(4) +               # = mvhd.next_track_id
    reserved(4) +
    duration(4) +               # in MOVIE timescale
    reserved(8) +
    layer(2) + alternate_group(2) +
    volume(2) + reserved(2) +
    matrix(36) +                # identity matrix
    width(4) + height(4)        # both 0 for metadata track
))
```

`flags=3` means "track enabled" + "track in movie".

#### mdhd — Media Header

```python
isobmff_fullbox('mdhd', version=0, flags=0, payload=(
    creation_time(4) + modification_time(4) +
    timescale(4) +      # 1000 (milliseconds) — independent of movie timescale
    duration(4) +       # in MEDIA timescale
    language(2) +       # 0x55C4 = 'und' (undetermined)
    pre_defined(2)
))
```

The media timescale is set to **1000** (milliseconds). The media duration is:
```python
media_duration = int(movie_duration_ticks / movie_timescale * 1000)
```

#### hdlr — Handler Reference

```python
isobmff_fullbox('hdlr', version=0, flags=0, payload=(
    pre_defined(4) +
    b'mett' +           # handler_type — ISO 14496-12 timed metadata
    reserved(12) +
    b'Haptic Metadata\x00'
))
```

`'mett'` is the ISO 14496-12 standard handler type for timed metadata. This is what
iOS sees as `track.mediaType == "mett"` (not `.metadata`, not `.video`).

#### nmhd — Null Media Header

Required for metadata tracks instead of `vmhd` (video) or `smhd` (audio):
```python
isobmff_fullbox('nmhd', version=0, flags=0, payload=b'')
```

#### dref / url — Data Reference

Declares that sample data is in the same file (self-contained):
```python
url  = isobmff_fullbox('url ', version=0, flags=1, payload=b'')
# flags=1 means "data is in this file" — no URL string needed
dref = isobmff_fullbox('dref', version=0, flags=0,
                        payload=entry_count(4) + url)
```

#### stsd — Sample Description (mett sample entry)

```python
mett_entry = isobmff_box('mett', payload=(
    reserved(6) +
    data_reference_index(2) +   # = 1 (references dref entry 1)
    b'application/json\x00'     # content_type — declared MIME type of samples
))
stsd = isobmff_fullbox('stsd', version=0, flags=0,
                         payload=entry_count(4) + mett_entry)
```

The `'application/json'` content type tells any parser (iOS, Android MediaExtractor)
what format to expect when it reads the sample bytes.

#### stts — Time to Sample

One entry: 1 sample with delta = full media duration:
```python
isobmff_fullbox('stts', 0, 0,
    entry_count(4) +            # = 1
    sample_count(4) +           # = 1
    sample_delta(4)             # = media_duration (entire movie)
)
```

This declares that the single AHAP sample starts at t=0 and lasts until the end
of the movie. It covers the full timeline.

#### stsc — Sample to Chunk

One entry: 1 sample per chunk:
```python
isobmff_fullbox('stsc', 0, 0,
    entry_count(4) +            # = 1
    first_chunk(4) +            # = 1
    samples_per_chunk(4) +      # = 1
    sample_description_index(4) # = 1
)
```

#### stsz — Sample Sizes

One sample of `len(ahap_data)` bytes:
```python
isobmff_fullbox('stsz', 0, 0,
    sample_size(4) +            # = 0 (variable — use entry table)
    sample_count(4) +           # = 1
    entry_size[0](4)            # = len(ahap_data)
)
```

#### stco — Chunk Offsets (The Critical Box)

```python
isobmff_fullbox('stco', 0, 0,
    entry_count(4) +            # = 1
    offset[0](4)                # = ahap_offset (absolute file byte position)
)
```

This is the box that connects the logical sample to its physical location in the file.
`ahap_offset` = the exact byte where the AHAP JSON starts in the final file.

### Step 5 — Assemble and Write the Intermediate File

```python
raw = non_moov + ahap_mdat + new_moov
```

Layout at this point (moov at end):
```
[ftyp][free][mdat(video+audio)]  [mdat(AHAP JSON)]  [moov + mett trak]
      ↑ non_moov                  ↑ ahap_mdat         ↑ new_moov
```

The stco for the mett track correctly points into `ahap_mdat`.

### Step 6 — Pure Python Faststart (apply_faststart_python)

`ffmpeg -movflags +faststart` silently drops the `mett` track because it doesn't
understand the custom handler type. So we implement faststart in Python:

```
Before (moov at end):
[ftyp(32)] [free(8)] [mdat(53MB)] [ahap_mdat(35KB)] [moov(79KB)]

After (moov at start):
[ftyp(32)] [moov(79KB)] [free(8)] [mdat(53MB)] [ahap_mdat(35KB)]
```

**The stco shift problem:** When moov moves from position ~53MB to position 32,
all existing stco offsets (which point into mdat) become wrong. Every offset needs
to increase by `moov_size` because all data boxes shifted right by that amount.

```python
def apply_faststart_python(file_data):
    moov_size = moov_box['size']   # e.g. 79,150 bytes

    # Shift ALL stco offsets in moov by moov_size
    moov_patched = _patch_stco(moov_raw, delta=moov_size)

    # Write: ftyp + patched_moov + everything else
    return ftyp_raw + moov_patched + other_boxes
```

**Why the shift equals moov_size exactly:**

```
Before:  [ftyp(32)] ... [mdat starts at 40] ...
After:   [ftyp(32)] [moov(79150)] ... [mdat starts at 79190]

delta = 79190 - 40 = 79150 = moov_size  ✓
```

The video stco offsets go from e.g. 48 → 79,198. The mett stco goes from
53,499,522 → 53,578,672. All shifted by exactly `moov_size`.

**_patch_stco uses pattern search, not container walking:**

```python
def _patch_stco(moov_bytes, delta):
    # Scan for b'stco' fourcc in the moov bytes
    # For each match: read box_size, parse entry_count, patch each offset
    # Pattern search is more reliable than walking the box hierarchy
```

The container-walking approach (step into trak → mdia → minf → stbl → stco) failed
in practice because the linear position counter would drift when nested containers
didn't fill their parent exactly. Pattern search finds all three stco boxes (video,
audio, mett) regardless of nesting depth.

---

## 4. The Final File Structure

```
Offset        Box             Size
──────────────────────────────────────────
0             ftyp            32 bytes
32            moov            79,150 bytes
  116           trak (video)  44,359 bytes
                 stco[0]      79,198  ← correct post-faststart offset
  44,475        trak (audio)  ...
                 stco[0]      162,772 ← correct post-faststart offset
  79,130        trak (mett)   402 bytes
                 stsd          mett entry, content-type=application/json
                 stsz          1 sample, size=35,221
                 stco[0]      53,578,672 ← absolute offset of AHAP JSON
79,182        free            8 bytes
79,190        mdat (video)    53,499,474 bytes
53,578,664    mdat (AHAP)     35,229 bytes
  +8           AHAP JSON      35,221 bytes ← at 53,578,672 ✓
```

---

## 5. iOS Extraction Pipeline

### Why AVAssetReader Doesn't Work Over HTTP

`AVAssetReader` is a local-file-only API. Attempting to initialize it with an
`http://` URL fails immediately:

```
Error Domain=AVFoundationErrorDomain Code=-11838
"Cannot initialize an instance of AVAssetReader
 with an asset at non-local URL"
```

### The Range Request Approach

Since moov is at the start of the file (faststart), the entire track metadata is
in the first ~79KB. We download just that, parse the binary structure, find the
stco offset and stsz size, then fetch exactly those bytes.

```
Request 1:  GET /output_with_haptics.mp4
            Range: bytes=0-524287          (first 512 KB, covers ftyp+moov)
            Response: 206 Partial Content
            Body: [ftyp][moov][free][start of mdat]

Request 2:  GET /output_with_haptics.mp4
            Range: bytes=53578672-53613892  (AHAP bytes only)
            Response: 206 Partial Content
            Body: {"Version":1,"Pattern":[...]}   (35,221 bytes)
```

Total: **2 HTTP requests**, **~560 KB downloaded** to get the AHAP from a 51MB file.

### parseMettStcoStsz — Binary Parsing in Swift

```swift
func parseMettStcoStsz(from data: Data) -> (Int, Int)?
```

The function scans the downloaded header bytes using pattern search:

**Step 1 — Find the mett handler:**
```swift
data.range(of: Data("mett".utf8))
// Finds the 4 bytes 'mett' inside the hdlr box payload
// This marks the start of our injected track's mdia section
```

**Step 2 — Find stsz AFTER mett:**
```
stbl box order (ISO 14496-12): stsd → stts → stsc → stsz → stco
stsz ALWAYS comes before stco
```

```swift
data.range(of: Data("stsz".utf8), in: afterMett..<data.endIndex)
```

Parse stsz FullBox:
```
stszBoxStart + 0  : size          (4 bytes)
stszBoxStart + 4  : 'stsz'        (4 bytes)
stszBoxStart + 8  : version+flags (4 bytes)  ← FullBox header
stszBoxStart + 12 : sample_size   (4 bytes)  ← 0 = variable
stszBoxStart + 16 : sample_count  (4 bytes)  ← = 1
stszBoxStart + 20 : entry_size[0] (4 bytes)  ← = 35,221 = len(AHAP)
```

**Step 3 — Find stco AFTER stsz:**
```swift
data.range(of: Data("stco".utf8), in: afterStsz..<data.endIndex)
```

Parse stco FullBox:
```
stcoBoxStart + 0  : size          (4 bytes)
stcoBoxStart + 4  : 'stco'        (4 bytes)
stcoBoxStart + 8  : version+flags (4 bytes)
stcoBoxStart + 12 : entry_count   (4 bytes)  ← = 1
stcoBoxStart + 16 : offset[0]     (4 bytes)  ← = 53,578,672
```

Returns `(53578672, 35221)` — offset and size of the AHAP JSON in the file.

### fetchAHAPFromRemoteMett — The Full Flow

```swift
// 1. Download first 512KB (covers moov)
var req = URLRequest(url: mp4URL)
req.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
let (headerData, _) = try await URLSession.shared.data(for: req)

// 2. Parse stco and stsz
let (ahapOffset, ahapSize) = parseMettStcoStsz(from: headerData)!
// → (53578672, 35221)

// 3. Fetch only the AHAP bytes
var ahapReq = URLRequest(url: mp4URL)
ahapReq.setValue("bytes=\(ahapOffset)-\(ahapOffset + ahapSize - 1)",
                 forHTTPHeaderField: "Range")
let (ahapData, resp) = try await URLSession.shared.data(for: ahapReq)
// → 35,221 bytes of JSON

// 4. Feed to CoreHaptics
processAHAPData(ahapData)
```

### Why the Server Must Support Range Requests

`python3 -m http.server` does NOT implement the `Range` header — it always returns
the full file. AVFoundation probes Range support immediately on asset load with a
`Range: bytes=0-1` request. If the server responds with 200 + full content-length
instead of 206 + 2 bytes, AVFoundation fails with:

```
CoreMediaErrorDomain -12939
"byte range length mismatch — should be length 2 is length 53613893"
```

`serve.py` handles this correctly:
```python
class RangeHTTPRequestHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if range_header.startswith('bytes='):
            # Parse start-end, seek file, send 206 Partial Content
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
            self.send_header('Content-Length', str(length))
            f.seek(start)
            self._send_bytes(f, length)
```

---

## 6. Seek Behaviour in MP4 Mode

Seek works identically to HLS mode — it's entirely a CoreHaptics operation:

```swift
hapticScheduler.seek(to: videoTime)
  └─ patternPlayer?.stop()
  └─ patternPlayer = engine?.makeAdvancedPlayer(with: cachedPattern)
  └─ patternPlayer?.seek(toOffset: videoTime)
  └─ patternPlayer?.start(atTime: CHHapticTimeImmediate)
```

The AHAP is loaded once at startup. `seek(toOffset:)` skips all events before
`videoTime`, resumes mid-event if seeking into a `HapticContinuous`, and plays
the remaining duration of that event.

The mett track has no per-segment haptic data — it carries one single sample
spanning the entire movie. This is equivalent to the HLS approach where one
`haptic.ahap` file covers the full video duration.

---

## 7. Android Extraction (MediaExtractor)

The same `mett` handler track is readable on Android without any Range parsing:

```kotlin
val extractor = MediaExtractor()
extractor.setDataSource("http://server/output_with_haptics.mp4")

for (i in 0 until extractor.trackCount) {
    val format = extractor.getTrackFormat(i)
    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
    if (mime == "application/json") {  // matches stsd content-type
        extractor.selectTrack(i)
        val buf = ByteBuffer.allocate(format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
        extractor.readSampleData(buf, 0)
        val ahapJson = String(buf.array(), Charsets.UTF_8)
        // parse AHAP JSON → convert to VibrationEffect
    }
}
```

`MediaExtractor` handles the Range requests internally. It reads moov, finds the
`mett` track by its `application/json` content type in stsd, and fetches exactly
the sample bytes using the stco offset.

---

## 8. Key Numbers (cars.mp4 example)

| Field | Value |
|---|---|
| Final file size | 53,613,893 bytes (~51 MB) |
| ftyp box | 32 bytes |
| moov box | 79,150 bytes |
| mett trak | 402 bytes (inside moov) |
| mett stco offset | 53,578,672 |
| AHAP size | 35,221 bytes |
| AHAP events | 69 |
| HTTP requests to extract AHAP | 2 |
| Bytes downloaded to extract AHAP | ~560 KB of 51 MB |

---

## 9. Failure Modes and Fallbacks

| Failure | Detection | Fallback |
|---|---|---|
| Server no Range support | `parseMettStcoStsz` returns nil or 206 fails | `fetchAHAPSidecar()` — downloads `haptic.ahap` directly |
| moov > 512KB download | stco/stsz not found in header bytes | `fetchAHAPSidecar()` |
| mett track not present in file | 'mett' pattern not found | `fetchAHAPSidecar()` |
| AHAP JSON corrupt | `JSONDecoder` fails in `processAHAPData` | Haptics silently disabled |
| Local file (bundle) | `asset.url.isFileURL == true` | `AVAssetReader` path (no Range needed) |
