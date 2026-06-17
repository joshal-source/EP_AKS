#!/usr/bin/env python3
"""Proxy Splunk agent-management API and rewrite http:// package URLs to https://."""
import os
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DMX_HOST = os.environ["DMX_HOST"]
UPSTREAM = f"https://{DMX_HOST}:8089"
REWRITE_FROM = f"http://{DMX_HOST}".encode()
REWRITE_TO = f"https://{DMX_HOST}".encode()
LISTEN_PORT = int(os.environ.get("MGMT_PROXY_PORT", "18089"))

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

SKIP_HEADERS = frozenset(
    {"host", "connection", "transfer-encoding", "content-length", "proxy-connection"}
)


class ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def _proxy(self):
        url = UPSTREAM + self.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in SKIP_HEADERS
        }

        req = urllib.request.Request(
            url, data=body, method=self.command, headers=headers
        )
        try:
            with urllib.request.urlopen(req, context=CTX, timeout=300) as resp:
                data = resp.read().replace(REWRITE_FROM, REWRITE_TO)
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() not in SKIP_HEADERS:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as err:
            data = err.read().replace(REWRITE_FROM, REWRITE_TO)
            self.send_response(err.code)
            self.end_headers()
            self.wfile.write(data)
        except Exception as err:
            msg = str(err).encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    def log_message(self, _format, *_args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    server.serve_forever()
