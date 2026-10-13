#!/usr/bin/env bash
# =============================================================================
# Self-test: powering the box off / rebooting it from the app (update.sh power).
#
# What is guarded, and why:
#
#  • THE UNITS. `install-units` must arm one .path per verb on the trigger
#    file the app drops (shutdown-requested, reboot-requested), each running
#    `update.sh power <verb>`, plus the boot-time one-shot that closes the
#    request — and it must leave power.json behind: its presence is how the
#    app knows this host takes power requests (an older updater never wrote
#    one, and the app must not offer a button nothing would honour).
#  • THE REQUEST. The trigger is consumed BEFORE the machine goes down (a
#    request that fails must not replay at the next boot through the .path
#    unit), who asked is recorded in power.json and in the root-only pending
#    file, and systemctl is called with --no-block so the one-shot returns.
#  • THE RETURN. `power booted` closes the pending request with the time the
#    box was back, keeps the record of the last request on a boot that had
#    none pending (a power cut, a manual reboot), and only seeds an idle
#    power.json where there is none.
#
# No systemd: systemctl and logger are stubbed, the functions under test are
# EXTRACTED from update.sh, never copied.
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
mkdir -p "$WORK/bin" "$WORK/data" "$WORK/systemd"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "$WORK/systemctl.log"\nexit 0\n' > "$WORK/bin/systemctl"
printf '#!/usr/bin/env bash\nprintf "logger %%s\\n" "$*" >> "$WORK/logger.log"\nexit 0\n' > "$WORK/bin/logger"
# install_units also publishes host.json (tools/test-host-facts.sh covers it): a bare `ip`.
printf '#!/usr/bin/env bash\ncase "$*" in "-j addr show") echo "[]" ;; esac\nexit 0\n' > "$WORK/bin/ip"
printf '#!/usr/bin/env bash\necho box\n' > "$WORK/bin/hostname"
chmod +x "$WORK/bin/systemctl" "$WORK/bin/logger" "$WORK/bin/ip" "$WORK/bin/hostname"

# --- harness -----------------------------------------------------------------
{
  cat <<'H'
c_g=""; c_b=""; c_y=""; c_r=""; c_0=""
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
H
  printf 'DATA_DIR=%s\nSYSTEMD_DIR=%s\nNM_DISPATCHER_DIR=%s\n' "$WORK/data" "$WORK/systemd" "$WORK/nm"
  # The paths and the helpers, as update.sh defines them.
  sed -n '/^UPDATES_DIR=/p; /^STATE_JSON=/p; /^APPLY_JSON=/p; /^POWER_JSON=/p; /^PRIVATE_DIR=/p; /^POWER_PENDING=/p; /^POWER_PENDING_LEGACY=/p; /^HOST_JSON=/p; /^APP_GID=/p; /^TRIGGER_WHO=/p' "$REPO/update.sh"
  sed -n '/^now_utc() {/,/}$/p' "$REPO/update.sh"
  for f in json_esc ensure_updates_dir private_tmp publish_file trigger_ok consume_trigger write_power_json do_power host_lan_interfaces write_host_json install_units; do
    sed -n "/^$f() {/,/^}/p" "$REPO/update.sh"
  done
  # chown to a gid this user may not have: the self-test runs unprivileged —
  # and the test user plays the pod (the uid a trigger must be owned by).
  cat <<'H'
chown() { :; }
APP_GID="$(id -u)"
H
} > "$WORK/prelude.sh"

run() { # run CODE -> output ; RC = exit status
  local out rc
  # shellcheck disable=SC2097,SC2098
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" \
           bash -c "set -euo pipefail; . '$WORK/prelude.sh'; $1" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
reset_box() { rm -rf "$WORK/data" "$WORK/systemd" "$WORK/systemctl.log" "$WORK/logger.log"; mkdir -p "$WORK/data" "$WORK/systemd"; }
jq_() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$WORK/data/updates/power.json" "$1" 2>/dev/null; }

echo "== install-units =="
reset_box
out="$(run "install_units")"; RC=$?
check "install-units exits 0" "$RC" "0"
for u in suite366-update-apply.service suite366-update-apply.path suite366-update-check.path \
         suite366-power-shutdown.service suite366-power-shutdown.path \
         suite366-power-reboot.service suite366-power-reboot.path suite366-power-booted.service; do
  if [[ -f "$WORK/systemd/$u" ]]; then ok "writes $u"; else ko "writes $u"; fi
done
contains "the reboot .path watches the app's trigger" "$(cat "$WORK/systemd/suite366-power-reboot.path")" "PathExists=$WORK/data/updates/reboot-requested"
contains "the shutdown .path watches the app's trigger" "$(cat "$WORK/systemd/suite366-power-shutdown.path")" "PathExists=$WORK/data/updates/shutdown-requested"
contains "the reboot service runs update.sh power reboot" "$(cat "$WORK/systemd/suite366-power-reboot.service")" "ExecStart=$WORK/data/update.sh power reboot"
contains "the shutdown service runs update.sh power shutdown" "$(cat "$WORK/systemd/suite366-power-shutdown.service")" "ExecStart=$WORK/data/update.sh power shutdown"
# A trigger left behind by a service that could not consume it (older updater,
# crash before do_power) re-fires the .path unit until the start limit trips
# and the .path unit itself goes failed — seen on the test Spark. The unit
# removes it on the way out, whatever happened.
contains "the reboot service drops an unconsumed trigger on exit" "$(cat "$WORK/systemd/suite366-power-reboot.service")" "ExecStopPost=-/bin/rm -f $WORK/data/updates/reboot-requested"
contains "the shutdown service too" "$(cat "$WORK/systemd/suite366-power-shutdown.service")" "ExecStopPost=-/bin/rm -f $WORK/data/updates/shutdown-requested"
contains "the booted unit runs at every boot" "$(cat "$WORK/systemd/suite366-power-booted.service")" "WantedBy=multi-user.target"
contains "the booted unit runs update.sh power booted" "$(cat "$WORK/systemd/suite366-power-booted.service")" "ExecStart=$WORK/data/update.sh power booted"
contains "the five units are enabled together" "$(cat "$WORK/systemctl.log")" "enable --now suite366-update-apply.path suite366-update-check.path suite366-power-shutdown.path suite366-power-reboot.path suite366-power-booted.service"
check "power.json is seeded idle (the app's cue that power requests are honoured)" "$(jq_ 'd["status"]')" "idle"
check "…with no request on record" "$(jq_ 'd["last"]')" "None"
contains "…and the operator is told" "$out" "power requests included"

echo "== power reboot, requested from the app =="
reset_box; run "ensure_updates_dir" >/dev/null
printf 'ops@acme.example\n' > "$WORK/data/updates/reboot-requested"
out="$(run "do_power reboot")"; RC=$?
check "exits 0" "$RC" "0"
if [[ -e "$WORK/data/updates/reboot-requested" ]]; then ko "the trigger is consumed before the machine goes down"; else ok "the trigger is consumed before the machine goes down"; fi
check "systemctl reboot, without blocking the one-shot" "$(cat "$WORK/systemctl.log")" "systemctl --no-block reboot"
check "power.json says rebooting" "$(jq_ 'd["status"]')" "rebooting"
check "…who asked" "$(jq_ 'd["last"]["requested_by"]')" "ops@acme.example"
check "…what" "$(jq_ 'd["last"]["action"]')" "reboot"
check "…and not back yet" "$(jq_ 'd["last"]["completed_at"]')" ""
if [[ -n "$(jq_ 'd["last"]["requested_at"]')" ]]; then ok "…requested_at is set"; else ko "…requested_at is set"; fi
check "the pending file is root-only" "$(stat -c %a "$WORK/data/.private/power-pending")" "600"
if [[ -e "$WORK/data/updates/power-pending" ]]; then ko "…and OUT of the directory the pod can write"; else ok "…and OUT of the directory the pod can write"; fi
check "…and names the request" "$(sed -n 1,2p "$WORK/data/.private/power-pending" | tr '\n' '|')" "reboot|ops@acme.example|"
contains "the host journal names the requester" "$(cat "$WORK/logger.log")" "power: reboot (by: ops@acme.example)"
contains "the operator sees it" "$out" "Power: reboot requested by ops@acme.example"

echo "== power booted, after that reboot =="
out="$(run "do_power booted")"; RC=$?
check "exits 0" "$RC" "0"
check "power.json is idle again" "$(jq_ 'd["status"]')" "idle"
check "…keeps who asked" "$(jq_ 'd["last"]["requested_by"]')" "ops@acme.example"
check "…and what" "$(jq_ 'd["last"]["action"]')" "reboot"
if [[ -n "$(jq_ 'd["last"]["completed_at"]')" ]]; then ok "…and records when the box was back"; else ko "…and records when the box was back"; fi
if [[ -e "$WORK/data/.private/power-pending" ]]; then ko "the pending file is gone"; else ok "the pending file is gone"; fi
contains "the host journal says so" "$(cat "$WORK/logger.log")" "power: back after reboot (by: ops@acme.example)"
# A boot with nothing pending (power cut, manual reboot): the record stays.
before="$(cat "$WORK/data/updates/power.json")"
out="$(run "do_power booted")"; RC=$?
check "a boot with nothing pending leaves power.json alone" "$(cat "$WORK/data/updates/power.json")" "$before"

echo "== power shutdown, by hand (no trigger) =="
reset_box; run "ensure_updates_dir" >/dev/null
out="$(run "do_power shutdown")"; RC=$?
check "exits 0" "$RC" "0"
check "systemctl poweroff" "$(cat "$WORK/systemctl.log")" "systemctl --no-block poweroff"
check "power.json says shutting_down" "$(jq_ 'd["status"]')" "shutting_down"
check "…with no requester (the operator at the console)" "$(jq_ 'd["last"]["requested_by"]')" ""
contains "the operator sees it" "$out" "Power: shutdown requested by the operator"

echo "== refusals =="
reset_box; run "ensure_updates_dir" >/dev/null
out="$(run "do_power halt")"; RC=$?
check "an unknown verb is refused" "$RC" "1"
contains "…and named" "$out" "unknown action 'halt'"
if [[ -f "$WORK/systemctl.log" ]]; then ko "…and nothing is called"; else ok "…and nothing is called"; fi
out="$(run "do_power ''")"; RC=$?
check "an empty verb is refused" "$RC" "1"

echo "== the shared directory is pod-writable: what root reads and writes there =="
# A symlink dropped as a trigger: root must not read through it (the first 200
# bytes used to land in power.json, world-readable), and the .path unit must
# not re-fire on it for ever — it is removed.
reset_box; run "ensure_updates_dir" >/dev/null
printf 'root:x:0:0\n' > "$WORK/secret"; ln -s "$WORK/secret" "$WORK/data/updates/reboot-requested"
out="$(run "do_power reboot")"; RC=$?
check "a symlinked trigger exits 0 (the reboot still happens, as an operator request)" "$RC" "0"
if [[ -e "$WORK/data/updates/reboot-requested" || -L "$WORK/data/updates/reboot-requested" ]]; then ko "the symlink is removed"; else ok "the symlink is removed"; fi
contains "…and refused by name" "$out" "not a regular file"
absent "…nothing read through it lands in power.json" "$(cat "$WORK/data/updates/power.json")" "root:x:0:0"
# A trigger owned by someone else (not the pod, not root) is refused too: here
# the pod's uid is pretended to be another one, so the test user's file is "someone else's".
reset_box; run "ensure_updates_dir" >/dev/null
printf 'x\n' > "$WORK/data/updates/reboot-requested"
out="$(run "APP_GID=65534; trigger_ok '$WORK/data/updates/reboot-requested' && echo accepted")"; RC=$?
check "a trigger owned by neither the pod nor root is refused" "$RC" "1"
contains "…and says so" "$out" "refused (owner uid"
if [[ -e "$WORK/data/updates/reboot-requested" ]]; then ko "…and removed"; else ok "…and removed"; fi
# A large file is refused as well (a trigger is a couple of lines).
reset_box; run "ensure_updates_dir" >/dev/null
head -c 70000 /dev/zero | tr '\0' 'a' > "$WORK/data/updates/reboot-requested"
out="$(run "trigger_ok '$WORK/data/updates/reboot-requested' && echo accepted")"; RC=$?
check "an oversized trigger is refused" "$RC" "1"
# Every file root publishes is produced in the private dir and RENAMED into
# place: a symlink the pod planted under the destination's old temp name must
# not be followed, and the canary it points at must survive intact.
reset_box; run "ensure_updates_dir" >/dev/null
printf 'canary\n' > "$WORK/canary"
for n in power.json state.json apply.json host.json; do ln -s "$WORK/canary" "$WORK/data/updates/$n.tmp"; done
ln -s "$WORK/canary" "$WORK/data/updates/power.json"
out="$(run "write_power_json idle; write_host_json")"; RC=$?
check "writes exit 0 with planted symlinks" "$RC" "0"
check "the canary is untouched" "$(cat "$WORK/canary")" "canary"
if [[ -L "$WORK/data/updates/power.json" ]]; then ko "the published file replaced the planted symlink"; else ok "the published file replaced the planted symlink"; fi
check "…and is a regular 0644 file" "$(stat -c '%F %a' "$WORK/data/updates/power.json")" "regular file 644"
check "the private working dir is root-only" "$(stat -c %a "$WORK/data/.private")" "700"
check "nothing root-owned but the published files is left in the shared dir" "$(find "$WORK/data/updates" -mindepth 1 ! -name '*.json' ! -name '*.tmp' -printf '%f ' 2>/dev/null)" ""
# A box that rebooted on the previous updater: its record was in the shared dir.
reset_box; run "ensure_updates_dir" >/dev/null
printf 'reboot\nold@acme.example\n2026-10-12T15:00:00Z\n' > "$WORK/data/updates/power-pending"
out="$(run "do_power booted")"; RC=$?
check "a legacy pending record is honoured once" "$(jq_ 'd["last"]["requested_by"]')" "old@acme.example"
if [[ -e "$WORK/data/updates/power-pending" ]]; then ko "…and removed from the shared dir"; else ok "…and removed from the shared dir"; fi

echo "== booted on a fresh box =="
reset_box
out="$(run "do_power booted")"; RC=$?
check "exits 0" "$RC" "0"
check "seeds an idle power.json" "$(jq_ 'd["status"]')" "idle"
check "…with no request on record" "$(jq_ 'd["last"]')" "None"
check "…readable by the pod (0644)" "$(stat -c %a "$WORK/data/updates/power.json")" "644"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
