# NoPorts demo: the full details

This demo logs you in over SSH to a machine, then port-scans all 65,535 TCP
ports of that same machine while you are logged in. The scan finds nothing
open. The "machine" is a Docker container standing in for a real one, and
everything runs on your computer in Docker. You need no accounts and no
purchased Atsigns, and after the first run you need no Internet access.

For a visual walkthrough of how it all fits together, with a diagram for each
part, see the slide deck
[docs/noports-demo-explained.pptx](noports-demo-explained.pptx).

## Quick start

1. Install Docker: Docker Desktop on macOS, or Docker Engine with the Compose
   plugin (v2.20 or newer) on Linux. Your CPU must be x86-64 or arm64.
2. `git clone https://github.com/atsign-foundation/noports-demo && cd noports-demo`
3. `./demo.sh`. The first run downloads and builds images, which takes 1–3 minutes
   and needs the Internet. Later runs take about 10 seconds and work offline.
   When online, each run picks up a newer NoPorts release or platform image if
   there is one.
4. If anything fails, run `./doctor.sh`. It says what failed and why. `demo.sh` also
   runs it for you when something fails.
5. When you are done, run `./teardown.sh`. It removes every container, the
   network, and all keys and state.

`./demo.sh --step` pauses between acts, and at each pause tells you how to look
inside the boxes yourself. `./demo.sh web` runs the same demo as
[a web page](#the-web-page). `./demo.sh shell` gives you an
interactive shell on the device over NoPorts, so you can run `ss -tuln` there
yourself.

## Which box is which

```
   "Atsign's cloud" (local)          your side                      attacker
  +-------------------------+       +--------------------------+   +---------+
  | platform     LISTENS    | <---- | device                   |   | scanner |
  |  atDirectory, atServers |       |  sshnpd    (dials out)   |<--|  nmap   |
  +-------------------------+       |  sshd on 127.0.0.1 only  |   +---------+
  | relay        LISTENS    | <---- |                          |   scans all
  |  srvd                   |       +--------------------------+   65535 TCP
  +-------------------------+                                       ports
              ^      ^
              |      +------------- client: sshnp + OpenSSH (dials out)
              +-------------------- (both sides dial the relay; it joins them)

  All five boxes share one flat Docker network: no firewall, no NAT.
  Arrows point from the side that opens the connection.
  None of the five publishes a port to your computer.
```

`./demo.sh web` adds a sixth box, `ui`, which serves the web page. It is on a
network of its own and is described under [The web page](#the-web-page).

| Box | What it is | Listens? |
|---|---|---|
| **platform** | `atsigncompany/ephemeral`: an atDirectory plus one atServer per Atsign (`@demo_client`, `@demo_device`, `@demo_relay`). It stands in for the hosted Atsign Platform. | Yes, as the hosted one does |
| **relay** | `srvd`, the socket rendezvous, signed in as `@demo_relay`. It stands in for Atsign's hosted relays. | Yes, one pair of ports per session |
| **device** | The machine you log in to. `sshnpd` runs as `@demo_device`, and `sshd` is bound to `127.0.0.1`. | **Nothing reachable from the network** |
| **client** | Your laptop: `sshnp` as `@demo_client`, plus OpenSSH. | No |
| **scanner** | nmap, on the same network as the device. | No |

## What you just saw

1. **Before connecting**, the demo lists every listening socket inside the
   device. Only loopback addresses appear: `sshd` on `127.0.0.1:22`, and Docker's
   own DNS resolver on `127.0.0.11`, which every container has. It also confirms
   that Docker publishes no ports for the device. Then the scanner sweeps all
   65,535 TCP ports of the device. Every port is closed (TCP reset): the device is
   reachable, it simply has nothing to connect to. For contrast, the same scan of
   the platform finds its open ports, which shows the scanner works.
2. **Connecting.** `sshnp` on the client sends an encrypted session request to the
   device through the atServers on the platform. The relay assigns a pair of ports.
   The device's daemon and the client each **dial out** to the relay, and the relay
   joins the two connections. The client's OpenSSH logs in through that tunnel,
   verifying the device's real SSH host key, and runs commands. The device's
   `sshd` logs the login as coming from `127.0.0.1`, because the NoPorts daemon
   handed it over locally.
3. **While connected**, the scan runs again and finds nothing. The device's
   listening sockets have not changed. Its connection table shows only outbound
   connections, to atServers on the platform and to the relay. Since nothing on
   the device listens on the network, the device must have opened every one of
   those connections itself.
4. The relay is listening during the session, one port for each side. It passes
   bytes it cannot read: SSH is encrypted end to end, and NoPorts adds a second
   layer with a session key that goes from device to client encrypted for the
   client, so the relay and the atServers never see it.

## The web page

`./demo.sh web` runs the same demo as a page in your browser, at
`http://localhost:8080`. Set `DEMO_UI_PORT` to use another port. The page has
three parts:

- **The story.** The same four acts, with the explanation as text and the
  commands and their real output in terminal blocks. A **Next step** button
  replaces Enter.
- **Look for yourself.** At each stop, buttons run a real command inside a box
  and show what it printed. You can also type your own command.
- **The device, right now.** The device's listening sockets and connections,
  refreshed every two seconds, and a diagram of the session being set up.

It is not a second copy of the demo. A small server
([ui/server.py](../ui/server.py)) runs `demo.sh` and shows what it prints, so
the terminal and the page cannot drift apart.

**The diagram is drawn from logs.** Setting up a session takes nine steps and
about half a second. After you connect, the server reads what `sshnp`, `sshnpd`
and `srvd` logged, finds the line each step left behind, and the page replays
the steps slowly in the order they really happened. Click a step to see its
line. Three limits:

- The wording of those log lines belongs to NoPorts and can change in a new
  release. A step whose line is not found is marked "stated, not shown", and
  nothing else breaks.
- Two steps show less than their titles say, and the page says so. For step 5
  the log shows the device's reply arriving, not that it carries the session
  key. For step 8 it shows NoPorts choosing `127.0.0.1` as its target, not the
  moment it connected.
- That the relay cannot read the session is still stated, not shown.

**What the web page costs.** To run commands in the other boxes, the `ui` box is
given Docker's control socket. That is full control of Docker on your computer,
so the box is built to be hard to reach:

- It starts only when you run `./demo.sh web`.
- Its port is published on `127.0.0.1` only, so other computers cannot connect.
- It answers only requests that carry the key in the address `demo.sh` prints.
  A new key is made each time.
- It sits on its own network. The scanner's view of the device is unchanged,
  and the device still publishes no ports.

`./teardown.sh` removes it with everything else.

**In a codespace.** The "Open in GitHub Codespaces" button in the README
starts a private Linux machine on GitHub, sets the demo up there, and opens the
web page. Things to know:

- Nobody has run the demo in a codespace yet. If you try it, please open an
  issue to say how it went.
- It runs on GitHub's machine, not your computer, and uses your GitHub
  account's Codespaces allowance.
- There is no key in the address, because GitHub already limits the page to
  you. Keep the forwarded port private: the page can run commands in the boxes.

## What this does not prove

- **No real NAT or firewall traversal.** Everything runs on one host, on one
  Docker bridge. In real use the device sits behind NAT or a firewall and dials
  out across the Internet to Atsign's hosted atServers and relays. This demo does
  not exercise that path, and it does not measure latency or reliability.
- **Nothing about production key handling.** The Atsigns are throwaway and the
  platform is a local test image. The keys here are unencrypted files in Docker
  volumes, created by one-time activation secrets that the platform image prints
  to its own logs. Its Redis has a well-known password, and its admin UI on 9001
  has none. Enrollment, key storage, rotation and revocation in a real deployment
  are not shown.
- **NoPorts does not fix the device itself.** Software on the device can still have
  vulnerabilities. Anyone with an authorized client Atsign and SSH key gets in.
  "No listening ports" is not "no attack surface": `sshnpd` still processes
  messages that arrive over the connections it opens, and the device trusts the
  atServers and relay it dials.
- **The demo scans TCP over IPv4 only.** It does not run a UDP scan (UDP scans
  through a bridge are slow and inconclusive). Instead it lists the device's UDP
  sockets from the inside: only Docker's resolver on loopback. The Docker network
  has no IPv6.
- **"The relay cannot read it" is stated, not shown.** The demo does not capture
  packets. The claim comes from the NoPorts design documentation (see *How it
  works* in the NoPorts docs).

## Read the whole thing in five minutes

| File | Purpose |
|---|---|
| [compose.yaml](../compose.yaml) | The five boxes and their one network: none of them has a `ports:` section. Then the optional `ui` box for the web page, which has one. |
| [Dockerfile](../Dockerfile) | Builds the device, client, relay and scanner images from Debian and the official NoPorts release tarball, checked against the release's own checksums. |
| [device/sshd_config](../device/sshd_config) | `ListenAddress 127.0.0.1` and key-only logins. |
| [platform/atsigns](../platform/atsigns) | The three Atsigns that the platform creates at start-up. |
| [.env](../.env) | Atsign names and the platform's domain, shared by Compose and the scripts. |
| [demo.sh](../demo.sh) | Setup, then the four acts. Every command it runs is printed before its output. |
| [doctor.sh](../doctor.sh) | Ordered checks, each with a cause and a fix. |
| [teardown.sh](../teardown.sh) | `docker compose down --volumes`, then a check that nothing is left. |
| [docs/noports-demo-explained.pptx](noports-demo-explained.pptx) | Slide deck explaining the demo, with diagrams. |
| [ui/server.py](../ui/server.py) | The web page's server: runs `demo.sh`, reads the device's state and the daemons' logs, and runs the "look for yourself" commands. Python standard library only. |
| [ui/static/](../ui/static/) | The page itself: one HTML file, one stylesheet, one script and the Atsign logo, with no libraries. |
| [.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) | Tells GitHub Codespaces how to run the demo. |
| [scripts/in-container/](../scripts/in-container/) | Small scripts that run inside the boxes: start the daemons, activate an Atsign, open the SSH session, and list sockets. |

## Versions

The demo tracks the newest NoPorts and platform releases.

| Component | Version |
|---|---|
| NoPorts (`sshnpd`, `sshnp`, `srvd`, `at_activate`) | The newest NoPorts release (v5.18.2 at the time of writing), from the release tarballs `sshnp-linux-x64.tgz` / `sshnp-linux-arm64.tgz` |
| Platform | `atsigncompany/ephemeral:latest` (amd64 + arm64) |
| Base image | `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` |
| nmap | Debian trixie's package (7.95 at the time of writing) |

- **How "newest" is chosen.** The demo uses the release that the noports repo's
  GitHub "latest release" link points to.
- **Updates.** Whenever GitHub is reachable, `demo.sh` rebuilds the images if a newer
  NoPorts release exists, and pulls a newer platform image if there is one. A new
  platform image starts blank, so the demo re-activates the Atsigns automatically.
  Offline, it uses whatever is already on your machine.
- **Integrity, not pinning.** The build checks each tarball against the SHA-256 in
  that release's own `checksums.txt`. This catches a corrupted or swapped download.
  It does not make the build reproducible.
- **To pin a version,** set `NOPORTS_VERSION=v5.18.2` in [.env](../.env), or run
  `NOPORTS_VERSION=v5.18.2 ./demo.sh`. To pin the platform, replace `:latest` in
  [compose.yaml](../compose.yaml) with a digest. `./doctor.sh` reports which NoPorts
  version the images contain, and warns if a newer one is out.

**The platform's certificate expires.** Each platform image contains a real,
publicly trusted TLS certificate for `vip.ve.atsign.zone`. In the image current at
the time of writing it is valid until **14 December 2026**. After a certificate
expires, every client refuses to connect. Running `./demo.sh` online pulls a fresh
image. `./doctor.sh` warns two weeks before the certificate in your local image
expires.

## Notes on the platform image

`atsigncompany/ephemeral` has no published documentation. This is what we found by
reading it and running it:

- At start-up it reads a list of names from `/tmp/setup/atsigns` (26 by default,
  `alpha` to `zulu`), and for each one creates an atServer on port `FIRST_PORT`,
  `FIRST_PORT+1`, and so on. It also creates a random one-time activation (CRAM)
  secret, written to `/atsign/atservers/<name>/CRAM` and **printed to the
  container log**. The demo mounts its own three-name list instead, and activates
  each Atsign with `at_activate onboard --cramkey`, run on the box that owns it.
- The atDirectory listens on 64, and on 443 for HTTPS. It answers each name with
  `vip.ve.atsign.zone:<port>`. It loads these records about 15 seconds after start.
  The compose health check waits for them.
- Inside the demo, `vip.ve.atsign.zone` is a Docker network alias for the platform.
  In public DNS the name points at a private address (`10.64.64.64`), so nothing
  outside your machine is involved. No extra CA is needed: the certificate chains
  to Google Trust Services, and Debian's `ca-certificates` trusts that.
- Port 9001 is supervisord's web UI, without authentication. Port 6379 is the
  atDirectory's Redis.
- It does **not** include a socket rendezvous, so `srvd` runs in its own box with
  its own Atsign from the same platform.
- atServer data lives inside the container, so removing the container resets the
  platform. `demo.sh` notices when keys and platform are out of step and starts
  again cleanly.

## Platform support

- Tested: macOS (Apple silicon) with Docker Desktop, arm64 images. The amd64 images
  also ran the full demo on the same Mac under Docker Desktop's emulation.
- Expected to work but untested: Linux on x86-64 or arm64, and Intel Macs.
- Expected to work but untested: Windows, inside WSL 2. See
  [Running on Windows](#running-on-windows).
- Not supported: 32-bit ARM and other CPUs (no platform image). Windows outside
  WSL 2 (PowerShell, Command Prompt, Git Bash).
- `demo.sh` rebuilds the images when they are missing, when the NoPorts version
  changes, or when `scripts/in-container/` changes. After you edit the
  Dockerfile, run `docker compose --profile ui build` yourself.

## Running on Windows

Nobody has run the demo on Windows yet. This is the route we expect to work. If
you try it, please open an issue to say how it went.

The scripts need bash, and the boxes are Linux containers, so run the demo
inside WSL 2 (Windows Subsystem for Linux), where it should behave as it does
on Linux.

1. Install WSL 2 with a Linux distribution: in PowerShell, run `wsl --install`.
   This installs Ubuntu by default.
2. Install Docker Desktop. In its settings, under **Resources → WSL
   integration**, turn on integration for your distribution.
3. Open the Ubuntu terminal. Run every command from the quick start there,
   starting with `git clone`.

Two things to get right:

- **Clone inside WSL, not under `C:\`.** Keep the repository in your WSL home
  folder (for example `~/noports-demo`), not under `/mnt/c/`. Files under
  `/mnt/c/` are slow to reach from Docker and can lose their executable
  permission.
- **Do not use a copy cloned by Git for Windows.** The scripts need Unix line
  endings. The repository's `.gitattributes` asks Git for them on every
  system, but cloning inside WSL avoids the question.

PowerShell, Command Prompt and Git Bash are not supported. Git Bash rewrites
the paths passed to Docker and handles interactive sessions badly, so failures
there are hard to diagnose.
