#!/usr/bin/env python3
"""Test double for the archfit App upload routes and the GitHub Actions OIDC token service.

usage: app.py ANSWERS LOG PORTFILE

ANSWERS is a JSON list consumed one entry per upload, in order:
  {"status": 503, "headers": {"Retry-After": "1"}, "body": {"error": "unavailable"}}
  {"drop": true}   closes the connection without an answer
LOG receives one JSON line per request. PORTFILE receives the listening port.
"""

import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

REQUEST_TOKEN = "request-token"  # what the tests export as ACTIONS_ID_TOKEN_REQUEST_TOKEN

with open(sys.argv[1]) as f:
    answers = json.load(f)
log_path, port_path = sys.argv[2], sys.argv[3]
lock = threading.Lock()
minted = 0


def record(entry):
    with lock, open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global minted
        url = urlsplit(self.path)
        authorized = self.headers.get("Authorization") == "bearer " + REQUEST_TOKEN
        record({"kind": "token", "path": url.path, "query": url.query, "authorized": authorized})
        if url.path != "/token" or not authorized:
            return self.reply(401, {"message": "bad token request"})
        with lock:
            minted += 1
            value = "oidc-%d" % minted
        self.reply(200, {"value": value})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record({
            "kind": "upload",
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "envelope": self.headers.get("X-Archfit-Envelope"),
            "content_type": self.headers.get("Content-Type"),
            "body_sha256": hashlib.sha256(body).hexdigest(),
            "body_bytes": len(body),
        })
        with lock:
            answer = answers.pop(0) if answers else {"status": 500, "body": {"error": "no_answer_scripted"}}
        if answer.get("drop"):
            self.close_connection = True
            return
        self.reply(answer["status"], answer.get("body", {}), answer.get("headers"))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
