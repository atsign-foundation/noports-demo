#!/usr/bin/env bash
# Checks everything the demo depends on, in order. For each failure it says
# what failed and the likely cause. Changes nothing; safe to run any time.
# It never prints the platform's logs: they contain activation secrets.
. "$(dirname "$0")/scripts/lib.sh"

PROBLEMS=0
fail() { bad "$1"; shift; why "$@"; PROBLEMS=$((PROBLEMS + 1)); }
finish() {
  echo
  if [ "$PROBLEMS" = 0 ]; then say "${GREEN}${BOLD}No problems found.${RESET}"
  else say "${RED}${BOLD}$PROBLEMS problem(s) found.${RESET} Fix the first one first; later ones often follow from it."; fi
  exit $(( PROBLEMS > 0 ))
}
# Run a command inside a demo box, with a hard time limit inside the container.
in_box() { local svc=$1 secs=$2; shift 2; dc exec -T --user demo "$svc" timeout "$secs" "$@"; }
# Last few warning/error lines of a daemon's current run (never the platform's).
recent_errors() {
  local id since; id=$(dc ps -q "$1"); [ -n "$id" ] || return
  since=$(docker inspect -f '{{.State.StartedAt}}' "$id")
  docker logs --since "$since" "$id" 2>&1 | grep -E '^(SEVERE|WARNING)' | tail -3 | cut -c1-200 | sed 's/^/        log: /'
}

heading "NoPorts demo doctor"

# ---- 1. Docker ------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  fail "Docker is not installed: there is no 'docker' command." \
       "Install Docker Desktop (macOS, Windows) or Docker Engine (Linux)."
  finish
fi
ok "docker command found"

if ! info=$(run_with_timeout 20 docker info --format '{{.ServerVersion}}|{{.Architecture}}|{{.MemTotal}}' 2>&1); then
  case "$info" in
    *"permission denied"*)
      fail "Docker is running but this user may not use it (permission denied)." \
           "Linux: add yourself to the 'docker' group (sudo usermod -aG docker \$USER), then log out and in." ;;
    *"Cannot connect"*|*"daemon is running"*|*"failed to connect"*|*"error during connect"*)
      fail "The Docker daemon is not running." "macOS: start Docker Desktop and wait for it to say it is running. Linux: sudo systemctl start docker." ;;
    "")
      fail "The Docker daemon did not answer within 20 seconds." "Docker Desktop may still be starting, or is stuck: restart it." ;;
    *)
      fail "The Docker daemon is not usable." "docker info said: $(printf '%s' "$info" | tail -1)" ;;
  esac
  finish
fi
IFS='|' read -r dver darch dmem <<EOF
$info
EOF
ok "Docker daemon $dver is running"

case "$darch" in
  x86_64|amd64|aarch64|arm64) ok "CPU architecture $darch is supported" ;;
  *) fail "CPU architecture '$darch' is not supported." \
          "The Atsign platform image is published for amd64 and arm64 only." ;;
esac

if [ "${dmem:-0}" -lt 1500000000 ] 2>/dev/null; then
  warn "Docker has only $((dmem / 1000000)) MB of memory; the demo wants about 1.5 GB."
  why "Docker Desktop: Settings > Resources > Memory."
fi

cver=$(docker compose version --short 2>/dev/null | sed 's/^v//')
if [ -z "$cver" ]; then
  fail "Docker Compose v2 ('docker compose') is not available." \
       "Docker Desktop includes it. On Linux install the docker-compose-plugin package."
  finish
fi
cmajor=${cver%%.*}; crest=${cver#*.}; cminor=${crest%%.*}
if [ "$cmajor" -lt 2 ] || { [ "$cmajor" = 2 ] && [ "$cminor" -lt 20 ]; }; then
  fail "Docker Compose $cver is too old; the demo needs 2.20 or newer." "Update Docker Desktop, or the docker-compose-plugin package on Linux."
else
  ok "Docker Compose $cver"
fi

# ---- 2. Host ports and images ------------------------------------------------
if dc config 2>/dev/null | grep -q 'published:'; then
  warn "compose.yaml publishes ports on your computer; the stock demo publishes none."
  dc config | grep -B1 -A1 'published:' | sed 's/^/        /'
else
  ok "The demo's five boxes publish no ports on your computer"
fi
ui_id=$(dc --profile ui ps -q ui 2>/dev/null)
if [ -n "$ui_id" ]; then
  ui_ports=$(docker port "$ui_id" | tr '\n' ' ')
  case "$ui_ports" in
    *0.0.0.0*|*'[::]'*) warn "The web page's box is reachable from other computers: $ui_ports" ;;
    *) ok "The web page (./demo.sh web) is served by its own box, on this computer only: $ui_ports" ;;
  esac
fi

PLATFORM_IMAGE=$(dc config --images 2>/dev/null | grep ephemeral)
if docker image inspect "$PLATFORM_IMAGE" >/dev/null 2>&1; then
  ok "Platform image present ($PLATFORM_IMAGE, created $(docker image inspect -f '{{.Created}}' "$PLATFORM_IMAGE" | cut -c1-10))"
  # The image carries a real TLS certificate for vip.ve.atsign.zone; when it
  # expires, every client refuses to connect.
  end=$(docker run --rm --entrypoint openssl "$PLATFORM_IMAGE" x509 -in /atsign/root/certs/fullchain.pem -noout -enddate 2>/dev/null | cut -d= -f2)
  if ! docker run --rm --entrypoint openssl "$PLATFORM_IMAGE" x509 -in /atsign/root/certs/fullchain.pem -noout -checkend 0 >/dev/null 2>&1; then
    fail "The platform image's TLS certificate expired on $end." \
         "Clients will refuse to connect. Run ./demo.sh while online: it pulls a newer image."
  elif ! docker run --rm --entrypoint openssl "$PLATFORM_IMAGE" x509 -in /atsign/root/certs/fullchain.pem -noout -checkend 1209600 >/dev/null 2>&1; then
    warn "The platform image's TLS certificate expires soon: $end."
    why "After that date the demo stops working. ./demo.sh pulls a newer image whenever it is online."
  else
    ok "Platform TLS certificate valid until $end"
  fi
else
  warn "Platform image not downloaded yet. ./demo.sh pulls it (needs Internet once)."
fi
missing=""
for img in $(dc config --images 2>/dev/null | grep '^noports-demo/'); do
  docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
done
if [ -n "$missing" ]; then
  warn "Not built yet:$missing. ./demo.sh builds them (needs Internet once)."
else
  have=$(built_noports_version); latest=$(latest_noports_release)
  ok "Device, client, relay and scanner images built with NoPorts $have"
  if [ -z "$latest" ]; then
    warn "Cannot reach GitHub to check for a newer NoPorts release (fine if you are offline)."
  elif [ "$NOPORTS_VERSION" = latest ] && [ "$have" != "$latest" ]; then
    warn "NoPorts $latest is out; these images have $have. ./demo.sh updates them."
  fi
fi

# ---- 3. The platform -----------------------------------------------------------
PLATFORM_UP=0
pid=$(dc ps -a -q platform 2>/dev/null)
if [ -z "$pid" ]; then
  fail "The platform container does not exist." \
       "The demo has not been started, or was torn down. Run ./demo.sh."
elif ! running platform; then
  fail "The platform container exists but is not running ($(docker inspect -f '{{.State.Status}}, exit code {{.State.ExitCode}}' "$pid"))." \
       "It was stopped, or Docker restarted. Run ./demo.sh to start it again."
else
  health=$(docker inspect -f '{{.State.Health.Status}}' "$pid")
  if [ "$health" = healthy ]; then
    ok "Platform is running and healthy"; PLATFORM_UP=1
  else
    fail "The platform is running but not healthy (health: $health)." \
         "Right after start this is normal for ~20 s, while the atDirectory loads. Otherwise, its processes:"
    dc exec -T platform supervisorctl status 2>/dev/null | sed 's/^/        /'
  fi
fi

# ---- 4. Each box: name resolution, Atsign, keys -----------------------------
check_box() {   # check_box SERVICE ATSIGN
  local svc=$1 atsign=$2 resolved pip out rc
  if ! running "$svc"; then
    local id; id=$(dc ps -a -q "$svc")
    if [ -z "$id" ]; then
      fail "$svc box: its container does not exist." "Run ./demo.sh to create it."
    else
      fail "$svc box: its container is not running ($(docker inspect -f '{{.State.Status}}, exit code {{.State.ExitCode}}' "$id"))." \
           "Exit code 137 or 143 means it was stopped from outside; anything else means its program failed." \
           "Run ./demo.sh to start it again."
      recent_errors "$svc"
    fi
    return 1
  fi
  pip=$(ip_of platform)
  resolved=$(in_box "$svc" 10 getent hosts "$ROOT_SERVER" | awk '{print $1; exit}')
  if [ -z "$resolved" ]; then
    fail "$svc box: the name $ROOT_SERVER does not resolve." \
         "Inside the demo it is a network alias of the platform container, so this means the platform is not running."
    return 1
  elif [ "$resolved" != "$pip" ]; then
    fail "$svc box: $ROOT_SERVER resolves to $resolved, not to the platform${pip:+ ($pip)}." \
         "With the platform down, Docker falls back to public DNS, which gives an address that is not this demo." \
         "Connections there would fail or hang. Start the platform: ./demo.sh"
    return 1
  fi
  ok "$svc box: $ROOT_SERVER resolves to the platform ($pip)"

  out=$(in_box "$svc" 30 at_activate status -a "$atsign" -r "$ROOT_SERVER" 2>&1); rc=$?
  case $rc in
    0) ok "$svc box: $atsign exists on the platform and is activated" ;;
    1) if in_box "$svc" 5 test -s "/home/demo/.atsign/keys/${atsign}_key.atKeys"; then
         fail "$svc box: $atsign is not activated on the platform, but this box has keys for it." \
              "The platform was recreated after the keys were made (it starts blank). Run ./demo.sh: it re-activates."
       else
         fail "$svc box: $atsign exists but has not been activated." "Run ./demo.sh: it activates the Atsigns."
       fi; return 1 ;;
    2) fail "$svc box: the atDirectory knows $atsign, but its atServer is unreachable." \
            "The atServer process inside the platform has stopped. Platform processes:"
       dc exec -T platform supervisorctl status 2>/dev/null | sed 's/^/        /'; return 1 ;;
    3) fail "$svc box: the atDirectory has no record of $atsign." \
            "Either platform/atsigns does not list $(bare "$atsign"), or the platform started under 20 s ago."; return 1 ;;
    4) fail "$svc box: cannot reach the atDirectory at $ROOT_SERVER:64." \
            "The platform's root process may have stopped, or its TLS certificate is not trusted/expired." \
            "$(printf '%s' "$out" | grep '^returning' | tail -1)"; return 1 ;;
    124) fail "$svc box: no answer from the atDirectory within 30 s." "The platform is overloaded or stuck; try ./teardown.sh then ./demo.sh."; return 1 ;;
    *) fail "$svc box: checking $atsign failed (code $rc)." "$(printf '%s' "$out" | tail -2)"; return 1 ;;
  esac

  if ! in_box "$svc" 5 test -s "/home/demo/.atsign/keys/${atsign}_key.atKeys"; then
    fail "$svc box: has no keys for $atsign." "Its keys volume was removed. Run ./demo.sh: it starts a fresh platform and re-activates."
    return 1
  fi
  if in_box "$svc" 30 at_activate list -a "$atsign" -r "$ROOT_SERVER" -k "/home/demo/.atsign/keys/${atsign}_key.atKeys" >/dev/null 2>&1; then
    ok "$svc box: its keys for $atsign sign in to the platform"
  else
    fail "$svc box: its keys for $atsign are rejected by the platform." \
         "The platform was recreated after these keys were made. Run ./demo.sh (it re-activates)."
    return 1
  fi
}

CLIENT_OK=0; DEVICE_OK=0; RELAY_OK=0
if [ "$PLATFORM_UP" = 1 ] || running client; then
  check_box client "$CLIENT_ATSIGN" && CLIENT_OK=1
else
  skip "client box checks: need the platform"
fi
if [ "$PLATFORM_UP" = 1 ]; then
  check_box device "$DEVICE_ATSIGN" && DEVICE_OK=1
  check_box relay  "$RELAY_ATSIGN"  && RELAY_OK=1
else
  skip "device and relay checks: need the platform"
fi

# ---- 5. The daemons ------------------------------------------------------------
signed_in() { wait_for_log "$1" 'monitor started' 1; }
# not_signed_in SERVICE PROGRAM ATSIGN: explain why a daemon has not signed in.
not_signed_in() {
  if ! in_box "$1" 5 pgrep -f "^$2 " >/dev/null 2>&1; then
    fail "$1: $2 is not running inside the $1 container." \
         "Something else is running as the container's command. Check: docker compose ps $1"
  else
    fail "$1: $2 is running but has not signed in to the platform as $3." \
         "It may still be starting (give it 30 s), or cannot reach its atServer. Recent warnings and errors:"
    recent_errors "$1"
  fi
}
if [ "$RELAY_OK" = 1 ]; then
  if signed_in relay; then ok "relay: srvd is running and signed in as $RELAY_ATSIGN"
  else not_signed_in relay srvd "$RELAY_ATSIGN"; RELAY_OK=0; fi
  for svc in client device; do
    running "$svc" || continue
    if [ -n "$(in_box "$svc" 10 getent hosts relay)" ]; then ok "$svc box: the name 'relay' resolves"
    else fail "$svc box: cannot resolve the name 'relay'." "srvd tells clients to dial 'relay'; the relay container is not on the network."; RELAY_OK=0; fi
  done
fi

if [ "$DEVICE_OK" = 1 ]; then
  if signed_in device; then ok "device: sshnpd is running and signed in as $DEVICE_ATSIGN"
  else not_signed_in device sshnpd "$DEVICE_ATSIGN"; DEVICE_OK=0; fi
  if in_box device 5 ss -Htln | grep -q '127.0.0.1:22 '; then ok "device: sshd is listening on 127.0.0.1:22"
  else fail "device: sshd is not listening on 127.0.0.1:22." "sshnpd hands sessions to sshd there. Restart the device: docker compose restart device"; fi
  if lst=$(dc exec -T device listeners 2>&1); then ok "device: nothing listens on a network-facing address"
  else fail "device: something listens on a network-facing address." "$lst"; fi
  if [ -z "$(docker port "$(dc ps -q device)")" ]; then ok "device: Docker publishes no ports for it"
  else fail "device: Docker publishes ports for it: $(docker port "$(dc ps -q device)" | tr '\n' ' ')" "Remove the ports: section from the device in compose.yaml."; fi
fi

# ---- 6. End to end: open a tunnel and read sshd's greeting through it --------
# This proves client -> relay -> device -> sshd carries data, without logging in.
if [ "$CLIENT_OK$DEVICE_OK$RELAY_OK" = 111 ]; then
  out=$(in_box client 60 sshnp --from "$CLIENT_ATSIGN" --to "$DEVICE_ATSIGN" --device "$DEVICE_NAME" \
        --srvd "$RELAY_ATSIGN" --root-server "$ROOT_SERVER" --remote-user-name demo -x 2>&1); rc=$?
  port=$(printf '%s\n' "$out" | sed -n 's/^ssh -p \([0-9]*\) .*/\1/p')
  if [ -n "$port" ]; then
    ok "end to end: the device daemon accepted a session request, and the relay allotted ports"
    banner=$(in_box client 15 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && head -1 <&3" 2>/dev/null | tr -d '\r')
    case "$banner" in
      SSH-*) ok "end to end: the device's sshd answered through the relay ($banner)" ;;
      *) fail "end to end: the session was set up, but no data came back through the relay." \
              "The client or device could not connect to the relay's session ports, or sshd on the device is down." ;;
    esac
  elif ! printf '%s' "$out" | grep -q 'Received host and port from srvd'; then
    fail "end to end: the relay ($RELAY_ATSIGN) did not answer the client." \
         "The relay is not signed in, or RELAY_ATSIGN in .env does not match it." \
         "$(printf '%s\n' "$out" | grep -vE '^\s*$' | tail -2)"
  else
    fail "end to end: the device daemon did not accept the session." \
         "$(printf '%s\n' "$out" | grep -E 'SHOUT|Error' | tail -2 | cut -c1-250)"
    recent_errors device
  fi
  [ "$rc" = 124 ] && why "(sshnp gave up after 60 s)"
else
  skip "end-to-end tunnel check: needs the client, device and relay checks to pass"
fi

finish
