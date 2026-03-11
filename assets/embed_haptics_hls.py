#!/usr/bin/env python3
"""
embed_haptics_hls.py

Embeds an AHAP haptic file into an HLS stream using three complementary methods:

  Method 1 — EXT-X-DATERANGE in m3u8 (PRIMARY, seek-safe)
    Base64-encoded AHAP lives inside the manifest.
    AVFoundation reads it via AVPlayerItemMetadataCollector.

  Method 2 — Proper ID3 PES in MPEG-TS (LIVE STREAMING)
    ID3 tag embedded as a real stream_type=0x15 PES inside the TS container.
    PMT is updated with the new elementary stream + metadata_descriptor.
    AVFoundation reads it via AVPlayerItemMetadataOutput.

  Method 3 — Direct sidecar file (FALLBACK)
    haptic.ahap copied to the output directory as a last resort.

Usage:
  python3 embed_haptics_hls.py \
      --input  cars.mp4 \
      --ahap   haptic.ahap \
      --output hls_output/

Dependencies:
  - ffmpeg (must be on PATH)
"""

import argparse
import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys


# ============================================================================
# MPEG-TS constants
# ============================================================================

TS_PACKET_SIZE = 188
TS_SYNC        = 0x47

# Metadata descriptor tag for ID3 timed metadata (ISO 13818-1)
#   descriptor_tag          = 0x26
#   descriptor_length       = 9
#   metadata_application_format = 0xFFFF (user private)
#   metadata_format         = 0xFF (user private)
#   metadata_format_identifier = b"ID3 "
#   metadata_service_id     = 0x00
#   flags                   = 0x0F (reserved bits set)
METADATA_DESCRIPTOR = bytes([
    0x26, 0x09,
    0xFF, 0xFF,
    0xFF,
    0x49, 0x44, 0x33, 0x20,
    0x00,
    0x0F,
])

STREAM_TYPE_METADATA = 0x15   # Metadata carried in PES packets
PES_STREAM_ID_PRIVATE = 0xBD  # private_stream_1


# ============================================================================
# CRC-32/MPEG-2  (poly=0x04C11DB7, init=0xFFFFFFFF, no reflection, no xorout)
# ============================================================================

def crc32_mpeg2(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


# ============================================================================
# MPEG-TS packet helpers
# ============================================================================

def ts_pid(pkt: bytes) -> int:
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def ts_pusi(pkt: bytes) -> bool:
    """payload_unit_start_indicator"""
    return bool(pkt[1] & 0x40)


def ts_payload(pkt: bytes) -> bytes:
    """Return the payload bytes of a TS packet (skips adaptation field)."""
    afc = (pkt[3] >> 4) & 0x3
    if afc in (0, 2):          # no payload
        return b''
    if afc == 1:               # payload only
        return pkt[4:]
    af_len = pkt[4]            # adaptation + payload
    start  = 5 + af_len
    return pkt[start:] if start < len(pkt) else b''


def ts_continuity_counter(pkt: bytes) -> int:
    return pkt[3] & 0xF


def psi_section(payload: bytes) -> bytes:
    """Extract PSI section bytes from a TS payload (skips pointer_field)."""
    if not payload:
        return b''
    ptr = payload[0]
    return payload[1 + ptr:]


def split_packets(data: bytes) -> list[bytes]:
    """
    Split raw bytes into 188-byte TS packets.
    Scans forward to find the first 0x47 sync byte so any prepended prefix
    (e.g. a legacy raw ID3 tag) is silently skipped.
    """
    # Find first valid sync byte that is consistently followed by more packets
    start = 0
    for i in range(len(data) - TS_PACKET_SIZE):
        if data[i] == TS_SYNC and data[i + TS_PACKET_SIZE] == TS_SYNC:
            start = i
            break

    pkts = [data[i:i + TS_PACKET_SIZE]
            for i in range(start, len(data) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE)]
    bad  = [i for i, p in enumerate(pkts) if p[0] != TS_SYNC]
    if bad:
        raise ValueError(f'TS sync byte missing in {len(bad)} packet(s): indices {bad[:5]}')
    return pkts


# ============================================================================
# PAT parser  →  finds PMT PID
# ============================================================================

def find_pmt_pid(packets: list[bytes]) -> int | None:
    for pkt in packets:
        if ts_pid(pkt) != 0x0000 or not ts_pusi(pkt):
            continue
        sect = psi_section(ts_payload(pkt))
        if not sect or sect[0] != 0x00:   # table_id must be 0x00 (PAT)
            continue
        section_length = ((sect[1] & 0x0F) << 8) | sect[2]
        pos = 8
        end = 3 + section_length - 4      # exclude CRC
        while pos + 4 <= end:
            prog_num = (sect[pos] << 8) | sect[pos + 1]
            pmt_pid  = ((sect[pos + 2] & 0x1F) << 8) | sect[pos + 3]
            if prog_num != 0:             # skip NIT entry (program 0)
                return pmt_pid
            pos += 4
    return None


def find_all_pids(packets: list[bytes]) -> set[int]:
    return {ts_pid(p) for p in packets}


# ============================================================================
# PMT parser
# ============================================================================

def parse_pmt_section(sect: bytes) -> dict | None:
    """
    Parse a PMT section into a dict:
      program_number, version_byte, pcr_pid,
      program_info (bytes), streams: [{type, pid, info}]
    """
    if not sect or sect[0] != 0x02:
        return None
    section_length  = ((sect[1] & 0x0F) << 8) | sect[2]
    program_number  = (sect[3] << 8) | sect[4]
    version_byte    = sect[5]
    pcr_pid         = ((sect[8] & 0x1F) << 8) | sect[9]
    prog_info_len   = ((sect[10] & 0x0F) << 8) | sect[11]
    program_info    = sect[12: 12 + prog_info_len]

    streams = []
    pos = 12 + prog_info_len
    end = 3 + section_length - 4           # exclude CRC
    while pos + 5 <= end:
        stype       = sect[pos]
        spid        = ((sect[pos + 1] & 0x1F) << 8) | sect[pos + 2]
        es_info_len = ((sect[pos + 3] & 0x0F) << 8) | sect[pos + 4]
        es_info     = sect[pos + 5: pos + 5 + es_info_len]
        streams.append({'type': stype, 'pid': spid, 'info': bytes(es_info)})
        pos += 5 + es_info_len

    return {
        'program_number': program_number,
        'version_byte':   version_byte,
        'pcr_pid':        pcr_pid,
        'program_info':   bytes(program_info),
        'streams':        streams,
    }


# ============================================================================
# PMT builder
# ============================================================================

def build_pmt_section(pmt: dict, new_stream_type: int, new_pid: int) -> bytes:
    """Rebuild a PMT section adding one new elementary stream."""
    prog_info = pmt['program_info']
    pcr_pid   = pmt['pcr_pid']
    prog_num  = pmt['program_number']

    # Serialize existing streams
    streams_bytes = bytearray()
    for s in pmt['streams']:
        streams_bytes += bytes([
            s['type'],
            0xE0 | (s['pid'] >> 8), s['pid'] & 0xFF,
            0xF0 | (len(s['info']) >> 8), len(s['info']) & 0xFF,
        ]) + s['info']

    # New stream entry (stream_type=0x15 + metadata_descriptor)
    es_info = METADATA_DESCRIPTOR
    streams_bytes += bytes([
        new_stream_type,
        0xE0 | (new_pid >> 8), new_pid & 0xFF,
        0xF0 | (len(es_info) >> 8), len(es_info) & 0xFF,
    ]) + es_info

    # Assemble body (table_id through last stream byte)
    body = bytearray([
        0x02,                                         # table_id
        0x00, 0x00,                                   # section_length placeholder
        (prog_num >> 8) & 0xFF, prog_num & 0xFF,      # program_number
        pmt['version_byte'],                           # version + current_next
        0x00,                                         # section_number
        0x00,                                         # last_section_number
        0xE0 | (pcr_pid >> 8), pcr_pid & 0xFF,       # PCR_PID
        0xF0 | (len(prog_info) >> 8), len(prog_info) & 0xFF,
    ])
    body += prog_info
    body += streams_bytes

    # Patch section_length = bytes from position 3 to end (body[3:]) + 4 CRC bytes
    section_length = (len(body) - 3) + 4
    body[1] = 0xB0 | (section_length >> 8)   # section_syntax_indicator=1 + reserved
    body[2] = section_length & 0xFF

    # Append CRC (covers everything from table_id through last byte before CRC)
    body += struct.pack('>I', crc32_mpeg2(bytes(body)))
    return bytes(body)


def build_pmt_ts_packet(pid: int, section: bytes, cc: int) -> bytes:
    """Wrap a PMT section in a single 188-byte TS packet."""
    if len(section) > 183:
        raise ValueError(f'PMT section too large ({len(section)} bytes) for one TS packet')
    payload = bytes([0x00]) + section          # pointer_field=0
    payload += bytes([0xFF] * (184 - len(payload)))  # pad unused bytes
    return bytes([
        TS_SYNC,
        0x40 | (pid >> 8),   # PUSI=1
        pid & 0xFF,
        0x10 | (cc & 0xF),   # payload only
    ]) + payload


# ============================================================================
# PES builder for ID3 timed metadata
# ============================================================================

def encode_pts(pts: int) -> bytes:
    """Encode a 33-bit PTS value into the 5-byte MPEG-2 format."""
    return bytes([
        0x21 | ((pts >> 29) & 0x0E),   # '0010' + pts[32:30] + marker
        (pts >> 22) & 0xFF,
        0x01 | ((pts >> 14) & 0xFE),   # pts[21:15] + marker
        (pts >> 7) & 0xFF,
        0x01 | ((pts & 0x7F) << 1),    # pts[6:0] + marker
    ])


def build_metadata_pes(id3_data: bytes, pts_90khz: int = 0) -> bytes:
    """
    Build a PES packet carrying an ID3 tag.
      stream_id = 0xBD (private_stream_1)
      data_alignment_indicator = 1  (required for metadata)
      PTS present, DTS absent
    """
    optional_header = bytes([
        0x84,  # '10' + data_alignment_indicator=1 + padding
        0x80,  # PTS_DTS_flags=10 (PTS only)
        0x05,  # PES_header_data_length = 5
    ]) + encode_pts(pts_90khz)

    pes_packet_length = len(optional_header) + len(id3_data)
    if pes_packet_length > 65535:
        raise ValueError(f'PES payload too large: {pes_packet_length} bytes (max 65535)')

    return (
        bytes([0x00, 0x00, 0x01, PES_STREAM_ID_PRIVATE])
        + struct.pack('>H', pes_packet_length)
        + optional_header
        + id3_data
    )


def packetize_pes(pid: int, pes_data: bytes) -> bytes:
    """
    Split PES bytes into consecutive 188-byte TS packets.
    Uses adaptation field stuffing to pad the final packet.
    """
    out = bytearray()
    offset = 0
    cc = 0

    while offset < len(pes_data):
        remaining = len(pes_data) - offset
        pusi = 0x40 if offset == 0 else 0x00

        if remaining >= 184:
            # Full payload packet
            header = bytes([TS_SYNC, pusi | (pid >> 8), pid & 0xFF, 0x10 | (cc & 0xF)])
            chunk  = pes_data[offset: offset + 184]
            offset += 184
        else:
            # Last packet — pad with adaptation field stuffing
            stuff = 184 - remaining
            if stuff == 1:
                af = bytes([0x00])                                  # AF length=0, just the byte itself
            else:
                af = bytes([stuff - 1, 0x00]) + b'\xFF' * (stuff - 2)  # length + flags + stuffing
            header = bytes([TS_SYNC, pusi | (pid >> 8), pid & 0xFF, 0x30 | (cc & 0xF)])
            chunk  = pes_data[offset:]
            out   += header + af + chunk
            cc     = (cc + 1) & 0xF
            break   # done

        pkt = header + chunk
        assert len(pkt) == 188
        out += pkt
        cc = (cc + 1) & 0xF

    return bytes(out)


# ============================================================================
# ID3v2 helpers  (for building the tag written into the PES)
# ============================================================================

def syncsafe_encode(n: int) -> bytes:
    result = bytearray(4)
    for i in range(3, -1, -1):
        result[i] = n & 0x7F
        n >>= 7
    return bytes(result)


def make_txxx_frame(description: str, value: str) -> bytes:
    payload = b'\x03' + description.encode('utf-8') + b'\x00' + value.encode('utf-8')
    return b'TXXX' + struct.pack('>I', len(payload)) + b'\x00\x00' + payload


def make_id3_tag(frames: list[bytes]) -> bytes:
    body = b''.join(frames)
    return b'ID3' + b'\x03\x00\x00' + syncsafe_encode(len(body)) + body


# ============================================================================
# Full proper ID3-in-TS injection
# ============================================================================

def inject_id3_proper(ts_path: str, id3_data: bytes) -> None:
    """
    Embed an ID3 tag as a proper timed-metadata elementary stream in an MPEG-TS file.

    The injection modifies the TS in-place:
      • Parses PAT to locate the PMT PID.
      • Parses PMT to read existing elementary streams.
      • Allocates a free PID for the new metadata stream (stream_type=0x15).
      • Rebuilds the PMT section adding the new stream + metadata_descriptor.
      • Builds a metadata PES packet (PTS=0) carrying the ID3 tag.
      • Writes: [new PMT packet] [metadata PES TS packets] [original TS packets]
    """
    with open(ts_path, 'rb') as f:
        raw = f.read()

    try:
        packets = split_packets(raw)
    except ValueError as e:
        print(f'  ⚠️  {e} — skipping proper injection')
        return

    # --- Step 1: find PMT PID from PAT ---
    pmt_pid = find_pmt_pid(packets)
    if pmt_pid is None:
        print('  ⚠️  PAT/PMT not found — skipping proper injection')
        return
    print(f'  PAT→PMT PID: 0x{pmt_pid:04X}')

    # --- Step 2: find and parse the PMT packet ---
    pmt_section      = None
    pmt_packet_index = None
    pmt_cc           = 0
    for i, pkt in enumerate(packets):
        if ts_pid(pkt) == pmt_pid and ts_pusi(pkt):
            pmt_section      = psi_section(ts_payload(pkt))
            pmt_packet_index = i
            pmt_cc           = ts_continuity_counter(pkt)
            break

    if pmt_section is None:
        print('  ⚠️  PMT packet not found — skipping proper injection')
        return

    pmt = parse_pmt_section(pmt_section)
    if not pmt:
        print('  ⚠️  PMT section parse failed — skipping proper injection')
        return

    streams_info = [(f'0x{s["type"]:02X}', f'PID=0x{s["pid"]:04X}') for s in pmt['streams']]
    print(f'  Existing streams: {streams_info}')

    # Check if metadata stream already present
    if any(s['type'] == STREAM_TYPE_METADATA for s in pmt['streams']):
        print('  ℹ️  Metadata stream (0x15) already in PMT — skipping injection')
        return

    # --- Step 3: allocate a free PID ---
    all_pids = find_all_pids(packets)
    meta_pid = 0x0042
    while meta_pid in all_pids or meta_pid == pmt_pid:
        meta_pid += 1
    print(f'  Allocated metadata PID: 0x{meta_pid:04X}')

    # --- Step 4: rebuild PMT ---
    new_pmt_section = build_pmt_section(pmt, STREAM_TYPE_METADATA, meta_pid)
    new_pmt_pkt     = build_pmt_ts_packet(pmt_pid, new_pmt_section, (pmt_cc + 1) & 0xF)
    print(f'  New PMT section: {len(new_pmt_section)} bytes')

    # --- Step 5: build metadata PES (PTS = 0) ---
    pes       = build_metadata_pes(id3_data, pts_90khz=0)
    meta_pkts = packetize_pes(meta_pid, pes)
    n_pkts    = len(meta_pkts) // TS_PACKET_SIZE
    print(f'  ID3 PES: {len(id3_data)} bytes → {len(pes)} byte PES → {n_pkts} TS packet(s)')

    # --- Step 6: write output ---
    # Replace the original PMT packet; insert metadata PES right after it.
    out = bytearray()
    for i, pkt in enumerate(packets):
        if i == pmt_packet_index:
            out += new_pmt_pkt
            out += meta_pkts
        else:
            out += pkt

    with open(ts_path, 'wb') as f:
        f.write(out)

    print(f'  ✅ Injected: PMT updated + {n_pkts} metadata TS packet(s) → {os.path.basename(ts_path)}')


# ============================================================================
# HLS segmentation
# ============================================================================

def segment_video(input_path: str, output_dir: str, segment_duration: int = 6) -> str:
    os.makedirs(output_dir, exist_ok=True)
    playlist        = os.path.join(output_dir, 'stream.m3u8')
    segment_pattern = os.path.join(output_dir, 'segment_%03d.ts')

    cmd = [
        'ffmpeg', '-y',
        '-i', input_path,
        '-c:v', 'libx264', '-c:a', 'aac',
        '-hls_time', str(segment_duration),
        '-hls_list_size', '0',
        '-hls_segment_filename', segment_pattern,
        '-f', 'hls', playlist,
    ]
    print(f'[1/4] Segmenting video → {output_dir}')
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print('ffmpeg error:\n', result.stderr)
        sys.exit(1)
    return playlist


# ============================================================================
# EXT-X-DATERANGE injection into m3u8
# ============================================================================

def parse_total_duration(playlist_path: str) -> float:
    total = 0.0
    with open(playlist_path) as f:
        for line in f:
            m = re.match(r'#EXTINF:([\d.]+)', line)
            if m:
                total += float(m.group(1))
    return total


def inject_daterange_into_m3u8(playlist_path: str, ahap_json: str) -> None:
    """
    Embed base64-encoded AHAP as EXT-X-DATERANGE inside the m3u8 manifest.
    AVFoundation reads this via AVPlayerItemMetadataCollector.
    iOS attribute key: X-HAPTICS-DATA
    """
    total    = parse_total_duration(playlist_path)
    ahap_b64 = base64.b64encode(ahap_json.encode()).decode('ascii')
    anchor   = '2024-01-01T00:00:00.000Z'

    block = (
        f'#EXT-X-PROGRAM-DATE-TIME:{anchor}\n'
        f'#EXT-X-DATERANGE:ID="haptics-0",'
        f'START-DATE="{anchor}",'
        f'DURATION={total:.3f},'
        f'X-HAPTICS-DATA="{ahap_b64}"\n'
    )

    with open(playlist_path) as f:
        content = f.read()

    content = content.replace('#EXTM3U\n', f'#EXTM3U\n{block}', 1)

    with open(playlist_path, 'w') as f:
        f.write(content)

    print(
        f'[2/4] EXT-X-DATERANGE injected → {os.path.basename(playlist_path)}\n'
        f'      duration={total:.3f}s  b64_size={len(ahap_b64)} chars'
    )


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Embed AHAP haptics into an HLS stream (EXT-X-DATERANGE + proper PES).'
    )
    parser.add_argument('--input',            required=True)
    parser.add_argument('--ahap',             required=True)
    parser.add_argument('--output',           required=True)
    parser.add_argument('--key',              default='com.hapticencoding.haptics')
    parser.add_argument('--segment-duration', type=int, default=6)
    args = parser.parse_args()

    for path, label in [(args.input, 'input video'), (args.ahap, 'AHAP file')]:
        if not os.path.isfile(path):
            print(f'Error: {label} not found: {path}')
            sys.exit(1)

    with open(args.ahap) as f:
        ahap_json = f.read()
    parsed = json.loads(ahap_json)
    print(f'AHAP: {len(ahap_json)} bytes, {len(parsed.get("Pattern", []))} events')

    # Step 1 — segment
    playlist = segment_video(args.input, args.output, args.segment_duration)

    # Step 2 — EXT-X-DATERANGE in m3u8 (primary, seek-safe)
    inject_daterange_into_m3u8(playlist, ahap_json)

    # Step 3 — proper ID3 PES in first TS segment (live streaming path)
    first_ts = os.path.join(args.output, 'segment_000.ts')
    if os.path.isfile(first_ts):
        id3_tag = make_id3_tag([make_txxx_frame(args.key, ahap_json)])
        print(f'[3/4] Injecting proper ID3 PES into {os.path.basename(first_ts)}')
        print(f'      ID3 tag size: {len(id3_tag)} bytes')
        inject_id3_proper(first_ts, id3_tag)
    else:
        print(f'[3/4] ⚠️  {first_ts} not found — skipping TS injection')

    # Step 4 — sidecar copy (direct-fetch fallback)
    dest = os.path.join(args.output, 'haptic.ahap')
    shutil.copy2(args.ahap, dest)
    print(f'[4/4] Sidecar copy → {os.path.basename(dest)}')

    print()
    print('Done.')
    print(f'  Playlist : {playlist}')
    print(f'  Methods  : EXT-X-DATERANGE + proper ID3 PES (0x15) + sidecar')
    print()
    print(f'  cd {args.output} && python3 -m http.server 8080')


if __name__ == '__main__':
    main()
