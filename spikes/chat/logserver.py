# Prints POSTed probe logs from the spike extension.
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        print(self.rfile.read(int(self.headers["Content-Length"])).decode(), flush=True)
        self.send_response(200); self.send_header("Access-Control-Allow-Origin", "*"); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 47830), H).serve_forever()
