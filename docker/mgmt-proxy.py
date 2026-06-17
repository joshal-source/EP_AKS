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

UPSTREAM_CTX = ssl.create_default_context()
UPSTREAM_CTX.check_hostname = False
UPSTREAM_CTX.verify_mode = ssl.CERT_NONE

SKIP_HEADERS = frozenset(
    {"host", "connection", "transfer-encoding", "content-length", "proxy-connection"}
)


def read_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    start = pos
    while pos < len(data):
        byte = data[pos]
        result |= (byte & 0x7f) << shift
        pos += 1
        if not (byte & 0x80):
            return result, pos
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


def rewrite_url_bytes(chunk: bytes) -> bytes:
    if HTTP_PREFIX not in chunk:
        return chunk
    if chunk.startswith(HTTP_PREFIX):
        return HTTPS_PREFIX + chunk[len(HTTP_PREFIX):]
    return chunk.replace(HTTP_PREFIX, HTTPS_PREFIX)


def rewrite_protobuf(body: bytes) -> bytes:
    out = bytearray()
    pos = 0
    try:
        while pos < len(body):
            tag = body[pos]
            wire_type = tag & 0x07
            pos += 1

            if wire_type == 0:
                varint_start = pos
                _, pos = read_varint(body, pos)
                out.append(tag)
                out.extend(body[varint_start:pos])
            elif wire_type == 1:
                if pos + 8 > len(body):
                    return body
                out.append(tag)
                out.extend(body[pos:pos + 8])
                pos += 8
            elif wire_type == 2:
                length, length_end = read_varint(body, pos)
                pos = length_end
                if pos + length > len(body):
                    return body
                chunk = body[pos:pos + length]
                pos += length

                if HTTP_PREFIX in chunk:
                    nested = rewrite_protobuf(chunk)
                    if nested != chunk:
                        chunk = nested
                    else:
                        chunk = rewrite_url_bytes(chunk)

                out.append(tag)
                out.extend(write_varint(len(chunk)))
                out.extend(chunk)
            elif wire_type == 5:
                if pos + 4 > len(body):
                    return body
                out.append(tag)
                out.extend(body[pos:pos + 4])
                pos += 4
            else:
                return body
    except ValueError:
        return body

    return bytes(out)


def rewrite_http_to_https(body: bytes) -> bytes:
    if HTTP_PREFIX not in body:
        return body
    rewritten = rewrite_protobuf(body)
    if HTTP_PREFIX in rewritten:
        return rewrite_url_bytes(rewritten)
    return rewritten


def read_chunked_body(rfile) -> bytes:
    chunks = bytearray()
    while True:
        line = rfile.readline()
        if not line:
            break
        size_line = line.decode("ascii", errors="replace").strip().split(";", 1)[0]
        if not size_line:
            continue
        chunk_size = int(size_line, 16)
        if chunk_size == 0:
            rfile.readline()
            break
        chunks.extend(rfile.read(chunk_size))
        rfile.readline()
    return bytes(chunks)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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

    def _read_request_body(self) -> bytes | None:
        if self.command not in {"POST", "PUT", "PATCH", "DELETE"}:
            return None

        if self.headers.get("Content-Length") is not None:
            length = int(self.headers["Content-Length"])
            return self.rfile.read(length) if length else b""

        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            return read_chunked_body(self.rfile)

        return b""

    def _proxy(self):
        body = self._read_request_body()
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in SKIP_HEADERS
        }
        headers["Host"] = DMX_HOST
        headers["Accept-Encoding"] = "identity"
        if body is not None:
            headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPSConnection(
            UPSTREAM_IP, 8089, context=UPSTREAM_CTX, timeout=300
        )
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
            content_type = resp.getheader("Content-Type", "")
            if "protobuf" in content_type.lower() or "opamp" in self.path.lower():
                data = rewrite_http_to_https(raw)
            else:
                data = raw
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
