#!/usr/bin/env bash
# Shared helpers for the escrow integration tests/demos. These run against
# the LIVE Drunix network (not mocks) — bring it up and deploy the escrow
# chaincode first (see ../../README.md / root README).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TEST_NETWORK_DIR="${REPO_ROOT}/drunix/drunix-network/test-network"
CC_NAME="${CC_NAME:-escrow}"
CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"

# single_org_release below calls `peer` directly (not through net.sh, which
# does its own PATH setup) — make sure the built binary is reachable.
export PATH="${REPO_ROOT}/drunix/build/bin:${PATH}"

c_blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }

# net <subcommand> ... — thin wrapper around network/net.sh with CC_NAME
# already pointed at the escrow chaincode.
net() {
  CC_NAME="${CC_NAME}" CHANNEL_NAME="${CHANNEL_NAME}" "${REPO_ROOT}/network/net.sh" "$@"
}

# do_invoke <json-args> — invoke via net.sh, then wait past the channel's
# BatchTimeout (2s, configtx.yaml) before returning. Plain `peer chaincode
# invoke` (what network.sh's `cc invoke` uses) returns as soon as the
# transaction is endorsed and submitted to the orderer — NOT after it is
# actually ordered, validated, and committed. Without this wait, a query
# immediately following an invoke can read stale (pre-commit) state.
do_invoke() {
  net invoke "$1"
  sleep 4
}

# read_state <escrow-id> — queries ReadEscrow via the normal (dual-org
# capable) query path and prints just the "state" field's value.
read_state() {
  local id="$1"
  net query "{\"Args\":[\"ReadEscrow\",\"${id}\"]}" | grep -o '"state":"[A-Z]*"' | head -1 | sed 's/"state":"//; s/"//'
}

# single_org_release <escrow-id> — attempts ReleaseEscrow endorsed by
# Org1 ONLY (peer0.org1 / Lite Peer, port 7051), bypassing network.sh's own
# `cc invoke` (which always gathers both orgs — see ccutils.sh:chaincodeInvoke).
# This is the one call in this whole test suite that deliberately violates
# the chaincode's deploy-time endorsement policy, to prove it's enforced.
single_org_release() {
  local id="$1"
  (
    cd "${TEST_NETWORK_DIR}"
    unset MSYS_NO_PATHCONV
    set +u  # scripts/envVar.sh references $OVERRIDE_ORG etc. without defaults; our -u would trip on it
    export FABRIC_CFG_PATH="${PWD}/../config"
    # shellcheck disable=SC1091
    . scripts/envVar.sh
    setGlobals 1 0   # Org1MSP, peer0 (Lite Peer) — Org1 identity, Org1 peer
    set -x
    peer chaincode invoke \
      -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
      -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
      -c "{\"Args\":[\"ReleaseEscrow\",\"${id}\"]}" \
      --tls --cafile "${ORDERER_CA}" \
      --peerAddresses localhost:7051 --tlsRootCertFiles "${PEER0_ORG1_CA}"
  )
}
