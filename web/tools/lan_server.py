#!/usr/bin/env python3
"""Serve the exported web build on the LAN over HTTPS, and print diagnostics posted back.

For testing on a real iPhone with no Mac and no inspector. The phone loads the game from
this machine, and `?log=1` makes the page POST its diagnostics panel here every 2 s, so
the readings land in this terminal instead of being squinted at through a screenshot.
Same origin, so no CORS and nothing to configure.

    python3 web/tools/lan_server.py            # serves build/web on :8099
    python3 web/tools/lan_server.py docs/play  # or any other directory
    PORT=9000 python3 web/tools/lan_server.py

Then open the printed URL on the phone. Rebuild with `web/build_web.sh` (no --deploy) and
the phone just reloads: no commit, no push, no waiting on GitHub Pages.

HTTPS IS NOT OPTIONAL. Godot's web shell refuses to start outside a secure context, and a
plain `http://192.168.x.x` origin is not one ("Secure Context - Check web server
configuration (use HTTPS)"). Only localhost gets a free pass, which does not help a phone.
So this generates a self-signed certificate for the current LAN IP on first run.

Safari will warn the first time: tap **Show Details** then **visit this website**, once
per session. The service worker still will not register against an untrusted certificate,
which is fine and in fact convenient: no cache to fight while iterating.
"""
import datetime
import http.server
import os
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile

DIRECTORY = sys.argv[1] if len(sys.argv) > 1 else "build/web"
LOG_FILE = os.environ.get("LOG_FILE", "build/lan.log")
PORT = int(os.environ.get("PORT", "8099"))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_POST(self):
        if self.path != "/__log":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        block = f"\n--- {stamp}  {self.client_address[0]} " + "-" * 28 + "\n" + body
        print(block)
        sys.stdout.flush()
        # Also to a file, so the whole session can be read back afterwards instead of
        # scrolled through, and pasted somewhere useful.
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(block + "\n")
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        # The wasm is ~36 MB; a stale copy on the phone wastes a test round.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass  # quiet: only the posted diagnostics matter


def lan_ip():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("10.255.255.255", 1))   # no packet sent, just picks the route
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def self_signed_cert(ip):
    """Generate (once per IP) a cert covering this LAN address, and return its path."""
    path = os.path.join(tempfile.gettempdir(), f"limpid_lan_{ip.replace('.', '_')}.pem")
    if os.path.exists(path):
        return path
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", path, "-out", path, "-days", "365",
         "-subj", f"/CN={ip}",
         "-addext", f"subjectAltName=IP:{ip},IP:127.0.0.1,DNS:localhost"],
        check=True, capture_output=True)
    print(f"generated self-signed certificate: {path}")
    return path


if not os.path.isdir(DIRECTORY):
    sys.exit(f"no such directory: {DIRECTORY} (run web/build_web.sh first?)")

ip = lan_ip()
server = Server(("0.0.0.0", PORT), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(self_signed_cert(ip))
server.socket = context.wrap_socket(server.socket, server_side=True)

open(LOG_FILE, "w", encoding="utf-8").close()   # fresh log per run
print(f"serving {DIRECTORY} on port {PORT} (https, self-signed)")
print(f"  writing every POST to {LOG_FILE}")
print(f"  on the phone:  https://{ip}:{PORT}/?debug=1&log=1")
print("  Safari will warn once: Show Details -> visit this website")
print("  (same wifi as this machine; ctrl-c to stop)\n")
server.serve_forever()
