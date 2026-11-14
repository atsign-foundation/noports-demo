#!/usr/bin/env bash
# NoPorts demo: SSH into a machine that has no open ports, and port-scan it
# before and during the session.
#
#   ./demo.sh          run the demo (safe to run again and again)
#   ./demo.sh --step   same, pausing between acts
#   ./demo.sh web      the same demo as a web page, at http://localhost:8080
#   ./demo.sh shell    open an interactive SSH shell on the device via NoPorts
#   ./doctor.sh        diagnose problems        ./teardown.sh   remove everything
. "$(dirname "$0")/scripts/lib.sh"

STEP=0; MODE=run
for a in "$@"; do
  case "$a" in
    --step) STEP=1 ;;
    shell)  MODE=shell ;;
    web)    MODE=web ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a (try --help)"; exit 64 ;;
  esac
done

# pause ["box|command|what it shows" ...]
# In step mode, stops until you press Enter. Before stopping it tells you,
# loudly, how to go and look at the boxes yourself: each argument is a command
# to run in one of them. On the web page the same commands become buttons.
pause() {
  local spec box rest command what
  if [ -n "${DEMO_EVENTS:-}" ]; then
    for spec in "$@"; do ev look "$spec"; done
    ev pause ""; read -r _; return 0
  fi
  [ "$STEP" = 1 ] && [ -t 0 ] || return 0
  if [ $# -gt 0 ]; then
    printf '\n%s  ************************  LOOK FOR YOURSELF  ************************%s\n' "$BOLD$YELLOW" "$RESET"
    say "  Don't take our word for it. Open a second terminal in this folder and run:"
    for spec in "$@"; do
      box=${spec%%|*}; rest=${spec#*|}; command=${rest%%|*}; what=${rest#*|}
      printf '\n    %sdocker compose exec %s %s%s\n      %s\n' "$BOLD" "$box" "$command" "$RESET" "$what"
    done
    printf '%s  *********************************************************************%s\n\n' "$BOLD$YELLOW" "$RESET"
  fi
  printf '%s[Enter to continue]%s' "$DIM" "$RESET"; read -r _
  return 0
}

# Any failure: say what failed, then let the doctor work out why.
die() {
  [ -n "${DEMO_EVENTS:-}" ] && ev fail "$1"
  printf '\n%sThe demo stopped: %s%s\n' "$RED$BOLD" "$1" "$RESET"
  shift; [ $# -gt 0 ] && why "$@"
  printf '\nRunning ./doctor.sh to find the cause...\n'
  ./doctor.sh --after-failure
  exit 1
}

# ---------------------------------------------------------------------------
# Setup: images, platform, Atsigns, daemons. Quiet unless something is wrong.
# ---------------------------------------------------------------------------
setup() {
  # The web page's server runs this script inside the ui box, after
  # "./demo.sh web" has already done the setup on your computer.
  if [ -n "${DEMO_NO_SETUP:-}" ]; then
    local box
    for box in platform relay device client scanner; do
      running "$box" || die "The demo's $box box is not running." "Run ./demo.sh web again on your computer."
    done
    return 0
  fi
  heading "Setting up"
  run_with_timeout 20 docker info >/dev/null 2>&1 || die "Docker is not answering."
  docker compose version >/dev/null 2>&1 || die "'docker compose' (Compose v2) is not available."

  # 1. Images. When the Internet is reachable, use the newest NoPorts release
  #    and platform image; when it is not, use whatever is already here.
  local latest want have img missing=0
  latest=$(latest_noports_release)                 # empty when offline
  want=$NOPORTS_VERSION; [ "$want" = latest ] && want=$latest
  have=$(built_noports_version)
  if [ -z "$latest" ]; then
    say "GitHub is unreachable, so not checking for updates; using the images already here."
  else
    say "Checking for a newer platform image..."
    quietly run_with_timeout 180 docker compose pull -q platform \
      || warn "Could not pull atsigncompany/ephemeral:latest; using the local copy if there is one."
  fi
  docker image inspect "$(dc config --images | grep ephemeral)" >/dev/null 2>&1 \
    || die "The platform image is not here and could not be downloaded." "The first run needs Internet access to Docker Hub."
  for img in $(dc config --images | grep '^noports-demo/'); do
    docker image inspect "$img" >/dev/null 2>&1 || missing=1
  done
  if [ -n "$want" ] && { [ "$missing" = 1 ] || [ "$have" != "$want" ]; }; then
    if [ -n "$have" ]; then say "Changing NoPorts $have -> $want (rebuilding images)..."
    else say "Building the device, client, relay and scanner images with NoPorts $want (first run, 1-3 minutes)..."; fi
    NOPORTS_VERSION=$want dc build || die "Image build failed (see the output above)." \
      "Needs Internet access to deb.debian.org and github.com."
    have=$want
  elif [ "$missing" = 1 ]; then
    die "The demo images are not built, and GitHub is unreachable to fetch NoPorts." "The first run needs Internet access."
  elif scripts_changed; then
    say "The scripts that run inside the boxes have changed; rebuilding images..."
    NOPORTS_VERSION=$have dc build || die "Image build failed (see the output above)." \
      "Needs Internet access to deb.debian.org."
  fi
  say "Using NoPorts $have."

  # 2. The platform: an atDirectory and three atServers.
  say "Starting the platform (Atsign's cloud, locally; ~20 s from cold)..."
  quietly dc up -d --wait --wait-timeout 120 platform || die "The platform did not start and become healthy within 2 minutes." "Docker said: $LAST_OUT"

  # 3. Atsigns. Each box activates its own Atsign and keeps its keys in its own
  #    Docker volume. Keys are never printed; nor is the one-time CRAM secret.
  local changed=0 reset=0 svc atsign rc errs
  errs=$(mktemp)
  while :; do
    local need_reset=0
    for svc in client device relay; do
      case $svc in client) atsign=$CLIENT_ATSIGN ;; device) atsign=$DEVICE_ATSIGN ;; relay) atsign=$RELAY_ATSIGN ;; esac
      CRAM=$(dc exec -T platform cat "/atsign/atservers/$(bare "$atsign")/CRAM") \
        || die "Could not read the activation secret for $atsign from the platform."
      CRAM="$CRAM" dc run --rm --no-deps -T -e CRAM --user demo --entrypoint ensure-activated "$svc" "$atsign" >/dev/null 2>"$errs"
      rc=$?
      case $rc in
        0)  say "  $atsign: keys already in place on the $svc box" ;;
        10) say "  $atsign: activated; keys stored on the $svc box"; changed=1 ;;
        20) need_reset=1 ;;
        *)  die "Could not activate $atsign (code $rc)." "$(cat "$errs")" ;;
      esac
    done
    [ "$need_reset" = 0 ] && { rm -f "$errs"; break; }
    [ "$reset" = 1 ] && die "Keys and platform still disagree after a platform reset."
    # Platform has the Atsigns activated but a box lost its keys (or the reverse):
    # start from a fresh platform, which forgets all activations.
    say "  Keys and platform are out of step; starting a fresh platform..."
    dc rm -sf platform relay device >/dev/null 2>&1
    quietly dc up -d --wait --wait-timeout 120 platform || die "The fresh platform did not become healthy." "Docker said: $LAST_OUT"
    reset=1
  done

  # 4. The relay and the device daemon. Restart them if their keys just changed.
  local force=""; [ "$changed" = 1 ] && force=--force-recreate
  quietly dc up -d $force relay device || die "Could not start the relay and device containers." "Docker said: $LAST_OUT"
  quietly dc up -d client scanner || die "Could not start the client and scanner containers." "Docker said: $LAST_OUT"
  say "Waiting for the relay and the device daemon to sign in to the platform..."
  wait_for_log relay  'monitor started' 60 || die "The relay (srvd) did not sign in to the platform within 60 s."
  wait_for_log device 'monitor started' 60 || die "The device daemon (sshnpd) did not sign in to the platform within 60 s."
  say "Ready."
}

# ---------------------------------------------------------------------------
# Helpers for the show
# ---------------------------------------------------------------------------
scan_device() {
  cmd "nmap -p- -T4 -n -Pn device      # all 65535 TCP ports, from the scanner box"
  local out; out=$(dc exec -T scanner nmap -p- -T4 -n -Pn device 2>&1)
  printf '%s\n' "$out" | grep -vE '^(Starting Nmap|MAC Address|$)' | sed 's/^/  /'
  if printf '%s\n' "$out" | grep -qE '^[0-9]+/tcp +open'; then
    die "The scan found an open port on the device. That should never happen here."
  fi
  printf '%s\n' "$out" | grep -q 'All 65535 scanned ports' || die "The scan did not complete." "$(printf '%s\n' "$out" | tail -3)"
  big "0 of 65535 TCP ports open on the device"
}

check_listeners() {
  cmd "ss -tuln      # inside the device: every listening TCP and UDP socket"
  dc exec -T device listeners || die "Something on the device is listening on a network-facing address."
  local published; published=$(docker port "$(dc ps -q device)")
  if [ -n "$published" ]; then die "The device container has published ports: $published"; fi
  say "  Docker publishes no ports for the device either (docker port device: empty)."
}

show_connections() {
  local names
  names="$(ip_of platform)=platform $(ip_of relay)=relay $(ip_of client)=client $(ip_of scanner)=scanner"
  cmd "ss -tn state established      # inside the device: who it is connected to"
  dc exec -T device connections "$names" "$(atserver_labels)"
}

# ---------------------------------------------------------------------------
# Opens an SSH session from the client to the device, via NoPorts.
open_session() {
  local host_key
  host_key=$(dc exec -T device cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)
  dc exec -T -e DEVICE_HOST_KEY="$host_key" client session open || die "Could not open the SSH session."
}

if [ "$MODE" = shell ]; then
  setup
  heading "Interactive shell on the device, via NoPorts"
  open_session
  say "Type 'exit' to leave. Try: ss -tuln   (only loopback listeners)"
  dc exec client session shell
  dc exec -T client session close
  exit 0
fi

setup

# ---------------------------------------------------------------------------
# ./demo.sh web: start the ui box, which serves the demo as a web page.
# It is a sixth box, on its own network. It publishes one port, on 127.0.0.1
# only, and it is given Docker's control socket so it can run this script's
# commands in the other five boxes. The device still publishes nothing.
# ---------------------------------------------------------------------------
if [ "$MODE" = web ]; then
  port=${DEMO_UI_PORT:-8080}
  if [ "${CODESPACES:-}" = true ]; then
    token=off      # a codespace's forwarded port is already private to its owner
  else
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  say "Starting the web page (first time: builds a small image)..."
  DEMO_UI_TOKEN=$token quietly dc --profile ui up -d --force-recreate ui \
    || die "Could not start the web page's box." "Docker said: $LAST_OUT" \
           "If port $port is in use, pick another: DEMO_UI_PORT=8081 ./demo.sh web"
  url="http://localhost:$port/"; [ "$token" = off ] || url="$url?t=$token"
  i=0
  until curl -fs -o /dev/null "http://127.0.0.1:$port/healthz"; do
    i=$((i + 1)); [ "$i" -gt 30 ] && die "The web page did not start within 30 s." "$(dc --profile ui logs --tail 5 ui 2>&1)"
    sleep 1
  done
  big "The demo is ready in your browser"
  say "  $url"
  say ""
  if [ "${CODESPACES:-}" = true ]; then
    say "In a codespace: open the PORTS tab and click the address next to port $port."
  else
    say "The page only answers on this computer, and only with the key in that address."
    if [ -t 1 ]; then
      if command -v open >/dev/null 2>&1; then open "$url"
      elif command -v wslview >/dev/null 2>&1; then wslview "$url"
      elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1; fi
    fi
  fi
  say "When you are done:  ./teardown.sh"
  exit 0
fi

heading "1. The boxes"
say "Five containers on one flat Docker network. No firewall, no NAT between them."
say ""
printf '  %-9s %-16s %s\n' "BOX" "IP" "ROLE"
printf '  %-9s %-16s %s\n' platform "$(ip_of platform)" "The Atsign Platform, run locally: atDirectory + one atServer per Atsign. LISTENS, as the hosted one does."
printf '  %-9s %-16s %s\n' relay    "$(ip_of relay)"    "Atsign's cloud: the socket rendezvous (srvd), $RELAY_ATSIGN. LISTENS, as the hosted ones do."
printf '  %-9s %-16s %s\n' device   "$(ip_of device)"   "${BOLD}The machine we will log in to.${RESET} sshnpd ($DEVICE_ATSIGN) + sshd on 127.0.0.1."
printf '  %-9s %-16s %s\n' client   "$(ip_of client)"   "Your laptop: sshnp ($CLIENT_ATSIGN) + OpenSSH."
printf '  %-9s %-16s %s\n' scanner  "$(ip_of scanner)"  "An attacker on the same network as the device: nmap."
say ""
say "None of them publishes a port to your computer. Everything below happens inside Docker."
pause "device|hostname|you are now inside the device: this is its name" \
      "device|ps -e -o pid,user,args|everything running on the device"

heading "2. Before connecting: what does the device expose?"
say "First, the device's own view of itself."
check_listeners
say ""
say "Now the attacker's view: scan every TCP port on the device."
scan_device
say "Closed (reset) means the device answered, \"nothing here\", for every port. It is"
say "reachable; it just has nothing to connect to. For contrast, the same scan of the"
say "platform, which is supposed to listen:"
cmd "nmap -p- -T4 -n -Pn --open platform"
dc exec -T scanner nmap -p- -T4 -n -Pn --open platform 2>&1 | grep -E '^[0-9]+/tcp' | sed 's/^/  /'
say "So the scanner works. Those ports are Atsign's side: the atDirectory (64, 443), the"
say "atServers (2500-2502), and this throwaway image's Redis and admin UI (6379, 9001)."
pause "device|ss -tuln|every listening socket on the device: loopback (127.x) only" \
      "scanner|nmap -p- -T4 -n -Pn device|scan all 65,535 of the device's ports yourself"

heading "3. Connect: SSH from the client to the device"
say "The client asks the device, through the platform, for a session. The device's daemon"
say "and the client each dial OUT to the relay, which joins the two connections."
cmd "sshnp -f $CLIENT_ATSIGN -t $DEVICE_ATSIGN -d $DEVICE_NAME -r $RELAY_ATSIGN --root-server $ROOT_SERVER -x ..."
open_session
say "  ssh: logged in (the device's SSH host key was verified, not blindly accepted)."
say ""
say "Run a command on the device, over that session:"
cmd "ssh demo@device 'hostname; whoami; uname -sm'      # over the NoPorts tunnel"
dc exec -T client session run 'echo "  hostname: $(hostname)"; echo "  user:     $(whoami)"; echo "  system:   $(uname -sm)"' \
  || die "The command over SSH failed."
say ""
say "And what the device's sshd logged about it:"
dc exec -T device grep 'Accepted publickey' /var/log/sshd.log | tail -1 | sed 's/^/  /'
say "sshd saw the login come from 127.0.0.1: from the NoPorts daemon on the same box,"
say "not from the network."
pause "device|ss -tn state established|the device's connections right now: all dialled outward" \
      "device|tail -n 3 /var/log/sshd.log|what sshd on the device logged about the login" \
      "device|ss -tuln|still nothing listening on the network"

heading "4. While connected: scan the device again"
dc exec -T client session run true >/dev/null 2>&1 || die "The SSH session dropped before the second scan."
say "The SSH session is open right now. Same scan, every TCP port:"
scan_device
say "Listening sockets on the device, during the session:"
check_listeners
say ""
say "And the device's open connections. With nothing listening on the network, every"
say "one of these was dialled outward by the device:"
show_connections
say ""
say "The relay, by contrast, is listening right now: one port per side of this session."
cmd "nmap -p- -T4 -n -Pn --open relay"
dc exec -T scanner nmap -p- -T4 -n -Pn --open relay 2>&1 | grep -E '^[0-9]+/tcp' | sed 's/^/  /'
say "It joins the two outbound connections and passes bytes it cannot read: the SSH"
say "session inside is encrypted end to end, and NoPorts adds its own encryption with a"
say "session key the relay never sees."
say ""
say "Still logged in? Run another command on the device:"
dc exec -T client session run 'echo "  $(hostname): still logged in at $(date +%T)"' \
  || die "The SSH session dropped during the scan."
# Stop here while the session is still open: this is the moment to go and look.
pause "scanner|nmap -p- -T4 -n -Pn device|you are logged in right now: scan the device again" \
      "device|ss -tuln|the device's listening sockets, during the session" \
      "device|ss -tn state established|the session's connections: every one dialled outward"
dc exec -T client session close
[ -n "${DEMO_EVENTS:-}" ] && say "The SSH session is now closed."

heading "What you just saw"
say "- You logged in to the device over SSH, and ran commands on it."
say "- Before and during that session, a full TCP scan of the device from the next box"
say "  over found nothing open. The device listens only on loopback."
say "- Every network connection the device had was one it made outward: to its atServer"
say "  on the platform, and to the relay."
say "- The platform and relay listen, as Atsign's hosted services do. They broker and"
say "  relay; they do not hold the keys to read the session."
if [ -n "${DEMO_EVENTS:-}" ]; then ev "done" ""; exit 0; fi
say ""
say "The same demo as a web page:      ./demo.sh web"
say "Interactive shell on the device:  ./demo.sh shell"
say "Check everything is healthy:      ./doctor.sh"
say "Remove containers, keys, state:   ./teardown.sh"
say "What this does NOT prove: see docs/DETAILS.md."
