import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

events = []
attempts = []
mode = "success"
failures_left = 0
token = os.environ.get("WEBHOOK_TOKEN", "local-dev-only-token")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def reply(self, status, body=None):
        data = json.dumps(body or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "UP"})
        elif self.path == "/events":
            self.reply(200, {"events": events, "attempts": attempts})
        else:
            self.reply(404)

    def do_POST(self):
        global mode, failures_left
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        if self.path == "/control":
            request = json.loads(raw or b"{}")
            mode = request.get("mode", "success")
            failures_left = int(request.get("failures", 0))
            if request.get("reset", False):
                events.clear()
                attempts.clear()
            self.reply(200, {"mode": mode})
            return
        if self.path != "/hook":
            self.reply(404)
            return
        if self.headers.get("X-Geordi-Token") != token:
            self.reply(401)
            return
        attempts.append({"deliveryId": self.headers.get("Idempotency-Key")})
        if mode == "terminal":
            self.reply(400)
            return
        if mode == "retry" and failures_left > 0:
            failures_left -= 1
            self.reply(503)
            return
        payload = json.loads(raw)
        events.append({"deliveryId": self.headers.get("Idempotency-Key"), "payload": payload})
        self.reply(200, {"accepted": True})

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
