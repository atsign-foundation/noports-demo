#!/usr/bin/env python3
"""Records one real run of the demo, for the web version that needs no Docker.

Run inside the ui box by "./demo.sh record". It drives the same code as the
live page (server.py): it starts ./demo.sh --step and, at every pause, saves

  - the events demo.sh printed since the last pause, with their timing
  - what the device was listening on and connected to at that moment
  - the session handshake, as the NoPorts programs logged it
  - the output of each "look for yourself" command, run there and then

The result is printed as JSON. ui/static/app.js plays it back when the page
is served without server.py. Nothing in it is written by hand.
"""
import datetime
import json
import re
import sys
import time

import server


def note(text):
    print(text, file=sys.stderr, flush=True)


def snapshot():
    server._live["at"] = 0          # not the copy from a second ago
    return server.live()


def record():
    run = server.RUN
    recording = {
        "recorded": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "noports": server.in_box("client", ["cat", "/etc/noports-version"])[1].strip(),
        "live": snapshot(),
        "segments": [],
    }
    run.start()
    index, title = 0, ""
    deadline = time.time() + 600
    while time.time() < deadline:
        began = time.time()
        events, looks = [], []
        while time.time() < deadline:
            got = run.since(run.run_id, index, wait=1)
            ms = round((time.time() - began) * 1000)
            for e in got["events"]:
                events.append({"k": e["k"], "t": e["t"], "ms": ms})
                if e["k"] == "heading":
                    title = e["t"]
                elif e["k"] == "look":
                    looks.append(e["t"].split("|"))
            index = got["next"]
            if got["state"] != "running" and index == len(run.events):
                break
        state = run.state
        segment = {"events": events, "state": state, "live": snapshot(), "exec": {}}
        if re.match(r"[34]\.", title):          # the page asks for it at these pauses only
            segment["handshake"] = server.handshake()
        for box, command, _ in looks:
            note("  %s: %s" % (box, command))
            segment["exec"][box + "\n" + command] = server.run_in_box(box, command)
        recording["segments"].append(segment)
        note("recorded up to: %s (%s)" % (title or "the start", state))
        if state == "paused":
            run.next()
            continue
        if state != "done":
            for e in events:
                note(e["t"])
            sys.exit("The demo did not finish (state: %s), so there is nothing to publish." % state)
        return recording
    sys.exit("The demo did not finish within 10 minutes.")


def check(recording):
    """A recording that does not show the point of the demo must not be published."""
    text = "\n".join(e["t"] for s in recording["segments"] for e in s["events"])
    shown = [s["handshake"] for s in recording["segments"] if s.get("handshake")]
    problems = []
    if text.count("0 of 65535 TCP ports open on the device") < 2:
        problems.append("the two port scans are not both in the recording")
    if not shown or not all(h["ready"] for h in shown):
        problems.append("the session handshake was not found in the logs")
    if not any(s["live"]["session"] for s in recording["segments"]):
        problems.append("no open session was seen on the device")
    if any(not s["live"]["loopback_only"] for s in recording["segments"]):
        problems.append("the device was listening on the network")
    if problems:
        sys.exit("Not publishing this recording: " + "; ".join(problems) + ".")


if __name__ == "__main__":
    result = record()
    check(result)
    json.dump(result, sys.stdout, indent=1)
    sys.stdout.write("\n")
