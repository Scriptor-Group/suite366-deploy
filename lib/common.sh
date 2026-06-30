# shellcheck shell=bash
# =============================================================================
# lib/common.sh — shared runtime helpers used across modules.
# The most basic helpers (colors, log/info/warn/die, have, fetch) live in
# install.sh because the bootstrap loader needs them before this is sourced.
# =============================================================================

tty_usable() { (exec </dev/tty) >/dev/null 2>&1; }   # /dev/tty exists AND is openable

# Runs a long command in the background and prints the namespace's pod state
# every ~15s, so we don't stare at nothing during `helm --wait`.
run_progress() { # run_progress "label" cmd...
  local label="$1"; shift
  ( "$@" ) & local pid=$! rc=0 n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; n=$((n+15))
    local summary
    summary="$(k3s kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null \
      | awk '{c[$3]++} END{for(s in c) printf "%s:%d ", s, c[s]}')"
    info "$label … ${n}s elapsed${summary:+ — pods: $summary}"
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# Interactive read from the terminal (stdin = pipe when curl|bash).
ask() { # ask VAR "prompt" "default"
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi          # already supplied via env
  if [[ "$ASSUME_YES" == "1" ]] || ! tty_usable; then printf -v "$__var" '%s' "$__def"; return 0; fi
  read -r -p "$__prompt${__def:+ [$__def]}: " __ans </dev/tty || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
ask_secret() { # ask_secret VAR "prompt"
  local __var="$1" __prompt="$2" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  if [[ "$ASSUME_YES" == "1" ]] || ! tty_usable; then return 0; fi
  read -r -s -p "$__prompt: " __ans </dev/tty || true; echo
  printf -v "$__var" '%s' "$__ans"
}

wait_http() { # wait_http URL LABEL  (timeout ~30 min: HF DL 15+ GiB + recovery)
  # 30 min covers: HuggingFace DL (5-10 min/model), Inductor compile +
  # cudagraph capture (3-6 min), and 1-2 restart cycles if the first attempt
  # fails (e.g. transient OOM on GB10's unified memory). Non-blocking: on
  # timeout we continue with just a `warn`.
  local url="$1" label="$2" i=0
  printf "    %s: waiting" "$label"
  while (( i < 360 )); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then printf " OK\n"; return 0; fi
    printf "."; sleep 5; ((i++))
  done
  printf " timeout\n"; return 1
}

kc()   { k3s kubectl "$@"; }
