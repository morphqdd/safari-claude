"""Spike probe server: HTTP for the test page + minimal WebSocket endpoint for the extension.

POST /send with a JSON body forwards it to the connected extension socket.
Everything is logged to probe.log next to this file.
"""
import base64, hashlib, json, os, socketserver, struct, sys, threading, time

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(ROOT, "probe.log")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
clients = []
lock = threading.Lock()


def log(obj):
    obj.setdefault("srv_t", time.strftime("%H:%M:%S"))
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def frame(opcode, payload=b""):
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request_line = self.rfile.readline().decode(errors="replace").strip()
        headers = {}
        while True:
            line = self.rfile.readline().decode(errors="replace").strip()
            if not line:
                break
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        if headers.get("upgrade", "").lower() == "websocket":
            return self.websocket(headers)
        method, path, _ = request_line.split(" ", 2)
        body = self.rfile.read(int(headers.get("content-length", 0)))
        if method == "POST" and path == "/send":
            with lock:
                targets = list(clients)
            for c in targets:
                c.sendall(frame(1, body))
            return self.reply(200, b"sent to %d" % len(targets))
        if method == "POST" and path == "/log":
            log({"page": json.loads(body or b"{}")})
            return self.reply(204, b"")
        with open(os.path.join(ROOT, "page.html"), "rb") as f:
            return self.reply(200, f.read(), "text/html; charset=utf-8")

    def reply(self, code, body, ctype="text/plain"):
        self.wfile.write(b"HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                         % (code, ctype.encode(), len(body)) + body)

    def websocket(self, headers):
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest())
        self.wfile.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        log({"ws": "connected", "origin": headers.get("origin")})
        sock = self.request
        with lock:
            clients.append(sock)
        alive = [True]

        def pinger():
            while alive[0]:
                time.sleep(20)
                try:
                    sock.sendall(frame(9, b"p"))
                except OSError:
                    return

        threading.Thread(target=pinger, daemon=True).start()
        try:
            while True:
                b1, b2 = self.rfile.read(2)
                n = b2 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", self.rfile.read(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4)
                data = bytes(c ^ mask[i % 4] for i, c in enumerate(self.rfile.read(n)))
                op = b1 & 0x0F
                if op == 8:
                    log({"ws": "close-frame"})
                    break
                if op == 10:
                    log({"ws": "pong"})
                elif op == 1:
                    log({"ext": json.loads(data)})
        except (ValueError, OSError):
            pass
        finally:
            alive[0] = False
            with lock:
                clients.remove(sock)
            log({"ws": "disconnected"})


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


Server(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 47822), Handler).serve_forever()
