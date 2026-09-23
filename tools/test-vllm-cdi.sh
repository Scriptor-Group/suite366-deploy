#!/usr/bin/env bash
# =============================================================================
# Tests for the CDI spec refresh: lib/preflight.sh's refresh_cdi_spec() and the
# ExecStartPre baked into suite366-vllm.service by switch-model.sh
# (install-vllm-unit — the one template, written at install by lib/vllm.sh and
# on a running box by update.sh through `switch-model.sh converge`).
#
# This exists because of a box that came back from a reboot with every LLM call
# failing and nothing in any log naming the cause. /etc/cdi/nvidia.yaml pins the
# device-node majors, but /dev/nvidia-uvm's major is allocated dynamically at
# each boot; the spec said 497 while the kernel had moved to 498, so every
# container got a node on the wrong char device. What made it cost hours is
# where the failure does NOT show:
#   • `nvidia-smi` works on the host AND inside the container (NVML goes through
#     /dev/nvidiactl, major 195, which is fixed);
#   • the driver, the modules and /dev/nvidia* are all healthy;
#   • the only symptom is torch.cuda.init() raising "CUDA unknown error - this
#     may be due to an incorrectly set up environment", which names neither CDI
#     nor the driver — and vLLM crash-looping 63 times behind it.
# The installer had generated the spec ONCE, guarded by `if ! [[ -s … ]]`, so
# every later run walked straight past the stale file.
#
# The functions are pulled out of lib/*.sh verbatim rather than copied, so the
# test cannot drift from the shipped code.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

# A stub nvidia-ctk that writes a spec carrying whatever major it is told to,
# and records every invocation so the test can assert it actually ran.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/nvidia-ctk" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
[[ "${STUB_FAIL:-0}" == "1" ]] && exit 1
out=""
for a in "$@"; do case "$a" in --output=*) out="${a#--output=}" ;; esac; done
[[ -n "$out" ]] || exit 1
mkdir -p "$(dirname "$out")"
printf 'cdiVersion: 0.5.0\ndevices:\n  - path: /dev/nvidia-uvm\n    major: %s\n' \
  "${STUB_MAJOR:-498}" > "$out"
STUB
chmod +x "$WORK/bin/nvidia-ctk"

# Run refresh_cdi_spec extracted verbatim from the shipped preflight module.
run_refresh() { # run_refresh SPEC_PATH
  CALLS="$WORK/calls" CDI_SPEC="$1" PATH="$WORK/bin:$PATH" \
  STUB_MAJOR="${STUB_MAJOR:-498}" STUB_FAIL="${STUB_FAIL:-0}" \
  bash -c '
    set -uo pipefail
    info() { printf "    %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    eval "$(sed -n "/^refresh_cdi_spec() {/,/^}/p" "$1")"
    refresh_cdi_spec
  ' _ "$REPO/lib/preflight.sh" 2>&1
}

echo "== the spec is rewritten on every run, not only when it is missing =="

spec="$WORK/cdi/nvidia.yaml"
: > "$WORK/calls"
run_refresh "$spec" >/dev/null
[[ -s "$spec" ]] && ok "a missing spec is generated" \
  || ko "a missing spec is generated"

# The regression. The old code was `if ! [[ -s /etc/cdi/nvidia.yaml ]]`, so a
# spec left over from an earlier boot — non-empty, perfectly valid-looking, and
# wrong — was never touched again.
: > "$WORK/calls"
printf 'cdiVersion: 0.5.0\ndevices:\n  - path: /dev/nvidia-uvm\n    major: 497\n' > "$spec"
run_refresh "$spec" >/dev/null
if grep -q 'major: 498' "$spec"; then
  ok "a stale spec from an earlier boot is rewritten with the current major"
else
  ko "a stale spec from an earlier boot is rewritten with the current major" \
     "still: $(grep -o 'major: [0-9]*' "$spec" | head -1)"
fi
[[ -s "$WORK/calls" ]] && ok "the generator is invoked even though a spec already existed" \
  || ko "the generator is invoked even though a spec already existed"

grep -q -- "--output=$spec" "$WORK/calls" \
  && ok "it writes the path the rest of the installer reads (CDI_SPEC)" \
  || ko "it writes the path the rest of the installer reads (CDI_SPEC)" "$(cat "$WORK/calls")"

echo "== a generator that fails warns, it does not abort the install =="
: > "$WORK/calls"
out="$(STUB_FAIL=1 run_refresh "$spec")"; rc=$?
[[ $rc -eq 0 ]] && ok "refresh_cdi_spec returns 0 when nvidia-ctk fails" \
  || ko "refresh_cdi_spec returns 0 when nvidia-ctk fails" "rc=$rc"
grep -q "may not resolve after reboot" <<<"$out" \
  && ok "and says so rather than failing silently" \
  || ko "and says so rather than failing silently" "$out"

echo "== the unit refreshes the spec before the containers are created =="
# Devices are injected at container CREATION, so a refresh that runs after
# `docker compose up` would be a no-op for the containers that matter. Pull the
# unit heredoc straight out of switch-model.sh (install_vllm_unit), the one
# template every writer uses.
unit="$(sed -n '/cat > "\$SYSTEMD_DIR\/suite366-vllm.service" <<EOF/,/^EOF$/p' \
        "$REPO/switch-model.sh")"
[[ -n "$unit" ]] || { ko "the suite366-vllm.service heredoc is still where the test looks"; unit=""; }
# lib/vllm.sh must not keep a second copy: two templates drift, and the one the
# updater rewrites would silently differ from the one the installer wrote.
grep -q 'suite366-vllm.service <<EOF' "$REPO/lib/vllm.sh" \
  && ko "lib/vllm.sh still carries its own copy of the unit (one template only)" \
  || ok "lib/vllm.sh writes the unit through switch-model.sh install-vllm-unit"
grep -q 'switch-model.sh" install-vllm-unit' "$REPO/lib/vllm.sh" \
  && ok "  and calls it" || ko "  and calls it"

grep -q '^ExecStartPre=.*nvidia-ctk cdi generate' <<<"$unit" \
  && ok "the unit carries a CDI refresh as ExecStartPre" \
  || ko "the unit carries a CDI refresh as ExecStartPre" "$unit"

# Leading '-': a generator that fails must not hold the whole LLM stack down
# when the spec on disk is already correct.
grep -q '^ExecStartPre=-' <<<"$unit" \
  && ok "the refresh is best-effort, it cannot block the stack" \
  || ko "the refresh is best-effort, it cannot block the stack" "$unit"

# The unit writes $cdi_spec, which install_vllm_unit sets from the same
# CDI_SPEC the preflight refresh reads — lib/vllm.sh passes it through, and a
# box converged by update.sh gets the installer's default.
grep -q 'ExecStartPre=.*--output=\$cdi_spec' <<<"$unit" \
  && grep -q 'cdi_spec="\${CDI_SPEC:-/etc/cdi/nvidia.yaml}"' "$REPO/switch-model.sh" \
  && grep -q 'CDI_SPEC="\${CDI_SPEC:-/etc/cdi/nvidia.yaml}"' "$REPO/lib/config.sh" \
  && grep -q 'CDI_SPEC="\$CDI_SPEC" "\$DATA_DIR/switch-model.sh" install-vllm-unit' "$REPO/lib/vllm.sh" \
  && ok "the unit and the preflight refresh target the same file" \
  || ko "the unit and the preflight refresh target the same file" "$unit"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
