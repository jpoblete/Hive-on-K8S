#!/usr/bin/env python3
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
"""Local HTTP proxy for HiveServer2 Web UI (port 10002).

Hive 4.x HttpServer routes by request.getServerPort(), which follows the Host
header. kubectl port-forward to localhost:11202 sends Host :11202 while HS2
only registers handlers for connector port 10002. This proxy listens on the
public lab port and forwards to an upstream port-forward with Host: localhost:10002.
"""
import argparse
import http.client
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HS2WebUiProxyHandler(BaseHTTPRequestHandler):
    upstream_host = "127.0.0.1"
    upstream_port = 0
    hs2_web_port = 10002

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), fmt % args))

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {}
        for key, value in self.headers.items():
            lk = key.lower()
            if lk in ("host", "connection", "proxy-connection", "keep-alive", "te", "trailers", "transfer-encoding", "upgrade"):
                continue
            headers[key] = value
        headers["Host"] = "localhost:%s" % self.hs2_web_port
        headers["Connection"] = "close"
        conn = http.client.HTTPConnection(self.upstream_host, self.upstream_port, timeout=120)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                lk = key.lower()
                if lk in ("connection", "transfer-encoding", "content-length"):
                    continue
                self.send_header(key, value)
            data = resp.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data:
                self.wfile.write(data)
        except (http.client.HTTPException, OSError, socket.timeout) as exc:
            self.send_error(502, "HS2 Web UI upstream error: %s" % exc)
        finally:
            conn.close()

    def do_GET(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_POST(self):
        self._proxy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--hs2-web-port", type=int, default=10002)
    args = parser.parse_args()
    HS2WebUiProxyHandler.upstream_port = args.upstream_port
    HS2WebUiProxyHandler.hs2_web_port = args.hs2_web_port
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), HS2WebUiProxyHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
