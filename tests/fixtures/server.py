"""Fixture server: serves events.html and appends POST /log bodies (one per line) to the log file in argv[1]. Port 47830."""
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG = sys.argv[1]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = open(os.path.join(ROOT, "events.html"), "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/log":
            with open(LOG, "ab") as f:
                f.write(body + b"\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", 47830), H).serve_forever()
