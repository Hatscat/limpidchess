#!/usr/bin/env python3
"""Serve the exported web build on the LAN and print diagnostics the page posts back.

For testing on a real iPhone with no Mac and no inspector. The phone loads the game from
this machine, and `?log=1` makes the page POST its diagnostics panel here every 2 s, so
the readings land in this terminal instead of being squinted at through a screenshot.
Same origin, so no CORS and nothing to configure.

    python3 web/tools/lan_server.py            # serves build/web on :8099
    python3 web/tools/lan_server.py docs/play  # or any other directory
    PORT=9000 python3 web/tools/lan_server.py

Then open the printed URL on the phone. Rebuild with `web/build_web.sh` (no --deploy) and
the phone just reloads: no commit, no push, no waiting on GitHub Pages.

Note this is plain HTTP, so the browser treats it as an insecure origin and refuses to
register the service worker. That is a feature here: no cache to fight while iterating.
"""
import datetime
import http.server
import os
import socket
import socketserver
import sys

DIRECTORY = sys.argv[1] if len(sys.argv) > 1 else "build/web"
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
        print(f"\n--- {stamp}  {self.client_address[0]} " + "-" * 28)
        print(body)
        sys.stdout.flush()
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


if not os.path.isdir(DIRECTORY):
    sys.exit(f"no such directory: {DIRECTORY} (run web/build_web.sh first?)")

print(f"serving {DIRECTORY} on port {PORT}")
print(f"  on the phone:  http://{lan_ip()}:{PORT}/?debug=1&log=1")
print("  (same wifi as this machine; ctrl-c to stop)\n")
Server(("0.0.0.0", PORT), Handler).serve_forever()
