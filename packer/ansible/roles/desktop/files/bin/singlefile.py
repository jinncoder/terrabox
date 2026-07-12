#!/usr/bin/env python3

import http.server
import argparse
import os
import mimetypes
import re


RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)")


def make_handler(filepath):
    mime_type, encoding = mimetypes.guess_type(filepath)
    content_type = mime_type or "application/octet-stream"

    class StreamingFileHandler(http.server.BaseHTTPRequestHandler):
        def list_directory(self, path):
            self.send_error(403, "Directory listing disabled")
            return None

        def do_GET(self):
            try:
                print(f"Get {self.request_version} {self.path}")
                file_size = os.path.getsize(filepath)
                range_header = self.headers.get("Range")

                start = 0
                end = file_size - 1
                status_code = 200

                if range_header:
                    match = RANGE_RE.match(range_header)
                    if not match:
                        self.send_error(400, "Invalid Range header")
                        return

                    start_str, end_str = match.groups()

                    if start_str:
                        start = int(start_str)
                    if end_str:
                        end = int(end_str)

                    if start > end or start >= file_size:
                        self.send_error(416, "Requested Range Not Satisfiable")
                        return

                    end = min(end, file_size - 1)
                    status_code = 206

                content_length = end - start + 1

                self.send_response(status_code)
                self.send_header("Content-Type", content_type)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(content_length))

                if status_code == 206:
                    print(f"\tRange request: {start}-{end}/{file_size}")
                    self.send_header(
                        "Content-Range", f"bytes {start}-{end}/{file_size}"
                    )

                if encoding:
                    self.send_header("Content-Encoding", encoding)

                self.end_headers()

                with open(filepath, "rb") as f:
                    f.seek(start)
                    remaining = content_length

                    while remaining > 0:
                        chunk_size = min(64 * 1024, remaining)
                        chunk = f.read(chunk_size)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)

            except Exception as e:
                self.send_error(500, f"Internal Server Error: {e}")

        def log_message(self, format, *args):
            return

    return StreamingFileHandler


def run(filepath, host, port):
    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"File not found: {filepath}")

    handler_class = make_handler(filepath)
    server = http.server.ThreadingHTTPServer((host, port), handler_class)

    print(f"Serving '{filepath}' on http://{host}:{port}")
    server.serve_forever()


def parse_args():
    parser = argparse.ArgumentParser(
        description="HTTP server for streaming a single file with Range support"
    )
    parser.add_argument("filepath", help="Path to the file to serve")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run(args.filepath, args.host, args.port)
