#!/usr/bin/env bash
#
# net.sh — wrapper around drunix/drunix-network/test-network/network.sh that bakes in
# every Windows/Git-Bash workaround recorded in NOTES.md (Phase 0 / Phase 0.5), so a
# teammate on the same Windows 11 + Docker Desktop + WSL2 + Git-Bash setup can bring the
# network up, create the channel, and deploy chaincode without re-discovering any of it.
#
# This script does NOT contain business logic. It only sequences and patches around the
# upstream drunix-network scripts. See ../NOTES.md for the full incident-by-incident
# writeup of *why* each of these is here.
#
# Usage:
#   network/net.sh doctor          # check prereqs, report what's missing
#   network/net.sh build-tools     # go install peer/cryptogen/configtxgen/... (Workaround 1)
#   network/net.sh up              # bring the 11-container network up (Workarounds 2, 6)
#   network/net.sh down            # tear the network down (Workaround 2)
#   network/net.sh create-channel  # create + join 'mychannel' (Workaround 3)
#   network/net.sh deploy-cc       # deploy the default chaincode (Workarounds 3, 4)
#   network/net.sh invoke '<json>' [ccname]   # e.g. invoke '{"Args":["InitLedger"]}'
#   network/net.sh query  '<json>' [ccname]   # e.g. query  '{"Args":["GetAllAssets"]}'
#   network/net.sh status          # container table + quick error scan
#   network/net.sh bootstrap       # up -> create-channel -> deploy-cc, in one shot
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRUNIX_ROOT="${REPO_ROOT}/drunix"
TEST_NETWORK_DIR="${DRUNIX_ROOT}/drunix-network/test-network"
BUILD_BIN="${DRUNIX_ROOT}/build/bin"

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
CC_NAME="${CC_NAME:-basic}"
CC_SRC_PATH="${CC_SRC_PATH:-../asset-transfer-basic/chaincode-go}"  # relative to TEST_NETWORK_DIR
CC_VERSION="${CC_VERSION:-1.0}"
CC_SEQUENCE="${CC_SEQUENCE:-auto}"
CC_END_POLICY="${CC_END_POLICY:-}"  # e.g. "AND('Org1MSP.peer','Org2MSP.peer')" — empty means channel default
CCENV_IMAGE="npcioss/drunix-ccenv:1.0"   # NOTE the tag is 1.0, not 1.0.0 like the other images

# Fabric-role containers known (NOTES.md "Final verified topology") to occasionally exit
# on first boot if YugabyteDB isn't ready yet (Workaround 6). Yugabyte/KeyDB never need this.
RACE_PRONE_CONTAINERS=(lp1.org1 cp.org1 vs1.org1 vs1.org2 lp1.org2 cp.org2)
ALL_FABRIC_CONTAINERS=(orderer.example.com lp1.org1 cp.org1 vs1.org1 lp1.org2 cp.org2 vs1.org2)
YUGABYTE_CONTAINERS=(yugabyte-org1 yugabyte-org2)

c_blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
die()     { c_red "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------------------
# Workaround: Go and jq are installed by `winget` but the current shell's PATH doesn't see
# them until a shell restart. Rather than requiring that, locate them from their known,
# non-per-user install locations and append to PATH for this process only.
# ---------------------------------------------------------------------------------------
setup_toolchain() {
  if ! command -v go >/dev/null 2>&1; then
    if [ -x "/c/Program Files/Go/bin/go.exe" ]; then
      export PATH="${PATH}:/c/Program Files/Go/bin"
    else
      die "go not found. Install with: winget install -e --id GoLang.Go  (then re-run)"
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    local jq_dir
    # $LOCALAPPDATA is a Windows env var (backslashes); `find` still works
    # against it, but the resulting path is a backslash/forward-slash mix
    # that bash's own PATH lookup won't resolve — normalize with cygpath.
    jq_dir=$(find "${LOCALAPPDATA}/Microsoft/WinGet/Packages" -maxdepth 1 -iname "jqlang.jq_*" 2>/dev/null | head -1)
    [ -n "${jq_dir}" ] && jq_dir=$(cygpath -u "${jq_dir}")
    if [ -n "${jq_dir}" ] && [ -x "${jq_dir}/jq.exe" ]; then
      export PATH="${PATH}:${jq_dir}"
    else
      die "jq not found. Install with: winget install -e --id jqlang.jq  (then re-run)"
    fi
  fi

  # Pick up the binaries built by build-tools (peer, cryptogen, configtxgen, ...).
  # network.sh itself also prepends this directory, but subcommands we call directly
  # (docker exec, etc.) don't go through network.sh, so make sure it's on PATH here too.
  export PATH="${BUILD_BIN}:${PATH}"
}

check_docker() {
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start Docker Desktop (WSL2 backend) first."
}

# ---------------------------------------------------------------------------------------
# Workaround 1: no `make` on stock Windows/Git-Bash, so replicate the Makefile's pattern
# rule for the native tool binaries directly with `go install`.
# ---------------------------------------------------------------------------------------
build_tools() {
  setup_toolchain
  [ -d "${DRUNIX_ROOT}" ] || die "drunix/ clone not found at ${DRUNIX_ROOT}"

  mkdir -p "${BUILD_BIN}"
  local extra_version
  extra_version=$(git -C "${DRUNIX_ROOT}" rev-parse --short HEAD)
  local ldflags="-X github.com/npci/drunix/common/metadata.Version=1.0.0-snapshot-${extra_version} -X github.com/npci/drunix/common/metadata.CommitSHA=${extra_version}"

  local tool
  for tool in peer cryptogen configtxgen configtxlator osnadmin; do
    c_blue "Building ${tool}..."
    ( cd "${DRUNIX_ROOT}" && GOBIN="${BUILD_BIN}" go install -ldflags "${ldflags}" -buildvcs=false "github.com/npci/drunix/cmd/${tool}" )
  done
  c_green "Tool binaries built in ${BUILD_BIN}"
}

# ---------------------------------------------------------------------------------------
# Workaround 6: network.sh's fixed `sleep 30` after starting YugabyteDB isn't a reliable
# readiness gate — poll `yugabyted status` on both org DBs until YSQL is actually ready.
# ---------------------------------------------------------------------------------------
wait_for_yugabyte() {
  local timeout_s=180 waited=0 c all_ready
  c_blue "Waiting for YugabyteDB YSQL to become ready on both orgs (this can take ~2 minutes cold)..."
  while [ "${waited}" -lt "${timeout_s}" ]; do
    all_ready=true
    for c in "${YUGABYTE_CONTAINERS[@]}"; do
      docker exec "${c}" yugabyted status 2>/dev/null | grep -q "YSQL Status: *Ready" || all_ready=false
    done
    if [ "${all_ready}" = true ]; then
      c_green "YugabyteDB YSQL ready on both orgs."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  c_red "Timed out after ${timeout_s}s waiting for YugabyteDB YSQL readiness. Continuing anyway; expect Workaround 6 to kick in."
}

# ---------------------------------------------------------------------------------------
# Workaround 6 (continued): if the peer/vscc containers dialed Yugabyte before it was
# ready, they panic and exit once. Once Yugabyte is confirmed ready, restart any of the
# known race-prone containers that are sitting in `Exited`.
# ---------------------------------------------------------------------------------------
restart_crashed_containers() {
  local c status restarted=false
  for c in "${RACE_PRONE_CONTAINERS[@]}"; do
    status=$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo "missing")
    if [ "${status}" = "exited" ]; then
      c_blue "Restarting ${c} (exited before Yugabyte was ready)..."
      docker start "${c}" >/dev/null
      restarted=true
    fi
  done
  if [ "${restarted}" = true ]; then
    sleep 10
    for c in "${RACE_PRONE_CONTAINERS[@]}"; do
      status=$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo "missing")
      [ "${status}" = "running" ] || c_red "  ${c} is '${status}', not 'running' — check: docker logs ${c}"
    done
  fi
}

print_status() {
  check_docker
  docker ps -a --filter "name=orderer.example.com" --filter "name=lp1." --filter "name=cp." \
    --filter "name=vs1." --filter "name=yugabyte-" --filter "name=hlf_keydb_" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo
  c_blue "Scanning logs for panic/fatal/error (excludes the known one-time Yugabyte cold-start race)..."
  local c hits
  for c in "${ALL_FABRIC_CONTAINERS[@]}"; do
    hits=$(docker logs "${c}" 2>&1 | grep -icE "panic|fatal|error" || true)
    [ "${hits}" -gt 0 ] && echo "  ${c}: ${hits} matching line(s) — run: docker logs ${c}"
  done
  c_green "Status scan complete."
}

# ---------------------------------------------------------------------------------------
# Workaround 2: network.sh defaults DOCKER_SOCK=/var/run/docker.sock and the peer/orderer/
# vscc compose services bind-mount it. Git-Bash's MSYS runtime mangles that POSIX path into
# a Windows path under the Git install dir before docker-compose.exe sees it, so volume
# creation fails with "Access is denied". MSYS_NO_PATHCONV=1 stops that mangling — but see
# Workaround 3: it must be scoped ONLY to this up/down call.
# ---------------------------------------------------------------------------------------
net_up() {
  setup_toolchain
  check_docker
  [ -x "${BUILD_BIN}/peer.exe" ] || build_tools
  c_blue "Bringing the network up (MSYS_NO_PATHCONV=1 scoped to this command only)..."
  ( cd "${TEST_NETWORK_DIR}" && MSYS_NO_PATHCONV=1 ./network.sh up )
  wait_for_yugabyte
  restart_crashed_containers
  print_status
}

net_down() {
  setup_toolchain
  check_docker
  c_blue "Tearing the network down (MSYS_NO_PATHCONV=1 scoped to this command only)..."
  ( cd "${TEST_NETWORK_DIR}" && MSYS_NO_PATHCONV=1 ./network.sh down )
}

# ---------------------------------------------------------------------------------------
# Workaround 3: createChannel/deployCC/cc invoke/cc query run native Windows binaries
# (configtxgen, peer, configtxlator) that NEED normal Git-Bash path translation. Do not
# inherit MSYS_NO_PATHCONV here even if it's set in the caller's shell.
# ---------------------------------------------------------------------------------------
net_create_channel() {
  setup_toolchain
  check_docker
  c_blue "Creating/joining channel '${CHANNEL_NAME}' (no MSYS_NO_PATHCONV — native tools need normal path translation)..."
  ( cd "${TEST_NETWORK_DIR}" && unset MSYS_NO_PATHCONV; ./network.sh createChannel -c "${CHANNEL_NAME}" )
}

# ---------------------------------------------------------------------------------------
# Workaround 4: the Go chaincode build path uses the low-level Docker API and never
# auto-pulls its base image. Pre-pull it (idempotent — no-op if already present).
# ---------------------------------------------------------------------------------------
net_deploy_cc() {
  setup_toolchain
  check_docker
  c_blue "Ensuring chaincode builder image ${CCENV_IMAGE} is present..."
  docker pull "${CCENV_IMAGE}"
  c_blue "Deploying chaincode '${CC_NAME}' v${CC_VERSION} from '${CC_SRC_PATH}' on channel '${CHANNEL_NAME}' (no MSYS_NO_PATHCONV)..."
  local -a extra_flags=()
  [ -n "${CC_END_POLICY}" ] && extra_flags+=(-ccep "${CC_END_POLICY}")
  c_blue "Endorsement policy: ${CC_END_POLICY:-<channel default>}"
  ( cd "${TEST_NETWORK_DIR}" && unset MSYS_NO_PATHCONV; ./network.sh deployCC -c "${CHANNEL_NAME}" -ccn "${CC_NAME}" -ccp "${CC_SRC_PATH}" -ccl go -ccv "${CC_VERSION}" -ccs "${CC_SEQUENCE}" "${extra_flags[@]}" )
}

net_invoke() {
  local args_json="${1:?usage: net.sh invoke '<json args>' [ccname]}"
  local ccname="${2:-${CC_NAME}}"
  setup_toolchain
  check_docker
  ( cd "${TEST_NETWORK_DIR}" && unset MSYS_NO_PATHCONV; ./network.sh cc invoke -c "${CHANNEL_NAME}" -ccn "${ccname}" -ccic "${args_json}" )
}

net_query() {
  local args_json="${1:?usage: net.sh query '<json args>' [ccname]}"
  local ccname="${2:-${CC_NAME}}"
  setup_toolchain
  check_docker
  ( cd "${TEST_NETWORK_DIR}" && unset MSYS_NO_PATHCONV; ./network.sh cc query -c "${CHANNEL_NAME}" -ccn "${ccname}" -ccqc "${args_json}" )
}

net_doctor() {
  echo "Docker daemon:"; docker info >/dev/null 2>&1 && c_green "  OK" || c_red "  NOT reachable"
  echo "Go:"; command -v go >/dev/null 2>&1 && go version | sed 's/^/  /' || echo "  not on PATH (will search /c/Program Files/Go/bin)"
  echo "jq:"; command -v jq >/dev/null 2>&1 && jq --version | sed 's/^/  /' || echo "  not on PATH (will search under \$LOCALAPPDATA/Microsoft/WinGet)"
  echo "Tool binaries in ${BUILD_BIN}:"
  if [ -x "${BUILD_BIN}/peer.exe" ]; then "${BUILD_BIN}/peer.exe" version | sed 's/^/  /'; else echo "  not built yet — run: network/net.sh build-tools"; fi
  echo "Chaincode builder image (${CCENV_IMAGE}):"
  docker image inspect "${CCENV_IMAGE}" >/dev/null 2>&1 && c_green "  present locally" || echo "  not pulled yet — deploy-cc will pull it"
}

net_bootstrap() {
  net_up
  net_create_channel
  net_deploy_cc
  c_green "Bootstrap complete: network up, channel '${CHANNEL_NAME}' created, chaincode '${CC_NAME}' deployed."
}

case "${1:-}" in
  doctor)         net_doctor ;;
  build-tools)    build_tools ;;
  up)             net_up ;;
  down)           net_down ;;
  create-channel) net_create_channel ;;
  deploy-cc)      net_deploy_cc ;;
  invoke)         shift; net_invoke "$@" ;;
  query)          shift; net_query "$@" ;;
  status)         print_status ;;
  bootstrap)      net_bootstrap ;;
  *)
    cat <<EOF
Usage: network/net.sh <command>

  doctor           check prereqs (docker, go, jq, built tools, ccenv image)
  build-tools      go install peer/cryptogen/configtxgen/configtxlator/osnadmin
  up               bring the 11-container network up
  down             tear the network down
  create-channel   create + join '${CHANNEL_NAME}'
  deploy-cc        deploy chaincode '${CC_NAME}' from its default sample path
  invoke '<json>' [ccname]   e.g. invoke '{"Args":["InitLedger"]}'
  query  '<json>' [ccname]   e.g. query  '{"Args":["GetAllAssets"]}'
  status           container table + quick error scan
  bootstrap        up -> create-channel -> deploy-cc

All workarounds this script applies are documented in ../NOTES.md.
EOF
    exit 1
    ;;
esac
