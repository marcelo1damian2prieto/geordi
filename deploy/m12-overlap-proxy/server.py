"""Test-only VictoriaMetrics proxy with one controllable query barrier."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Event, Lock
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen
import json

UPSTREAM = "http://victoriametrics:8428"
lock = Lock()
entered = Event()
released = Event()
armed = False
blocked = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def respond(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global armed, blocked
        path = urlsplit(self.path).path
        if path == "/__control/arm":
            with lock:
                armed = True
                blocked = 0
                entered.clear()
                released.clear()
            self.respond(200, '{"armed":true}')
        elif path == "/__control/release":
            released.set()
            self.respond(200, '{"released":true}')
        else:
            self.proxy()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/__control/health":
            self.respond(200, '{"status":"ok"}')
            return
        if path == "/__control/status":
            with lock:
                state = {"armed": armed, "blocked": blocked, "entered": entered.is_set(),
                         "released": released.is_set()}
            self.respond(200, json.dumps(state))
            return
        self.proxy()

    def do_HEAD(self):
        self.proxy()

    def do_POST_proxy(self):
        self.proxy()

    def proxy(self):
        global blocked
        parsed = urlsplit(self.path)
        query_values = parse_qs(parsed.query).get("query", [])
        target_m12 = any("geordi-m12-scheduling-service" in query for query in query_values)
        should_wait = False
        if target_m12:
            with lock:
                if armed and not released.is_set() and blocked == 0:
                    blocked += 1
                    should_wait = True
                    entered.set()
        if should_wait:
            released.wait(timeout=240)
        if should_wait and not released.is_set():
            self.respond(504, '{"error":"test_barrier_timeout"}')
            return

        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))) if self.command == "POST" else None
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in ("host", "content-length", "connection")}
        request = Request(UPSTREAM + self.path, data=body, headers=headers, method=self.command)
        try:
            with urlopen(request, timeout=30) as response:
                self.respond(response.status, response.read(), response.headers.get_content_type())
        except HTTPError as error:
            self.respond(error.code, error.read(), error.headers.get_content_type())
        except URLError:
            self.respond(502, '{"error":"provider_unavailable"}')


ThreadingHTTPServer(("0.0.0.0", 8429), Handler).serve_forever()
