#!/usr/bin/env bash
#
# THE primary test of this project (Phase 2, hard requirement (a)):
# a value-moving transition (RELEASED) endorsed by only ONE of the two
# required orgs must be REJECTED — proving the core guarantee that
# RELEASED/REFUNDED require BOTH payer-bank (Org1MSP) and settlement-org
# (Org2MSP) endorsement.
#
# This cannot be a Go unit test: unit tests call chaincode functions
# directly against a mocked stub and never go through Fabric's real
# proposal-endorsement-order-commit pipeline, so they cannot exercise
# "who endorsed this transaction" at all — that check only exists on the
# live network, enforced by VSCC against this chaincode's deploy-time
# endorsement policy (AND('Org1MSP.peer','Org2MSP.peer'), see NOTES.md /
# README for the exact policy applied at deploy).
#
# Proof strategy, robust to the exact wording of Fabric's error output:
#   1. Initiate + lock a fresh escrow (dual-org endorsed, as normal).
#   2. Record its state (must be LOCKED).
#   3. Attempt ReleaseEscrow endorsed by Org1 ONLY.
#   4. Re-read its state. PASS iff it is STILL LOCKED — i.e. the
#      single-org-endorsed release did not move the escrow to RELEASED,
#      regardless of whether step 3 itself printed an error, a non-VALID
#      commit status, or "succeeded" at the proposal-simulation level
#      (which it will — simulation has no idea who else will/won't endorse).
#
set -uo pipefail  # not -e: step 3 is EXPECTED to fail/warn; we check ledger state, not its exit code

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# common.sh does `set -euo pipefail` (it wants -e for its own callers). Sourcing
# runs in this shell, so that silently overrides the `-e`-less `set` above and
# defeats the comment's whole point: a failure in setup (InitiateEscrow/LockEscrow)
# would abort the script on the spot, with no message, before it even reaches
# step 3. Re-assert our intended options now that sourcing is done.
set +e -uo pipefail

# --- Precheck: fail loud, fail first -----------------------------------
# Without this, a down network makes the InitiateEscrow invoke below fail deep
# inside do_invoke -> ccutils.sh's chaincodeInvoke, whose retry output and final
# `fatalln` both go to *stdout* (plain `echo`, not `echo >&2` — see utils.sh),
# which is exactly the stream `do_invoke ... >/dev/null` throws away. Net result
# used to be: this script prints its header + escrow ID line, then dies in
# silence. Check reachability before printing anything test-specific.
require_network_up() {
  local missing=()
  local name
  for name in orderer.example.com lp1.org1 lp1.org2; do
    if ! docker ps --filter "name=^${name}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
      missing+=("${name}")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    c_red "Network is down — container(s) not running: ${missing[*]}"
    c_red "Run the network bootstrap first (see README.md / network/net.sh up), then re-run this test."
    exit 3
  fi
  if ! { exec 3<>"/dev/tcp/localhost/7050"; } 2>/dev/null; then
    c_red "Network is down — nothing listening on localhost:7050 (orderer)."
    c_red "Run the network bootstrap first (see README.md / network/net.sh up), then re-run this test."
    exit 3
  fi
  exec 3<&-
}
require_network_up

ESCROW_ID="test-single-org-reject-$(date +%s)"

c_blue "=== Primary test: single-org-endorsed RELEASE must be REJECTED ==="
c_blue "Escrow ID: ${ESCROW_ID}"

init_out="$(do_invoke "{\"Args\":[\"InitiateEscrow\",\"${ESCROW_ID}\",\"100000\",\"payer-acct-reject\",\"payee-acct-reject\"]}" 2>&1)"
if [ $? -ne 0 ]; then
  c_red "SETUP FAILED: InitiateEscrow invoke did not succeed:"
  printf '%s\n' "${init_out}"
  exit 2
fi

lock_out="$(do_invoke "{\"Args\":[\"LockEscrow\",\"${ESCROW_ID}\"]}" 2>&1)"
if [ $? -ne 0 ]; then
  c_red "SETUP FAILED: LockEscrow invoke did not succeed:"
  printf '%s\n' "${lock_out}"
  exit 2
fi

before="$(read_state "${ESCROW_ID}")"
c_blue "State before single-org release attempt: ${before}"
if [ "${before}" != "LOCKED" ]; then
  c_red "SETUP FAILED: expected LOCKED before the test, got '${before}'"
  exit 2
fi

c_blue "--- attempting ReleaseEscrow endorsed by Org1MSP ONLY (Org2MSP not asked) ---"
single_org_release "${ESCROW_ID}"
rc=$?
c_blue "single-org invoke exit code: ${rc} (expected non-zero or an INVALID commit status above; either way this is NOT the pass/fail signal — the ledger read below is)"
sleep 4  # past BatchTimeout, so the query below reflects the block's actual validation outcome

after="$(read_state "${ESCROW_ID}")"
c_blue "State after single-org release attempt: ${after}"

if [ "${after}" = "LOCKED" ]; then
  c_green "PASS: single-org-endorsed release was REJECTED — escrow ${ESCROW_ID} is still LOCKED, not RELEASED."
  exit 0
else
  c_red "FAIL: escrow ${ESCROW_ID} moved to '${after}' after a single-org-endorsed release — the endorsement policy was NOT enforced."
  exit 1
fi
