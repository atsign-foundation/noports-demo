# shellcheck shell=bash
# Shared helpers for demo.sh, doctor.sh and teardown.sh. Sourced, not run.
# Written for bash 3.2 (macOS's default) and BSD or GNU userland.

cd "$(dirname "$0")" || exit 1
# Settings come from .env; NOPORTS_VERSION set in your shell wins, as it does for Compose.
_np_override=${NOPORTS_VERSION:-}
# shellcheck source=/dev/null
. ./.env
NOPORTS_VERSION=${_np_override:-$NOPORTS_VERSION}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=; DIM=; RED=; GREEN=; YELLOW=; CYAN=; RESET=
fi

dc() { docker compose "$@"; }

# Narration and status lines.
say()     { printf '%s\n' "$@"; }
heading() { printf '\n%s== %s ==%s\n' "$BOLD$CYAN" "$1" "$RESET"; }
cmd()     { printf '%s$ %s%s\n' "$DIM" "$*" "$RESET"; }          # show a command before running it
ok()      { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
bad()     { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; }
warn()    { printf '  %sWARN%s  %s\n' "$YELLOW" "$RESET" "$1"; }
skip()    { printf '  %sSKIP%s  %s\n' "$DIM" "$RESET" "$1"; }
why()     { printf '        %s\n' "$@"; }                         # indented detail under PASS/FAIL
big()     { printf '\n  %s>>> %s <<<%s\n\n' "$BOLD$GREEN" "$1" "$RESET"; }

# run_with_timeout SECONDS command... (macOS has no timeout(1))
run_with_timeout() {
  local secs=$1; shift
  "$@" </dev/null &
  local pid=$!
  # The watcher must not hold our stdout open, or $(run_with_timeout ...) waits for it.
  ( sleep "$secs" & s=$!; trap 'kill $s; exit 0' TERM; wait $s; kill -TERM "$pid" ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid"; local rc=$?
  kill "$watcher" 2>/dev/null
  return $rc
}

# quietly CMD...: run CMD silently; on failure leave its last lines in $LAST_OUT.
quietly() {
  local out; out=$("$@" 2>&1) && return 0
  # shellcheck disable=SC2034  # read by the scripts that source this file
  LAST_OUT=$(printf '%s\n' "$out" | grep -v '^\s*$' | tail -4); return 1
}

# Container IP on the demo network, or empty.
ip_of() {
  local id; id=$(dc ps -q "$1" 2>/dev/null)
  [ -n "$id" ] && docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id"
}

running() { [ -n "$(dc ps -q --status running "$1" 2>/dev/null)" ]; }

# wait_for_log SERVICE PATTERN SECONDS: waits for PATTERN in the logs of the
# service's current run. Fails early if the container stops.
wait_for_log() {
  local id since i
  id=$(dc ps -q "$1") || return 1
  since=$(docker inspect -f '{{.State.StartedAt}}' "$id")
  i=0
  while [ "$i" -lt "$3" ]; do
    docker logs --since "$since" "$id" 2>&1 | grep -q "$2" && return 0
    running "$1" || return 1
    sleep 1; i=$((i + 1))
  done
  return 1
}

# The newest NoPorts release tag (e.g. v5.18.2), or empty if GitHub is unreachable.
# Read from where GitHub's "latest release" link redirects to.
latest_noports_release() {
  curl -fsSI --max-time 8 https://github.com/atsign-foundation/noports/releases/latest 2>/dev/null \
    | sed -n 's|^[Ll]ocation: .*/tag/\([^[:space:]]*\).*|\1|p'
}

# The NoPorts release inside the built images, or empty if they are not built.
built_noports_version() {
  docker run --rm --entrypoint cat noports-demo/client /etc/noports-version 2>/dev/null
}

# Strip '@' to get the platform's internal name for an atSign.
bare() { printf '%s' "${1#@}"; }

# The atServer port of each atSign: the platform gives FIRST_PORT (2500) to
# the first name in platform/atsigns, 2501 to the second, and so on.
# Output: "2500=atServer~of~@x ..." (~ stands for a space).
atserver_labels() {
  local p=2500 n out=""
  while read -r n; do
    [ -n "$n" ] && out="$out $p=atServer~of~@${n}" && p=$((p + 1))
  done < platform/atsigns
  printf '%s' "$out"
}
