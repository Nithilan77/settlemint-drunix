#!/usr/bin/env bash
#
# Phase 2, hard requirement (c): demonstrate four things against the LIVE
# Drunix network (not unit tests) — a lock, a release, a refund, and a
# rejected unilateral release. Run this only after `go test ./...` in
# chaincode/escrow is green and the escrow chaincode is deployed (see root
# README / NOTES.md for the deploy command and the exact endorsement policy
# applied).
#
set -uo pipefail  # not -e: this script's own report/exit-code accounting matters more than bash's default abort-on-error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

STAMP="$(date +%s)"
RELEASE_ID="demo-release-${STAMP}"
REFUND_ID="demo-refund-${STAMP}"

fail=0

c_blue "############################################################"
c_blue "# 1. LOCK"
c_blue "############################################################"
do_invoke "{\"Args\":[\"InitiateEscrow\",\"${RELEASE_ID}\",\"500000\",\"payer-acct-A\",\"payee-acct-A\"]}"
net query  "{\"Args\":[\"ReadEscrow\",\"${RELEASE_ID}\"]}"
do_invoke "{\"Args\":[\"LockEscrow\",\"${RELEASE_ID}\"]}"
state=$(read_state "${RELEASE_ID}")
c_blue "State after lock: ${state}"
if [ "${state}" = "LOCKED" ]; then c_green "1. LOCK: OK"; else c_red "1. LOCK: FAILED (state=${state})"; fail=1; fi

c_blue "############################################################"
c_blue "# 2. RELEASE (dual-org endorsed — the normal, legal path)"
c_blue "############################################################"
do_invoke "{\"Args\":[\"ReleaseEscrow\",\"${RELEASE_ID}\"]}"
state=$(read_state "${RELEASE_ID}")
c_blue "State after release: ${state}"
if [ "${state}" = "RELEASED" ]; then c_green "2. RELEASE: OK"; else c_red "2. RELEASE: FAILED (state=${state})"; fail=1; fi

c_blue "############################################################"
c_blue "# 3. REFUND (separate escrow, dual-org endorsed)"
c_blue "############################################################"
do_invoke "{\"Args\":[\"InitiateEscrow\",\"${REFUND_ID}\",\"250000\",\"payer-acct-B\",\"payee-acct-B\"]}"
do_invoke "{\"Args\":[\"LockEscrow\",\"${REFUND_ID}\"]}"
do_invoke "{\"Args\":[\"RefundEscrow\",\"${REFUND_ID}\"]}"
state=$(read_state "${REFUND_ID}")
c_blue "State after refund: ${state}"
if [ "${state}" = "REFUNDED" ]; then c_green "3. REFUND: OK"; else c_red "3. REFUND: FAILED (state=${state})"; fail=1; fi

c_blue "############################################################"
c_blue "# 4. REJECTED UNILATERAL RELEASE"
c_blue "############################################################"
"${SCRIPT_DIR}/single_org_release_rejected.sh"
if [ $? -eq 0 ]; then c_green "4. REJECTED UNILATERAL RELEASE: OK"; else c_red "4. REJECTED UNILATERAL RELEASE: FAILED"; fail=1; fi

c_blue "############################################################"
if [ "${fail}" -eq 0 ]; then
  c_green "ALL FOUR LIVE DEMONSTRATIONS PASSED"
else
  c_red "AT LEAST ONE DEMONSTRATION FAILED — see above"
fi
exit "${fail}"
