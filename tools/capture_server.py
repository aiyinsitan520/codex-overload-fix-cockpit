"""Accept one Codex /responses request, save the body, return a valid SSE stream."""
import gzip
import json
import os
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUT = sys.argv[1]
PORT = int(sys.argv[2])
count = 0


def decompress(body, encoding):
    enc = (encoding or "").lower().strip()
    if not enc or enc == "identity":
        return body, "identity"
    if enc == "gzip":
        return gzip.decompress(body), "gzip"
    if enc == "deflate":
        return zlib.decompress(body), "deflate"
    if enc == "zstd":
        try:
            from compression import zstd  # Python 3.14+
            return zstd.decompress(body), "zstd"
        except Exception:
            import zstandard
            return zstandard.ZstdDecompressor().decompress(body, max_output_size=64 << 20), "zstd"
    return body, enc


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        global count
        count += 1
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n) if n else b""
        plain, enc = decompress(raw, self.headers.get("Content-Encoding"))
        base = os.path.join(OUT, f"req_{count}")
        with open(base + ".body", "wb") as f:
            f.write(plain)
        with open(base + ".meta", "w", encoding="utf-8") as f:
            f.write(f"path={self.path}\nraw={len(raw)}\nplain={len(plain)}\nenc={enc}\n")
            for k, v in self.headers.items():
                if k.lower() in ("authorization",):
                    v = v[:20] + "..." + v[-8:]
                f.write(f"{k}: {v}\n")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(evt):
            data = json.dumps(evt, ensure_ascii=False)
            self.wfile.write(f"event: {evt['type']}\ndata: {data}\n\n".encode())
            self.wfile.flush()

        now = int(time.time())
        rid = f"resp_{count}"
        send({"type": "response.created", "sequence_number": 0, "response": {
            "id": rid, "object": "response", "created_at": now, "status": "in_progress",
            "model": "gpt-5.6-terra", "output": []}})
        item = {"id": "msg_1", "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": "OK", "annotations": []}]}
        send({"type": "response.output_item.added", "sequence_number": 1, "output_index": 0,
              "item": {**item, "status": "in_progress", "content": []}})
        send({"type": "response.content_part.added", "sequence_number": 2, "item_id": "msg_1",
              "output_index": 0, "content_index": 0,
              "part": {"type": "output_text", "text": "", "annotations": []}})
        send({"type": "response.output_text.delta", "sequence_number": 3, "item_id": "msg_1",
              "output_index": 0, "content_index": 0, "delta": "OK"})
        send({"type": "response.output_text.done", "sequence_number": 4, "item_id": "msg_1",
              "output_index": 0, "content_index": 0, "text": "OK"})
        send({"type": "response.content_part.done", "sequence_number": 5, "item_id": "msg_1",
              "output_index": 0, "content_index": 0,
              "part": {"type": "output_text", "text": "OK", "annotations": []}})
        send({"type": "response.output_item.done", "sequence_number": 6, "output_index": 0,
              "item": item})
        send({"type": "response.completed", "sequence_number": 7, "response": {
            "id": rid, "object": "response", "created_at": now, "status": "completed",
            "model": "gpt-5.6-terra", "output": [item],
            "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                      "output_tokens": 1, "output_tokens_details": {"reasoning_tokens": 0},
                      "total_tokens": 11}}})
        self.close_connection = True

    def log_message(self, fmt, *args):
        pass


os.makedirs(OUT, exist_ok=True)
print(f"capture server on {PORT} -> {OUT}", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
