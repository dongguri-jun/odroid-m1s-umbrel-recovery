#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# How to run:
#   python3 tests/fixtures/shutdown-ui-cache/server.py --root /path/to/ui --host 127.0.0.1 --port 4173 --request-log /tmp/requests.jsonl
from __future__ import annotations

import contextlib
import ipaddress
import json
import mimetypes
import posixpath
import signal
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import FrameType
from typing import TYPE_CHECKING, ClassVar, Final, ParamSpec, TypeVar
from urllib.parse import unquote, urlsplit

ONE_YEAR_SECONDS: Final = 365 * 24 * 60 * 60

if TYPE_CHECKING:
    from typing import override
else:
    P = ParamSpec('P')
    R = TypeVar('R')

    def override(func: Callable[P, R]) -> Callable[P, R]:
        return func


@dataclass(frozen=True, slots=True)
class ServerConfig:
    root: Path
    host: str
    port: int
    request_log: Path


class ConfigError(Exception):
    message: str

    def __init__(self, message: str) -> None:
        self.message = message
        super().__init__(message)


class ShutdownUiHandler(BaseHTTPRequestHandler):
    ui_root: ClassVar[Path]
    request_log: ClassVar[Path]

    def do_HEAD(self) -> None:
        self.serve_request(send_body=False)

    def do_GET(self) -> None:
        self.serve_request(send_body=True)

    @override
    def log_message(self, format: str, *args: str) -> None:
        return

    def serve_request(self, *, send_body: bool) -> None:
        target = self.resolve_request_path()
        if target is None:
            self.finish_status(HTTPStatus.NOT_FOUND, send_body=send_body)
            return
        self.serve_file(target, immutable=self.path.startswith('/assets/'), send_body=send_body)

    def resolve_request_path(self) -> Path | None:
        raw_path = urlsplit(self.path).path
        if raw_path in {'', '/'}:
            candidate = self.ui_root / 'index.html'
        else:
            decoded_path = unquote(raw_path)
            if any(part == '..' for part in decoded_path.split('/')):
                return None
            normalized = posixpath.normpath(decoded_path).lstrip('/')
            candidate = (self.ui_root / normalized).resolve()
        if not contains_path(self.ui_root, candidate) or not candidate.is_file():
            return None
        return candidate

    def serve_file(self, path: Path, *, immutable: bool, send_body: bool) -> None:
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        _ = self.send_header('Content-Type', mimetypes.guess_type(path.name)[0] or 'application/octet-stream')
        _ = self.send_header('Content-Length', str(len(body)))
        if immutable:
            _ = self.send_header('Cache-Control', f'public, max-age={ONE_YEAR_SECONDS}, immutable')
        else:
            _ = self.send_header('Cache-Control', 'no-cache, max-age=0, must-revalidate')
            _ = self.send_header('Pragma', 'no-cache')
        self.end_headers()
        if send_body:
            _ = self.wfile.write(body)
        self.write_request_log(HTTPStatus.OK)

    def finish_status(self, status: HTTPStatus, *, send_body: bool) -> None:
        body = f'{status.value} {status.phrase}\n'.encode()
        self.send_response(status)
        _ = self.send_header('Cache-Control', 'no-store')
        _ = self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if send_body:
            _ = self.wfile.write(body)
        self.write_request_log(status)

    def write_request_log(self, status: HTTPStatus) -> None:
        entry = {
            'ts': datetime.now(UTC).isoformat(timespec='milliseconds'),
            'method': self.command,
            'path': urlsplit(self.path).path,
            'status': status.value,
        }
        self.request_log.parent.mkdir(parents=True, exist_ok=True)
        with self.request_log.open('a', encoding='utf-8') as handle:
            _ = handle.write(json.dumps(entry, separators=(',', ':')))
            _ = handle.write('\n')


def contains_path(root: Path, candidate: Path) -> bool:
    return candidate == root or root in candidate.parents


def require_loopback_host(host: str) -> str:
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ConfigError('host must be a loopback IP address') from error
    if not address.is_loopback:
        raise ConfigError('host must be a loopback IP address')
    return host


def parse_args(argv: list[str]) -> ServerConfig:
    root_arg: Path | None = None
    host = '127.0.0.1'
    port = 4173
    request_log_arg: Path | None = None
    position = 0
    while position < len(argv):
        option = argv[position]
        if option == '--root':
            position += 1
            if position >= len(argv):
                raise ConfigError('--root requires a value')
            root_arg = Path(argv[position])
        elif option == '--host':
            position += 1
            if position >= len(argv):
                raise ConfigError('--host requires a value')
            host = argv[position]
        elif option == '--port':
            position += 1
            if position >= len(argv):
                raise ConfigError('--port requires a value')
            try:
                port = int(argv[position])
            except ValueError as error:
                raise ConfigError('--port must be an integer') from error
        elif option == '--request-log':
            position += 1
            if position >= len(argv):
                raise ConfigError('--request-log requires a value')
            request_log_arg = Path(argv[position])
        elif option in {'--help', '-h'}:
            print('Usage: server.py --root ROOT [--host 127.0.0.1] [--port 4173] --request-log PATH')
            raise SystemExit(0)
        else:
            raise ConfigError(f'unknown argument: {option}')
        position += 1
    if root_arg is None:
        raise ConfigError('--root is required')
    if request_log_arg is None:
        raise ConfigError('--request-log is required')
    root = root_arg.resolve()
    if not root.is_dir():
        raise ConfigError('root must be an existing directory')
    return ServerConfig(
        root=root,
        host=require_loopback_host(host),
        port=port,
        request_log=request_log_arg.resolve(),
    )


def make_handler(config: ServerConfig) -> type[ShutdownUiHandler]:
    class BoundShutdownUiHandler(ShutdownUiHandler):
        ui_root: ClassVar[Path] = config.root
        request_log: ClassVar[Path] = config.request_log

    return BoundShutdownUiHandler


def run(config: ServerConfig) -> None:
    server = ThreadingHTTPServer((config.host, config.port), make_handler(config))
    stop_once = threading.Event()

    def request_shutdown(signum: int, frame: FrameType | None) -> None:
        del signum, frame
        if stop_once.is_set():
            return
        stop_once.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    old_term = signal.signal(signal.SIGTERM, request_shutdown)
    old_int = signal.signal(signal.SIGINT, request_shutdown)
    try:
        with server:
            server.serve_forever(poll_interval=0.2)
    finally:
        with contextlib.suppress(ValueError):
            _ = signal.signal(signal.SIGTERM, old_term)
            _ = signal.signal(signal.SIGINT, old_int)


def main(argv: list[str]) -> int:
    try:
        run(parse_args(argv))
    except ConfigError as error:
        print(f'error: {error.message}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
