#!/usr/bin/env python3
"""
serve.py — HTTP server with Range + CORS support for HLS, MP4, and DASH media serving.

python3 -m http.server does NOT handle:
  • HTTP Range requests  → AVFoundation fails with -12939 "byte range length mismatch"
  • CORS headers         → Web player fails when opened from file:// or different origin

Usage (from hls_output/ directory):
  python3 ../serve.py [port]          # default port 8080
"""
import http.server
import os
import sys


class RangeHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler extended with Range (RFC 7233) and CORS support.

    Range support:
      Responds to 'Range: bytes=start-end' with 206 Partial Content.
      Required by AVFoundation for MP4 probing and by the web haptic player.

    CORS support:
      Sends Access-Control-Allow-Origin: * on every response so
      haptic_web_player.html works when opened from file:// or any origin.
    """

    def _cors_headers(self):
        self.send_header('Access-Control-Allow-Origin',   '*')
        self.send_header('Access-Control-Allow-Headers',  'Range')
        self.send_header('Access-Control-Expose-Headers', 'Content-Range, Accept-Ranges, Content-Length')

    def do_OPTIONS(self):
        """Preflight CORS request — browsers send this before cross-origin Range fetches."""
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            # Let parent handle directory listings
            super().do_GET()
            return

        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(404, 'File not found')
            return

        try:
            file_size = os.fstat(f.fileno()).st_size
            ctype     = self.guess_type(path)
            range_hdr = self.headers.get('Range', '')

            if range_hdr.startswith('bytes='):
                # Parse "bytes=start-end" (both optional, per RFC 7233)
                try:
                    spec     = range_hdr[6:]
                    start_s, end_s = spec.split('-', 1)
                    start = int(start_s) if start_s else 0
                    end   = int(end_s)   if end_s   else file_size - 1
                    end   = min(end, file_size - 1)
                    if start < 0 or start > end:
                        self.send_error(416, 'Range Not Satisfiable')
                        return
                    length = end - start + 1
                    f.seek(start)
                    self.send_response(206, 'Partial Content')
                    self.send_header('Content-Type',   ctype)
                    self.send_header('Content-Range',  f'bytes {start}-{end}/{file_size}')
                    self.send_header('Content-Length', str(length))
                    self.send_header('Accept-Ranges',  'bytes')
                    self._cors_headers()
                    self.end_headers()
                    self._send_bytes(f, length)
                    return
                except (ValueError, OSError):
                    pass  # fall through to full response

            # Full response
            self.send_response(200)
            self.send_header('Content-Type',   ctype)
            self.send_header('Content-Length', str(file_size))
            self.send_header('Accept-Ranges',  'bytes')
            self._cors_headers()
            self.end_headers()
            self.copyfile(f, self.wfile)

        except BrokenPipeError:
            pass  # client closed — normal for range probes
        finally:
            f.close()

    def _send_bytes(self, f, length: int, chunk: int = 65536):
        remaining = length
        while remaining > 0:
            data = f.read(min(chunk, remaining))
            if not data:
                break
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                break
            remaining -= len(data)

    def log_message(self, fmt, *args):
        # Show Range header alongside the status line for easier debugging
        range_hdr = self.headers.get('Range', '')
        suffix = f'  [{range_hdr}]' if range_hdr else ''
        super().log_message(fmt + suffix, *args)


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    handler = RangeHTTPRequestHandler
    with http.server.ThreadingHTTPServer(('', port), handler) as httpd:
        print(f'Serving on http://0.0.0.0:{port}  (Range + CORS supported)')
        print(f'Run from hls_output/  →  cd hls_output && python3 ../serve.py {port}')
        print(f'Web player →  http://localhost:{port}/haptic_web_player.html')
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print('\nStopped.')
