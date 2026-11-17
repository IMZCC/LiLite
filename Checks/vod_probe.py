"""Exercise the real credential-free range client without depending on a live CDN."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import re
import threading
import time

root = Path(__file__).resolve().parents[1]
play = root / "Sources/PiliNative/Playback"

cast_requests = []

class Server(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        limit = 256 * 1024
        if self.path.startswith("/cast"):
            assert not self.headers.get("Cookie") and not self.headers.get("Authorization")
            a, b = map(int, re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers["Range"]).groups())
            cast_requests.append((self.path, a))
            if self.path == "/castDenied":
                self.send_response(403); self.end_headers(); return
            if self.path == "/castA" and a:
                self.send_response(502); self.end_headers(); return
            total = 65 if self.path == "/castB" else 64
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {a}-{b}/{total}")
            self.send_header("Content-Length", str(b - a + 1))
            self.end_headers()
            self.wfile.write(bytes(range(a, b+1)))
            return
        assert self.headers.get("Range") == f"bytes=0-{limit-1}"
        assert self.headers.get("Accept-Encoding") == "identity"
        assert self.headers.get("Referer", "").startswith("http://127.0.0.1:")
        assert not self.headers.get("Cookie") and not self.headers.get("Authorization")
        if self.path == "/slow":
            time.sleep(6)
            return
        if self.path in ("/ignores", "/forbidden"):
            self.send_response(200 if self.path == "/ignores" else 403)
            self.end_headers()
            return
        n = 37 if self.path == "/short" else limit
        self.send_response(206)
        self.send_header("Content-Range", f"bytes 0-{n-1}/{n if n==37 else limit+8192}")
        self.send_header("Content-Length", str(n))
        self.send_header("Set-Cookie", "mustNotReturn=1; Path=/")
        self.end_headers()
        self.wfile.write(b"A" * (n if self.path != "/truncated" else n-64))

with tempfile.TemporaryDirectory() as tmp, ThreadingHTTPServer(("127.0.0.1", 0), Server) as http:
    binpath = str(Path(tmp) / "vod-check")
    subprocess.run(["swiftc", *[str(play / (file + ".swift")) for file in
                    ("MediaRange", "RelayRange", "RangeTransport", "VODSpeedProbe", "CastMediaSource")],
                    str(root / "Sources/PiliNative/Network/ServerCertificatePolicy.swift"),
                    str(root / "Checks/VODProbeCheck.swift"), "-o", binpath], check=True)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    try:
        subprocess.run([binpath, f"http://127.0.0.1:{http.server_port}/"], check=True, timeout=30)
        assert cast_requests == [("/castA",0),("/castA",4),("/castB",4),("/castC",4),("/castC",8),("/castDenied",0)]
    finally:
        http.shutdown()
