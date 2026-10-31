"""A stand-in for the Home Assistant Supervisor's API, for testing the add-ons without it.

The parts the add-ons use: the services API (the MariaDB add-on's mysql service), the
discovery API, and /addons/self/info. Run as the container "supervisor" at 172.30.32.2 on a
network like the Supervisor's (172.30.32.0/23), which is also where the ingress requests come
from (tests/run.sh sends them with curl from this container).

Environment:
  SUPERVISOR_TOKEN   the token the add-ons must send (Authorization: Bearer)
  MOCK_MYSQL         host:port:username:password of the mysql service, empty: no service
  STATE_DIR          where the discovery messages are written (discovery.json), and where
                     the test puts the add-on's options (options.json)
"""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import uuid

TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")
STATE = Path(os.environ.get("STATE_DIR", "/state"))
DISCOVERY = STATE / "discovery.json"


def ok(data: dict | None = None) -> tuple[int, dict]:
    return 200, {"result": "ok", "data": data or {}}


def error(status: int, message: str) -> tuple[int, dict]:
    return status, {"result": "error", "message": message}


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _route(self, method: str) -> tuple[int, dict]:
        if not self._authorized():
            return error(401, "Unauthorized")
        path = self.path.split("?")[0]
        if method == "GET" and path == "/services/mysql":
            if not os.environ.get("MOCK_MYSQL"):
                return error(400, "Service not enabled")
            host, port, user, password = os.environ["MOCK_MYSQL"].split(":", 3)
            return ok(
                {
                    "host": host,
                    "port": int(port),
                    "username": user,
                    "password": password,
                }
            )
        if method == "GET" and path == "/addons/self/options/config":
            # the options as the Supervisor validated them: what the test wrote into options.json
            return ok(json.loads((STATE / "options.json").read_text()))
        if method == "GET" and path == "/addons/self/info":
            return ok(
                {
                    "slug": "local_test",
                    "hostname": os.environ.get("ADDON_HOSTNAME", "local-test"),
                    "ingress": True,
                }
            )
        if method == "GET" and path == "/info":
            return ok(
                {
                    "supervisor": "test",
                    "homeassistant": "test",
                    "arch": "aarch64",
                    "timezone": "UTC",
                }
            )
        if method == "POST" and path == "/discovery":
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            messages = json.loads(DISCOVERY.read_text()) if DISCOVERY.exists() else []
            message = {
                "uuid": uuid.uuid4().hex,
                "service": body.get("service"),
                "config": body.get("config"),
            }
            messages.append(message)
            DISCOVERY.write_text(json.dumps(messages, indent=2))
            print(
                f"discovery: {message['service']} {sorted((message['config'] or {}).keys())}",
                flush=True,
            )
            return ok({"uuid": message["uuid"]})
        return error(404, f"no mock for {method} {path}")

    def do_GET(self) -> None:  # noqa: N802
        self._reply(*self._route("GET"))

    def do_POST(self) -> None:  # noqa: N802
        self._reply(*self._route("POST"))

    def do_DELETE(self) -> None:  # noqa: N802
        self._reply(*self._route("DELETE"))

    def log_message(self, fmt: str, *args) -> None:
        print(
            f"supervisor: {self.command} {self.path} -> {args[1] if len(args) > 1 else ''}",
            flush=True,
        )


if __name__ == "__main__":
    STATE.mkdir(parents=True, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
