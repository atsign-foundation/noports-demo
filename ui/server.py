#!/usr/bin/env python3
"""The demo as a web page. Runs inside the ui box (see compose.yaml).

It does not contain a second copy of the demo. It runs ../demo.sh, which
prints tagged lines when DEMO_EVENTS=1 (see scripts/lib.sh), and passes them
to the page. It also answers three questions the page asks:

  /api/live       what is the device listening on and connected to, right now?
  /api/handshake  what did the daemons' logs record about the last session?
  /api/exec       run this command in one of the boxes (the "look for
                  yourself" buttons)

Python standard library only.
"""
import datetime
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
DEMO_DIR = os.path.dirname(HERE)
TOKEN = os.environ.get("DEMO_UI_TOKEN", "")
BOXES = ("device", "scanner", "client", "relay")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png"}


# ---------------------------------------------------------------------------
# Docker: run a command, find a box's container, run something inside a box.
# ---------------------------------------------------------------------------
def sh(args, timeout=30):
    """Returns (exit code, combined output). Never raises."""
    try:
        p = subprocess.run(args, cwd=DEMO_DIR, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        return 124, out + "\n(stopped after %d seconds)" % timeout
    except OSError as e:
        return 127, str(e)


_ids = {}


def box_id(box, fresh=False):
    if fresh or box not in _ids:
        rc, out = sh(["docker", "compose", "ps", "-q", box])
        _ids[box] = out.strip().splitlines()[0] if rc == 0 and out.strip() else ""
    return _ids[box]


def in_box(box, argv, timeout=30):
    for fresh in (False, True):          # the box may have been recreated
        cid = box_id(box, fresh)
        if not cid:
            continue
        rc, out = sh(["docker", "exec", cid] + argv, timeout)
        if "No such container" not in out:
            return rc, out
    return 1, "The %s box is not running. Run ./demo.sh web again." % box


def box_logs(box):
    cid = box_id(box, True)
    return sh(["docker", "logs", "--tail", "600", cid])[1] if cid else ""


# ---------------------------------------------------------------------------
# The run: one ./demo.sh --step at a time, its output kept as a list of events.
# ---------------------------------------------------------------------------
class Run:
    def __init__(self):
        self.cond = threading.Condition()
        self.events = []
        self.state = "idle"      # idle, running, paused, done, failed
        self.run_id = 0
        self.proc = None

    def start(self):
        with self.cond:
            if self.proc and self.proc.poll() is None:
                self.proc.kill()
            self.run_id += 1
            self.events = []
            self.state = "running"
            env = dict(os.environ, DEMO_EVENTS="1", DEMO_NO_SETUP="1", NO_COLOR="1")
            self.proc = subprocess.Popen(["./demo.sh", "--step"], cwd=DEMO_DIR, env=env,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT)
            threading.Thread(target=self._read, args=(self.proc, self.run_id), daemon=True).start()
            self.cond.notify_all()

    def _read(self, proc, run_id):
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("\x1e"):
                kind, _, text = line[1:].partition("\t")
            else:
                kind, text = "out", line
            with self.cond:
                if run_id != self.run_id:
                    return
                self.events.append({"k": kind, "t": text})
                if kind == "pause":
                    self.state = "paused"
                elif kind in ("done", "fail"):
                    self.state = "done" if kind == "done" else "failed"
                self.cond.notify_all()
        rc = proc.wait()
        with self.cond:
            if run_id == self.run_id and self.state not in ("done", "failed"):
                self.state = "failed" if rc else "done"
                self.cond.notify_all()

    def next(self):
        with self.cond:
            if self.state != "paused":
                return
            self.state = "running"
            try:
                self.proc.stdin.write(b"\n")
                self.proc.stdin.flush()
            except OSError:
                pass
            self.cond.notify_all()

    def since(self, run_id, index, wait=25):
        """Events after `index`; waits up to `wait` seconds for something new."""
        deadline = time.time() + wait
        with self.cond:
            if run_id != self.run_id:
                index = 0
            seen_state = self.state
            while len(self.events) <= index and self.state == seen_state and run_id == self.run_id:
                left = deadline - time.time()
                if left <= 0:
                    break
                self.cond.wait(left)
            return {"run": self.run_id, "state": self.state,
                    "events": self.events[index:], "next": len(self.events)}


RUN = Run()


# ---------------------------------------------------------------------------
# /api/live: the device's own view of itself, as demo.sh shows it.
# ---------------------------------------------------------------------------
_names = {"at": 0, "value": ""}


def peer_names():
    """ "<ip>=<box> ..." for the connections script, refreshed once a minute."""
    if time.time() - _names["at"] > 60:
        pairs = []
        for box in ("platform", "relay", "client", "scanner"):
            cid = box_id(box, True)
            rc, ip = sh(["docker", "inspect", "-f",
                         "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", cid]) if cid else (1, "")
            if rc == 0 and ip.strip():
                pairs.append("%s=%s" % (ip.strip(), box))
        _names.update(at=time.time(), value=" ".join(pairs))
    return _names["value"]


def atserver_labels():
    out, port = [], 2500
    with open(os.path.join(DEMO_DIR, "platform", "atsigns")) as f:
        for name in f.read().split():
            out.append("%d=atServer~of~@%s" % (port, name))
            port += 1
    return " ".join(out)


_live = {"at": 0, "value": None, "lock": threading.Lock()}


def live():
    with _live["lock"]:
        if time.time() - _live["at"] < 1 and _live["value"]:
            return _live["value"]
        rc, listeners = in_box("device", ["listeners"])
        _, connections = in_box("device", ["connections", peer_names(), atserver_labels()])
        cid = box_id("device")
        prc, published = sh(["docker", "port", cid]) if cid else (1, "")
        value = {"up": bool(cid), "listeners": listeners.rstrip(), "loopback_only": rc == 0,
                 "connections": connections.rstrip(),
                 "published": published.strip() if prc == 0 else "",
                 "session": "relay:" in connections}
        _live.update(at=time.time(), value=value)
        return value


# ---------------------------------------------------------------------------
# /api/handshake: the nine steps of setting up a session, each backed by the
# line a daemon logged when it happened. A step with no line is reported
# without evidence, and the page marks it "stated, not shown".
#
# The log wording belongs to NoPorts and can change between releases. If it
# does, steps lose their evidence; nothing else breaks.
# ---------------------------------------------------------------------------
STEPS = [
    (1, "msg", "The client asks the relay for a pair of ports",
     [("relay", r"Will handle request from (@\S+)"), ("client", r"Fetching host and port from srvd")], ""),
    (2, "msg", "The relay allots port A to the client and port B to the device",
     [("relay", r"Started session \S+ for \S+ to \S+ using ports \((\d+), (\d+)\)"),
      ("client", r"Received host and port from srvd")], ""),
    (3, "msg", "The client sends a session request to the device",
     [("device", r"ssh_request received from"), ("client", r"Sending session request to the device daemon")], ""),
    (4, "tcp", "The device dials OUT to the relay, port B",
     [("relay", r"Connection on serverSocketB: \d+"), ("device", r"executing \S*srv -h \S+ -p \d+")], ""),
    (5, "msg", "The device replies to the client",
     [("client", r"Received response from the device daemon")],
     "The log shows the reply arriving. That it carries the session key, encrypted "
     "for the client, comes from the NoPorts design documents."),
    (6, "tcp", "The client dials OUT to the relay, port A",
     [("relay", r"Connection on serverSocketA: \d+"), ("client", r"Creating connection to socket rendezvous")], ""),
    (7, "join", "The relay joins the two connections",
     [("relay", r"Added connection\. There are now \d+ connections")], ""),
    (8, "local", "On the device, NoPorts connects to sshd on 127.0.0.1",
     [("device", r"Resolved local host localhost to"), ("device", r"SrvImplDart - localPort 22")],
     "The log shows NoPorts choosing 127.0.0.1 as its target, not the moment it connected, so "
     "no time is shown. The connection itself is listed under \"The device, right now\"."),
    (9, "ssh", "SSH runs end to end, from the client to sshd on the device",
     [("sshd", r"Accepted publickey for \S+ from 127\.0\.0\.1")],
     "The relay forwards these bytes. That it cannot read them comes from the "
     "NoPorts design documents; the demo does not capture packets."),
]
STAMP = re.compile(r"(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d\.\d{1,6})")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def stamp_of(line):
    m = STAMP.search(line)
    if not m:
        return None
    text = m.group(1).replace("T", " ")
    whole, _, frac = text.partition(".")
    return datetime.datetime.strptime(whole, "%Y-%m-%d %H:%M:%S").timestamp() + float("0." + frac)


def tidy(line):
    """A log line without colour codes, level or timestamps, cut to a readable length."""
    line = ANSI.sub("", line)
    line = re.sub(r"\b(INFO|SHOUT|WARNING|SEVERE|FINE|FINER|FINEST)\|", "", line)
    line = STAMP.sub("", line)
    line = re.sub(r"(\s*\|\s*)+", " | ", line).strip(" |:")
    line = re.sub(r"\s+", " ", line)
    return line if len(line) <= 200 else line[:197] + "..."


def last_match(text, pattern):
    rx = re.compile(pattern)
    for line in reversed(text.splitlines()):
        m = rx.search(line)
        if m:
            return line, m
    return None, None


def find(text, pattern, since):
    """The first line matching `pattern` logged at or after `since`. Lines
    with no timestamp cannot be placed, so the newest of those is used."""
    rx = re.compile(pattern)
    undated = (None, None)
    for line in text.splitlines():
        m = rx.search(line)
        if not m:
            continue
        at = stamp_of(line)
        if at is None or since is None:
            undated = (line, m)
        elif at >= since - 0.5:
            return line, m
    return undated


def handshake():
    logs = {"relay": box_logs("relay"), "device": box_logs("device"),
            "client": in_box("client", ["cat", "/tmp/sshnp.log"])[1],
            "sshd": in_box("device", ["cat", "/var/log/sshd.log"])[1]}
    # The session to show is the one the demo opened: it starts where the
    # client's sshnp first spoke to the relay. (doctor.sh opens sessions too.)
    line, _ = last_match(logs["client"], r"Fetching host and port from srvd")
    if not line:
        line, _ = last_match(logs["relay"], STEPS[1][3][0][1])
    since = stamp_of(line) if line else None
    _, m = find(logs["relay"], STEPS[1][3][0][1], since)
    ports = {"a": m.group(1), "b": m.group(2)} if m else {}
    steps, first = [], None
    for n, kind, title, sources, note in STEPS:
        found = None
        for box, pattern in sources:
            line, _ = find(logs[box], pattern, since)
            if line:
                found = {"box": "device" if box == "sshd" else box, "line": tidy(line),
                         "at": None if n == 8 else stamp_of(line)}      # see step 8's note
                break
        if found and found["at"] is not None:
            first = found["at"] if first is None else min(first, found["at"])
        steps.append({"n": n, "kind": kind, "title": title, "note": note, "evidence": found})
    for s in steps:
        e = s["evidence"]
        if e:
            e["ms"] = None if e["at"] is None or first is None else round((e["at"] - first) * 1000)
            del e["at"]
    seen = [s["n"] for s in steps if s["evidence"]]
    return {"ready": 2 in seen and 7 in seen, "ports": ports, "steps": steps}


# ---------------------------------------------------------------------------
# /api/exec: run one command in one box, for the "look for yourself" buttons.
# ---------------------------------------------------------------------------
def run_in_box(box, command):
    if box not in BOXES:
        return {"code": 64, "output": "Unknown box."}
    command = command.strip()
    if not command or len(command) > 300:
        return {"code": 64, "output": "Give a command of up to 300 characters."}
    began = time.time()
    rc, out = in_box(box, ["sh", "-c", command], timeout=90)
    lines = out.rstrip("\n").splitlines()
    if len(lines) > 400:
        lines = lines[:400] + ["(%d more lines not shown)" % (len(lines) - 400)]
    return {"box": box, "command": command, "code": rc, "output": "\n".join(lines),
            "seconds": round(time.time() - began, 1)}


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, ctype="application/json", headers=()):
        if not isinstance(body, bytes):
            body = (json.dumps(body) if ctype == "application/json" else body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def allowed(self, query):
        """The key demo.sh printed, as ?t=... once and then as a cookie."""
        if TOKEN == "off":
            return True, ()
        if query.get("t", [""])[0] == TOKEN:
            return True, (("Set-Cookie", "np_demo=%s; HttpOnly; SameSite=Strict; Path=/" % TOKEN),)
        cookies = dict(c.strip().partition("=")[::2] for c in self.headers.get("Cookie", "").split(";"))
        return cookies.get("np_demo") == TOKEN, ()

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/healthz":
            return self.reply(200, "ok", "text/plain")
        ok, headers = self.allowed(query)
        if not ok:
            return self.reply(403, "This page needs the key in the address that ./demo.sh web printed. "
                                   "Run it again and use that address.", "text/plain")
        if headers:                                   # drop the key from the address bar
            return self.reply(303, "", "text/plain", headers + (("Location", "/"),))
        if url.path == "/api/events":
            run_id = int(query.get("run", ["0"])[0])
            index = int(query.get("from", ["0"])[0])
            return self.reply(200, RUN.since(run_id, index))
        if url.path == "/api/live":
            return self.reply(200, live())
        if url.path == "/api/handshake":
            return self.reply(200, handshake())
        name = "index.html" if url.path == "/" else url.path.lstrip("/")
        path = os.path.join(STATIC, name)
        ext = os.path.splitext(name)[1]
        if "/" in name or ext not in TYPES or not os.path.isfile(path):
            return self.reply(404, "Not found", "text/plain")
        with open(path, "rb") as f:
            return self.reply(200, f.read(), TYPES[ext])

    def do_POST(self):
        url = urlparse(self.path)
        ok, _ = self.allowed({})
        # The custom header means another website cannot send this request
        # from your browser without the browser asking this server first.
        if not ok or self.headers.get("X-NoPorts-Demo") != "1":
            return self.reply(403, {"error": "not allowed"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}") if length <= 4096 else {}
        except ValueError:
            body = {}
        if url.path == "/api/start":
            RUN.start()
            return self.reply(200, {"ok": True})
        if url.path == "/api/next":
            RUN.next()
            return self.reply(200, {"ok": True})
        if url.path == "/api/exec":
            return self.reply(200, run_in_box(str(body.get("box", "")), str(body.get("command", ""))))
        return self.reply(404, {"error": "not found"})


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    if not TOKEN:
        sys.exit("DEMO_UI_TOKEN is not set. Start this with ./demo.sh web, which sets it.")
    # All interfaces inside the box; compose.yaml publishes it on 127.0.0.1 only.
    Server(("0.0.0.0", 8080), Handler).serve_forever()
