"""Home Assistant's side of the HAOS test (tests/haos/haos-check.sh), as a real HA user.

    python3 ha.py <command> [args]
      token                       a fresh access token from the refresh token of onboarding
      ingress <ingress entry>     the add-on's admin UI through Home Assistant's ingress, as that
                                  user: an ingress session (supervisor/api /ingress/session over the websocket), then
                                  GET <ingress entry>/ (the add-on's /api/hassio_ingress/<token>)
                                  with its cookie
      discovered                  the config flows in progress that the Supervisor's discovery started
      confirm <flow id>           confirm a hassio_confirm flow
      states <entity prefix>      the states of the entities whose entity_id has that prefix

Standard library only. HA on http://127.0.0.1:${HA_PORT:-18123}; the onboarding's tokens in
${HA_TOKENS:-/tmp/haos_tokens.json}.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.parse
import urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('HA_PORT', '18123')}"
TOKENS = os.environ.get("HA_TOKENS", "/tmp/haos_tokens.json")


def call(method, path, body=None, token=None, form=False, headers=None):
    data = None
    h = dict(headers or {})
    if body is not None:
        data = (
            urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()
        )
        h["Content-Type"] = (
            "application/x-www-form-urlencoded" if form else "application/json"
        )
    if token:
        h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=120) as res:
        return res.status, res.read().decode()


def token() -> str:
    saved = json.load(open(TOKENS))
    _, text = call(
        "POST",
        "/auth/token",
        {
            "grant_type": "refresh_token",
            "refresh_token": saved["refresh_token"],
            "client_id": f"{BASE}/",
        },
        form=True,
    )
    return json.loads(text)["access_token"]


def ws(tok: str, message: dict):
    """One command over the websocket API (a raw RFC 6455 client: the standard library only)."""
    import base64
    import socket
    import struct

    host, port = "127.0.0.1", int(BASE.rsplit(":", 1)[1])
    sock = socket.create_connection((host, port), timeout=60)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        f"GET /api/websocket HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    buf = buf.split(b"\r\n\r\n", 1)[1]

    def send(obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        head = bytes([0x81])
        n = len(data)
        head += (
            bytes([0x80 | n])
            if n < 126
            else bytes([0x80 | 126]) + struct.pack(">H", n)
            if n < 65536
            else bytes([0x80 | 127]) + struct.pack(">Q", n)
        )
        sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv():
        nonlocal buf

        def need(k):
            nonlocal buf
            while len(buf) < k:
                buf += sock.recv(65536)

        need(2)
        n = buf[1] & 0x7F
        off = 2
        if n == 126:
            need(4)
            n = struct.unpack(">H", buf[2:4])[0]
            off = 4
        elif n == 127:
            need(10)
            n = struct.unpack(">Q", buf[2:10])[0]
            off = 10
        need(off + n)
        data, buf = buf[off : off + n], buf[off + n :]
        return json.loads(data)

    recv()  # auth_required
    send({"type": "auth", "access_token": tok})
    assert recv()["type"] == "auth_ok"
    send({"id": 1, **message})
    while True:
        res = recv()
        if res.get("id") == 1:
            sock.close()
            if not res.get("success"):
                raise RuntimeError(res)
            return res["result"]


def main() -> int:
    cmd = sys.argv[1]
    tok = token()
    if cmd == "token":
        print(tok)
    elif cmd == "ingress":
        entry = sys.argv[2].rstrip("/")
        # (as the frontend does: the Supervisor's API through the websocket, an admin's)
        session = ws(
            tok,
            {
                "type": "supervisor/api",
                "endpoint": "/ingress/session",
                "method": "post",
            },
        )["session"]
        status, page = call(
            "GET", f"{entry}/", headers={"Cookie": f"ingress_session={session}"}
        )
        links = sorted(set(re.findall(r'href="([^"]+)"', page)))
        print(
            json.dumps(
                {
                    "status": status,
                    "ingress_entry": entry,
                    "signed_in_as": re.findall(r"ingress-tester", page)[:1],
                    "absolute_links_left": [
                        link
                        for link in links
                        if link.startswith("/") and not link.startswith(entry)
                    ],
                    "sample_links": links[:4],
                    "title": re.findall(r"<title>([^<]*)", page)[:1],
                },
                indent=1,
            )
        )
        # and without the session cookie: Home Assistant refuses
        try:
            status, _ = call("GET", f"{entry}/")
        except urllib.error.HTTPError as err:
            status = err.code
        print(json.dumps({"without_session": status}))
    elif cmd == "discovered":
        flows = [
            f
            for f in ws(tok, {"type": "config_entries/flow/progress"})
            if f.get("handler") == "firefox_sync"
        ]
        print(
            json.dumps(
                [
                    {k: f.get(k) for k in ("flow_id", "step_id", "context")}
                    for f in flows
                ],
                indent=1,
            )
        )
    elif cmd == "confirm":
        _, text = call(
            "POST", f"/api/config/config_entries/flow/{sys.argv[2]}", {}, token=tok
        )
        res = json.loads(text)
        print(
            json.dumps({k: res.get(k) for k in ("type", "title", "reason", "errors")})
        )
    elif cmd == "states":
        _, text = call("GET", "/api/states", token=tok)
        for s in sorted(json.loads(text), key=lambda s: s["entity_id"]):
            if s["entity_id"].split(".", 1)[1].startswith(sys.argv[2]):
                print(
                    f"{s['entity_id']:62} {s['state']:>10} {s['attributes'].get('unit_of_measurement', '')}"
                )
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
