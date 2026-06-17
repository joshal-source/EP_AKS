#!/usr/bin/env python3
"""TLS proxy on 8089: rewrite http:// package URLs to https:// in OpAMP protobuf."""
import http.client
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DMX_HOST = os.environ["DMX_HOST"]
UPSTREAM_IP = os.environ["UPSTREAM_IP"]
LISTEN_PORT = int(os.environ.get("MGMT_PROXY_PORT", "8089"))
CERT = os.environ["PROXY_CERT"]
KEY = os.environ["PROXY_KEY"]

HTTP_PREFIX = f"http://{DMX_HOST}".encode()
HTTPS_PREFIX = f"https://{DMX_HOST}".encode()
DELTA = len(HTTPS_PREFIX) - len(HTTP_PREFIX)

UPSTREAM_CTX = ssl.create_default_context()
UPSTREAM_CTX.check_hostname = False
UPSTREAM_CTX.verify_mode = ssl.CERT_NONE

SKIP_HEADERS = frozenset(
    {"host", "connection", "transfer-encoding", "content-length", "proxy-connection"}
)


def read_varint(data: bytes, pos: int) -> tuple[int, int, int]:
    result = 0
    shift = 0
    start = pos
    while pos < len(data):
        byte = data[pos]
        result |= (byte & 0x7f) << shift
        pos += 1
        if not (byte & 0x80):
            return result, start, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")
    raise ValueError("truncated varint")


def write_varint(value: int) -> bytes:
    out = bytearray()
    while value > 0x7f:
        out.append((value & 0x7f) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def rewrite_http_to_https(body: bytes) -> bytes:
    if HTTP_PREFIX not in body:
        return body

    out = bytearray()
    pos = 0
    while True:
        idx = body.find(HTTP_PREFIX, pos)
        if idx == -1:
            out.extend(body[pos:])
            break

        end = idx + len(HTTP_PREFIX)
        while end < len(body) and body[end] not in (0, 34, 39, 60, 62, 32, 10, 13):
            end += 1
        old = body[idx:end]
        new = HTTPS_PREFIX + old[len(HTTP_PREFIX):]

        replaced = False
        for start in range(idx - 1, max(idx - 6, -1), -1):
            try:
                length, varint_start, varint_end = read_varint(body, start)
            except ValueError:
                continue
            if varint_end == idx and length == len(old) and body[idx:end] == old:
                out.extend(body[pos:varint_start])
                out.extend(write_varint(length + DELTA))
                out.extend(new)
                pos = end
                replaced = True
                break

        if not replaced:
            out.extend(body[pos:idx])
            out.extend(new)
            pos = end

    return bytes(out)


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
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in SKIP_HEADERS
        }
        headers["Host"] = DMX_HOST
        headers["Accept-Encoding"] = "identity"

        conn = http.client.HTTPSConnection(
            UPSTREAM_IP, 8089, context=UPSTREAM_CTX, timeout=300
        )
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = rewrite_http_to_https(resp.read())
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                if key.lower() not in SKIP_HEADERS:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as err:
            msg = str(err).encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
        finally:
            conn.close()

    def log_message(self, _fmt, *_args):
        return


def main():
    httpd = ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
