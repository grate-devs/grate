#!/usr/bin/env python3
"""Loopback-only HTTPS file server for a native preindexed WinGet source."""
import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import sys
from urllib.parse import unquote, urlsplit


class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        parsed = Path(unquote(urlsplit(path).path).lstrip('/'))
        if parsed.is_absolute() or '..' in parsed.parts:
            return str(self.server.root / '__invalid__')
        if parsed.parts and parsed.parts[0] == 'assets':
            # Payloads are never copied or re-signed by source construction.
            if len(parsed.parts) != 2:
                return str(self.server.root / '__invalid__')
            return str(self.server.assets / parsed.parts[1])
        return str(self.server.root / parsed)

    def list_directory(self, path):
        self.send_error(404)
        return None


class Server(ThreadingHTTPServer):
    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(10)
            request = self.context.wrap_socket(request, server_side=True)
            request.settimeout(30)
        except (OSError, ssl.SSLError) as error:
            print(f'TLS failed: {error}', file=sys.stderr, flush=True)
            self.shutdown_request(request)
            return
        super().process_request_thread(request, client_address)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'assets', 'certificate', 'private-key'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    with Server(('127.0.0.1', args.port), Handler) as server:
        server.root = args.root.resolve()
        server.assets = args.assets.resolve()
        server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.context.minimum_version = ssl.TLSVersion.TLSv1_2
        server.context.set_alpn_protocols(['http/1.1'])
        server.context.load_cert_chain(args.certificate, args.private_key)
        print(f'Serving preindexed source at https://127.0.0.1:{args.port}', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
