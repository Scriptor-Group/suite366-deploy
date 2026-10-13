#!/usr/bin/env bash
# =============================================================================
# Self-test: host.json, the box's hostname and LAN addresses for the app.
#
# What is guarded, and why:
#  • WHICH interfaces: the plumbing (suite0, docker, cni, flannel, veth,
#    tailscale, WireGuard) never shows up; the default-route interface comes
#    first; an interface with no global address is dropped.
#  • OFFLINE: with no default route every LAN interface is still listed, so
#    a box someone plugged a laptop into still says where it is.
#  • THE FILE: valid JSON, 0644 (the pod reads it), written via tmp+rename,
#    the internal IP (suite0) listed apart; install-units writes it and arms
#    the boot unit and the NetworkManager hook.
# `ip` and `hostname` are stubbed; the functions are EXTRACTED from update.sh.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ORIG_PATH="$PATH"
c_g="\033[32m"; c_r="\033[31m"; c_0="\033[0m"
pass=0; fail=0
ok() { printf "  ${c_g}PASS${c_0} %s\n" "$1"; pass=$((pass + 1)); }
ko() { printf "  ${c_r}FAIL${c_0} %s\n" "$1"; fail=$((fail + 1)); }
check()    { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (expected '$3', got '$2')"; fi; }
contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else ko "$1 (missing: $3)"; fi; }
absent()   { if grep -qF -- "$3" <<<"$2"; then ko "$1 (present: $3)"; else ok "$1"; fi; }

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/data" "$WORK/systemd" "$WORK/nm"
# A GB10 as seen on 2026-10-13: LAN on enP7s7 (v4 + two global v6), Wi-Fi down,
# the dummy suite0, docker, flannel, cni, a WireGuard peer, tailscale.
cat > "$WORK/ip.json" <<'J'
[{"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","scope":"host"}]},
 {"ifname":"enP7s7","addr_info":[{"family":"inet","local":"192.168.1.72","scope":"global"},{"family":"inet6","local":"2a01:cb19:9557:ca00:21d:bc07:bcc8:5a41","scope":"global"},{"family":"inet6","local":"fe80::15a6:20d9:d3d9:f585","scope":"link"}]},
 {"ifname":"wlP9s9","addr_info":[]},
 {"ifname":"eth1","addr_info":[{"family":"inet","local":"10.0.0.5","scope":"global"}]},
 {"ifname":"suite0","addr_info":[{"family":"inet","local":"10.99.0.1","scope":"global"}]},
 {"ifname":"scriptor","addr_info":[{"family":"inet","local":"172.16.100.11","scope":"global"}]},
 {"ifname":"docker0","addr_info":[{"family":"inet","local":"172.17.0.1","scope":"global"}]},
 {"ifname":"cni0","addr_info":[{"family":"inet","local":"10.42.0.1","scope":"global"}]},
 {"ifname":"flannel.1","addr_info":[{"family":"inet","local":"10.42.0.0","scope":"global"}]},
 {"ifname":"tailscale0","addr_info":[{"family":"inet","local":"100.64.0.8","scope":"global"}]},
 {"ifname":"br-88496da820c8","addr_info":[{"family":"inet","local":"172.18.0.1","scope":"global"}]}]
J
cat > "$WORK/bin/ip" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  "-j addr show") cat "$WORK/ip.json" ;;
  "route get 1.1.1.1") [[ -f "$WORK/offline" ]] || echo "1.1.1.1 via 192.168.1.1 dev enP7s7 src 192.168.1.72 uid 0" ;;
  "-4 addr show dev suite0") echo "    inet 10.99.0.1/32 scope global suite0" ;;
  *) exit 0 ;;
esac
EOF2
printf '#!/usr/bin/env bash\necho promaxgb10-test\n' > "$WORK/bin/hostname"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "$WORK/systemctl.log"\nexit 0\n' > "$WORK/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/"*

{
  cat <<'H'
c_g=""; c_b=""; c_y=""; c_r=""; c_0=""
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
chown() { :; }
APP_GID="$(id -u)"
H
  printf 'DATA_DIR=%s\nSYSTEMD_DIR=%s\nNM_DISPATCHER_DIR=%s\n' "$WORK/data" "$WORK/systemd" "$WORK/nm"
  sed -n '/^UPDATES_DIR=/p; /^STATE_JSON=/p; /^APPLY_JSON=/p; /^POWER_JSON=/p; /^PRIVATE_DIR=/p; /^POWER_PENDING=/p; /^POWER_PENDING_LEGACY=/p; /^HOST_JSON=/p; /^APP_GID=/p; /^TRIGGER_WHO=/p' "$REPO/update.sh"
  sed -n '/^now_utc() {/,/}$/p' "$REPO/update.sh"
  for f in json_esc ensure_updates_dir private_tmp published_ok publish_file write_power_json host_lan_interfaces write_host_json do_host_facts install_units; do
    sed -n "/^$f() {/,/^}/p" "$REPO/update.sh"
  done
} > "$WORK/prelude.sh"
run() { # run CODE -> output ; RC = exit status
  local out rc
  # shellcheck disable=SC2097,SC2098
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" bash -c "set -euo pipefail; . '$WORK/prelude.sh'; $1" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
jq_() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$WORK/data/updates/host.json" "$1" 2>/dev/null; }

echo "== host-facts, online =="
out="$(run "do_host_facts")"; RC=$?
check "exits 0" "$RC" "0"
if python3 -m json.tool "$WORK/data/updates/host.json" >/dev/null 2>&1; then ok "host.json is valid JSON"; else ko "host.json is valid JSON"; fi
check "readable by the pod (0644)" "$(stat -c %a "$WORK/data/updates/host.json")" "644"
check "hostname" "$(jq_ 'd["hostname"]')" "promaxgb10-test"
check "the default-route interface comes first" "$(jq_ 'd["interfaces"][0]["name"]')" "enP7s7"
check "…with its IPv4" "$(jq_ 'd["interfaces"][0]["ipv4"]')" "['192.168.1.72']"
check "…and only its GLOBAL IPv6 (no link-local)" "$(jq_ 'd["interfaces"][0]["ipv6"]')" "['2a01:cb19:9557:ca00:21d:bc07:bcc8:5a41']"
check "a second LAN interface follows" "$(jq_ '[i["name"] for i in d["interfaces"]]')" "['enP7s7', 'eth1']"
check "the internal IP is listed apart" "$(jq_ 'd["internal_ip"]')" "10.99.0.1"
absent "no plumbing interface (suite0, docker, cni, flannel, tailscale, WireGuard, bridge)" "$(jq_ '[i["name"] for i in d["interfaces"]]')" "suite0"
absent "…tailscale" "$(cat "$WORK/data/updates/host.json")" "100.64"
absent "…WireGuard peer" "$(cat "$WORK/data/updates/host.json")" "172.16.100"
absent "…docker/cni" "$(cat "$WORK/data/updates/host.json")" "172.17"
absent "an interface without address is dropped (Wi-Fi down)" "$(cat "$WORK/data/updates/host.json")" "wlP9s9"
contains "the operator sees the addresses" "$out" "host facts published (192.168.1.72, 10.0.0.5)"
if [[ -n "$(jq_ 'd["updated_at"]')" ]]; then ok "updated_at set"; else ko "updated_at set"; fi

echo "== host-facts, offline (no default route) =="
touch "$WORK/offline"
out="$(run "do_host_facts")"; RC=$?
check "exits 0" "$RC" "0"
check "every LAN interface is still listed" "$(jq_ 'sorted(i["name"] for i in d["interfaces"])')" "['enP7s7', 'eth1']"
rm -f "$WORK/offline"

echo "== install-units arms the boot unit and the NetworkManager hook =="
rm -rf "$WORK/data/updates"; mkdir -p "$WORK/data"
out="$(run "install_units")"; RC=$?
check "exits 0" "$RC" "0"
contains "boot unit written" "$(cat "$WORK/systemd/suite366-host-facts.service" 2>/dev/null)" "ExecStart=$WORK/data/update.sh host-facts"
contains "…after the network is up" "$(cat "$WORK/systemd/suite366-host-facts.service" 2>/dev/null)" "After=network-online.target"
contains "…enabled with the others" "$(cat "$WORK/systemctl.log")" "suite366-host-facts.service"
contains "NetworkManager hook written" "$(cat "$WORK/nm/90-suite366-host-facts" 2>/dev/null)" "dhcp4-change"
check "…executable" "$(stat -c %a "$WORK/nm/90-suite366-host-facts")" "755"
check "host.json written right away" "$(jq_ 'd["interfaces"][0]["ipv4"]')" "['192.168.1.72']"
# No NetworkManager on the box: no hook, no failure.
rm -rf "$WORK/nm"
out="$(run "install_units")"; RC=$?
check "without NetworkManager install-units still exits 0" "$RC" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
