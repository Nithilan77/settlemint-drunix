# NOTES — Drunix deviations, workarounds, and quirks

Running log for the Citi × NPCI Drunix Hackathon (CHL-7007) build. Kept per the project's
working agreement: every deviation from vanilla Fabric, every workaround, every Drunix
quirk goes here — this is pitch material and potential upstream-issue material.

---

## 2026-09-25 — Phase 0: Feasibility gate

### Environment audit (Windows 11 Home, build 10.0.26200)

| Tool | Status | Detail |
|---|---|---|
| git | ✅ present | 2.55.0.windows.5 |
| Docker CLI | ✅ present | 29.7.2, installed per-user at `%LOCALAPPDATA%\Programs\DockerDesktop` |
| Docker Compose | ✅ present | v5.5.1 (bundled with Docker Desktop) |
| Docker **daemon** | ❌ **not running — blocking** | See below |
| Go | ❌ not installed | Neither on Windows PATH nor Git-Bash PATH. Required per test-network's own prereqs list ("Linux: git, Docker, Golang, jq") |
| jq | ❌ not installed | Same prereqs list |
| bash | ✅ present | GNU bash 5.3.15, Cygwin-flavored (via Git for Windows), not MSYS2 — worth watching for POSIX-path vs Windows-path issues in Docker volume mounts later |
| RAM | ✅ ~23.4 GiB total | Plenty for the intended stack |
| CPU | ✅ 18 logical cores | Plenty |

### Blocker: Docker Desktop cannot start — WSL2 is required and missing

`docker info` fails with:
```
failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine
```

Docker Desktop's own backend log (`%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`)
gives the root cause directly:
```
overwriting desktop state error: engine linux/wsl failed to start: checking preconditions: checking WSL version: wsl is not installed
```

**Why this is a hard blocker, not a config tweak:** Docker Desktop on Windows needs either
WSL2 or a Hyper-V backend. This machine is **Windows 11 Home**, and Hyper-V is not available
on Home editions at all (Pro/Enterprise/Education only) — so WSL2 is the *only* path. WSL2
itself is not installed (`wsl -l -v` → "The Windows Subsystem for Linux is not installed"),
and installing it requires the Windows "Virtual Machine Platform" + "WSL" optional features,
which requires **admin elevation** and typically a **reboot**. Neither is something to do
without explicit sign-off, per the project's risk-of-action guidance.

**Options for the user to choose between** (raised in chat, not decided here):
1. Install WSL2 (`wsl --install`, admin PowerShell, reboot) — standard path, keeps everything local.
2. Develop inside a remote/cloud Linux box (devcontainer, cloud VM) instead of native Windows.
3. Some other environment the user prefers.

### Secondary deviations/risks noted while reading test-network scripts (not yet hit, flagging early)

- `network.sh prereq` (`scripts/utils.sh:installPrereqs`) downloads **upstream Hyperledger
  Fabric's** `install-fabric.sh` from `hyperledger/fabric` on GitHub — i.e. it fetches
  *vanilla Fabric* CLI binaries (peer/orderer/cryptogen/fabric-ca-client), not Drunix-specific
  binaries. The actual Drunix behavior (Lite Peer / Committing Peer / Validation Service) comes
  entirely from the **container images** referenced in the compose files, not from the CLI
  binaries. Worth double-checking peer CLI compatibility once we're past the Docker blocker.
- Prereqs doc explicitly says **"Docker version <= 28"** — this machine has Docker 29.7.2,
  which is *not* the version the scripts were validated against. Flag if anything docker-compose
  related misbehaves later.
- Intended container topology per `compose/compose-test-net.yaml` +
  `scripts/yugabyte/compose.yaml` (not yet verified live — Docker daemon down):
  - 1 orderer (`npcioss/drunix-orderer:1.0.0`)
  - Per org (org1, org2): 1 Lite Peer + 1 Committing Peer (both `npcioss/drunix-peer:1.0.0`,
    role presumably set via env/config) + 1 Validation Service (`npcioss/drunix-vscc:1.0.0`)
  - Per org: 1 YugabyteDB node (`yugabytedb/yugabyte:2025.2.0.0-b131`) + 1 KeyDB transient
    store (`eqalpha/keydb`)
  - Total when fully up: 11 containers (1 orderer + 2×(LP+CP+VS) + 2×(Yugabyte+KeyDB))
  - Peer index convention per README: **0 = Lite Peer, 1 = Committing Peer** (used by
    `envVar.sh setGlobals orgIndex peerIndex`)

---

## 2026-09-25 — Phase 0: Gate result — network.sh up (SUCCESS, with two workarounds)

WSL2 (Ubuntu, plus the docker-desktop distro) is installed and the Docker daemon is confirmed
running (`docker info` succeeds; kernel `6.18.33.2-microsoft-standard-WSL2`, backend "Docker
Desktop", OSType linux). Go 1.27.0 and jq 1.8.2 installed via `winget` (`GoLang.Go`, `jqlang.jq`)
since neither is on Windows PATH nor Git-Bash PATH by default right after install - needed to be
appended explicitly per-session until a shell restart picks up the updated user PATH.

**Result: network came up fully - all 11 containers running - but only after two workarounds.**
Neither blocker was the Docker 29-vs-28 issue flagged earlier; that turned out to be a non-issue
in practice (network.sh up completed fully against Docker 29.7.2 / Compose v5.5.1, no
engine-version-related failure observed).

### Workaround 1 - peer/tool binaries were never built
`network.sh up`'s `checkPrereqs` requires a local `peer` binary on PATH (`peer version`) plus
`../config`. No `make` exists on this machine at all (not installed, and not present in stock
Git-for-Windows/Git-Bash), and no prebuilt binary existed either. Built the native tool binaries
directly with `go install`, replicating the Makefile's pattern rule:
`GOBIN=<repo>/build/bin go install -ldflags "-X .../metadata.Version=... -X
.../metadata.CommitSHA=..." -buildvcs=false github.com/npci/drunix/cmd/<tool>`
for `peer`, `cryptogen`, `configtxgen`, `configtxlator`, `osnadmin`. All built cleanly against
go.mod's `go 1.26.1` requirement using the installed 1.27.0 toolchain. Resulting LOCAL_VERSION
is `1.0.0-snapshot-<sha>` vs. the pulled `npcioss/drunix-peer:1.0.0` image's `1.0.0` -
network.sh only warns ("out of sync") on this mismatch, doesn't block. Upstream-issue material:
the documented `make peer` prereq instruction doesn't work out of the box on Windows without
MSYS2/mingw's make or building from inside WSL.

### Workaround 2 - MSYS/Git-Bash path-mangling breaks the DOCKER_SOCK bind mount
First `network.sh up` attempt got through crypto material generation and Yugabyte/KeyDB startup,
then failed to create the peer/orderer/vscc volumes and containers with:
`mkdir C:\Program Files\Git\var: Access is denied.`
Root cause: `network.sh` defaults `DOCKER_SOCK="/var/run/docker.sock"` (DOCKER_HOST unset), and
the peer/orderer/vscc compose services bind-mount `${DOCKER_SOCK}:/host/var/run/docker.sock`
(compose/compose-test-net.yaml:146,367; compose/docker/docker-compose-test-net.yaml x6). When
Git-Bash's MSYS runtime hands that env var to the native docker-compose.exe, MSYS's automatic
POSIX-path conversion rewrites the leading `/var/...` into `C:\Program Files\Git\var\...` (the
Git-for-Windows install root) before Docker Desktop ever sees it, and Docker then tries to
literally mkdir that Windows path, which fails without admin rights. This is exactly the
"MSYS_NO_PATHCONV" class of bug, and is exactly what the earlier pass flagged as a risk ("worth
watching for POSIX-path vs Windows-path issues in Docker volume mounts"). Fix: run network.sh
(both up and down) with `MSYS_NO_PATHCONV=1` exported in the Git-Bash session. With that set,
`network.sh down` cleanly tore down the partial network, and `network.sh up` recreated it with
all volumes/containers correctly. This env var should become a standing part of the Windows dev
workflow (export it at the top of a wrapper script, or in `.bashrc`), not remembered ad hoc.

### Secondary observation - Yugabyte cold-start race (not fatal, but noteworthy)
On the first successful up, 4 of 11 containers (lp1.org1, cp.org1, vs1.org1, vs1.org2, and
shortly after also lp1.org2/cp.org2) exited immediately with:
`panic: Error in instantiating ledger provider: failed to connect to user=yugabyte
database=yugabyte: ...:5433 (yugabyte-orgN): dial error: connection refused`
network.sh's networkUp() only does a fixed `sleep 30` after starting the Yugabyte/KeyDB compose
stack before bringing up peers/orderer/vscc - not long enough for YugabyteDB's YSQL layer to
finish cold-starting (`yugabyted status` confirmed "YSQL Status: Ready" only after roughly 2+
minutes). All 6 crashed containers came up clean on a plain `docker start` once Yugabyte was
actually ready - this is a pure timing race, not a real incompatibility. Upstream-issue material:
the fixed 30s sleep in network.sh is not a reliable readiness gate for YugabyteDB; should be
replaced with a real healthcheck/poll loop (e.g. pg_isready/ysqlsh against 5433, or a compose
`depends_on: condition: service_healthy`), especially on slower/first-run/WSL2-backed machines.

### Final verified topology (11/11 containers, all Up and stable)

| Container | Image | Role |
|---|---|---|
| orderer.example.com | npcioss/drunix-orderer:1.0.0 | Raft orderer (single node) |
| lp1.org1 | npcioss/drunix-peer:1.0.0 | Org1 Lite Peer (peer0) |
| cp.org1 | npcioss/drunix-peer:1.0.0 | Org1 Committing Peer (peer1) |
| vs1.org1 | npcioss/drunix-vscc:1.0.0 | Org1 Validation Service |
| lp1.org2 | npcioss/drunix-peer:1.0.0 | Org2 Lite Peer (peer0) |
| cp.org2 | npcioss/drunix-peer:1.0.0 | Org2 Committing Peer (peer1) |
| vs1.org2 | npcioss/drunix-vscc:1.0.0 | Org2 Validation Service |
| yugabyte-org1 | yugabytedb/yugabyte:2025.2.0.0-b131 | Org1 state DB |
| yugabyte-org2 | yugabytedb/yugabyte:2025.2.0.0-b131 | Org2 state DB |
| hlf_keydb_org1msp | eqalpha/keydb | Org1 transient store |
| hlf_keydb_org2msp | eqalpha/keydb | Org2 transient store |

Matches the topology predicted in the earlier pass exactly (1 orderer + 2x(LP+CP+VS) +
2x(Yugabyte+KeyDB) = 11). Channel creation / chaincode deploy not yet attempted - next gate.

---

## 2026-09-25 - Phase 0 addendum: steady-state check on the 6 restarted containers

Before moving on, re-checked the 6 containers that crashed once on first boot (lp1.org1,
cp.org1, vs1.org1, vs1.org2, lp1.org2, cp.org2) and were brought up with a plain `docker start`
after Yugabyte finished its cold start (see prior entry). Result: clean. `docker inspect
RestartCount` is 0 for all six (a manual `docker start` on an already-exited container doesn't
count as a restart-policy restart), `State.Status` is `running`, and `docker logs` shows exactly
one historical panic block each (the original Yugabyte-not-ready crash) followed by a normal,
single, non-repeating startup sequence with no further panics/errors/fatals since. No crash loop.

## 2026-09-25 - Phase 0.5: channel creation + stock chaincode deploy (SUCCESS)

Used the stock `asset-transfer-basic/chaincode-go` sample that ships in `drunix-network/` -
exactly the path `network.config` already points `CC_SRC_PATH` at by default, so no custom
chaincode was needed.

### Workaround 3 - MSYS_NO_PATHCONV=1 must NOT be set globally; it only fixes the docker-compose bind mount
Running `network.sh createChannel` with `MSYS_NO_PATHCONV=1` still exported from the Phase 0
`network.sh up` session broke `configtxgen` immediately: `Error reading configuration: open :
The system cannot find the file specified.` Root cause: `MSYS_NO_PATHCONV=1` disables Git-Bash's
automatic POSIX-to-Windows path translation for *everything*, not just the one `DOCKER_SOCK`
value that needed it. `FABRIC_CFG_PATH` (and other args to native Windows Go binaries -
`configtxgen.exe`, `peer.exe`, `cryptogen.exe`, `configtxlator.exe`) need that translation to
happen (POSIX `/d/.../configtx` -> `D:\...\configtx`), since these are ordinary native Windows
executables doing `os.Open()` on the literal string they're given.
**Correct scoping:** only `network.sh up`/`network.sh down` (which invoke `docker compose` with
the `${DOCKER_SOCK}` bind mount) need `MSYS_NO_PATHCONV=1`. Every other `network.sh` mode
(`createChannel`, `deployCC`, `cc invoke`, `cc query`, ...) must run WITHOUT it, or every native
tool call inside those flows breaks. This isn't a one-time env var to export for the session -
it needs to be toggled per-command on Windows/Git-Bash.

### Workaround 4 - ccenv builder image not pre-pulled, and its tag doesn't match the other images
`network.sh deployCC` failed chaincode install with:
`docker build failed: ... Error creating container: Error response from daemon: No such image:
npcioss/drunix-ccenv:1.0`
Fabric's Go chaincode build path uses the low-level Docker Engine API (container create + copy +
commit) rather than `docker build` with a Dockerfile, so it does **not** auto-pull a missing base
image the way `docker build`/`docker run` normally would. `docker pull npcioss/drunix-ccenv:1.0`
by hand fixed it immediately - the image exists on the registry, it just isn't fetched by
anything in the `network.sh` flow (not by `network.sh up`, not by `deployCC.sh`). Also note the
**tag inconsistency**: orderer/peer/vscc images are tagged `1.0.0`, but the ccenv builder image is
tagged `1.0` (no patch component) - worth flagging upstream since it's an easy thing to get wrong
if someone tries to pin/mirror images by convention.

### Minor bug - `network.sh cc invoke` / `cc query` reference an unset $DELAY
Every `cc invoke`/`cc query` call printed `sleep: missing operand` before succeeding on the retry.
Root cause: `scripts/ccutils.sh`'s `chaincodeInvoke`/`chaincodeQuery` functions read a `$DELAY`
global that only `scripts/deployCC.sh` ever sets (from its positional args); `network.sh`'s own
`invokeChaincode()`/`queryChaincode()` functions (used by the `cc invoke`/`cc query` subcommands)
never export `DELAY` at all. Harmless - the loop just does `sleep <empty>` (errors, but bash
just continues), retries immediately, and succeeds - but worth a one-line upstream fix
(`: ${DELAY:=3}`) since it clutters output and could mask a real timing issue later.

### What was verified end-to-end
1. `network.sh createChannel` - created `mychannel`, joined all 4 org peers (lp1.org1, cp.org1,
   lp1.org2, cp.org2), set anchor peers for both orgs. Clean run, no retries needed.
2. `network.sh deployCC` - vendored the sample's Go deps, packaged `basic_1.0`, installed on
   peer0.org1 and peer0.org2 (**note:** despite Drunix's LP/CP/VS three-role peer model, chaincode
   install/approve/commit in this stock flow only ever targets `peer0.orgN` a.k.a. the **Lite
   Peer** - `setGlobals` only defines peer indices 0 and 1, never touches the Validation Service
   peer directly for lifecycle ops), approved by both orgs, committed at sequence 1.
3. `network.sh cc invoke -ccn basic -ccic '{"Args":["InitLedger"]}'` - status 200, endorsed by
   both org Lite Peers, ordered, committed.
4. `network.sh cc query -ccn basic -ccqc '{"Args":["GetAllAssets"]}'` - returned all 6 seeded
   assets correctly.
5. A second, isolated transaction - `CreateAsset asset999 teal 10 Nithilan 9999` - invoked,
   then read back both via `ReadAsset` (peer query API) and **directly via SQL** against both
   orgs' YugabyteDB instances:
   `select * from mychannel.basic where db_value->>'ID' = 'asset999';`
   -> identical row (`block_number 7`, JSONB `db_value` byte-for-byte matching the chaincode
   query result) present on **both** `yugabyte-org1` and `yugabyte-org2`. The peer's state DB
   provider auto-created a `mychannel` schema with one table per chaincode (`mychannel.basic`),
   keyed by the composite key as `bytea`, value as `jsonb`, tagged with the committing
   block/transaction number - confirming Yugabyte is genuinely the ledger's state DB, not just
   configured and idle.

**Result: chaincode transaction commit is real and independently verifiable in the SQL state DB,
on both orgs, not just through the Fabric query API.**

---

## 2026-09-25 - Phase 2: escrow chaincode core, deployed and demonstrated live

Implemented the escrow claim state machine (chaincode/escrow/escrow.go) and deployed it
to the running network as a second chaincode ("escrow") alongside the Phase 0.5 sample
("basic"), on the existing "mychannel". Full state machine, tests, and live demo output
are in the escrow chaincode's own files; this entry is the Windows/tooling deviations
found while getting there.

### Bug found in network/net.sh - LOCALAPPDATA-derived PATH entries don't resolve
`setup_toolchain()`'s jq fallback built the jq install directory from
`find "${LOCALAPPDATA}/Microsoft/WinGet/Packages" ...`, which yields a path mixing
Windows backslashes (from `$LOCALAPPDATA`, e.g. `C:\Users\...\Local`) with the
forward-slash suffix `find` appends. Appending that mixed-separator string directly to
`PATH` looks fine when echoed, but bash's own `command -v`/exec path search silently
fails to resolve anything under it - confirmed by reproducing standalone:
`export PATH="$PATH:$mixed_path"; jq --version` -> `jq: command not found` (exit 127),
even though the exact same directory located via `find` resolves and runs fine once
piped through `cygpath -u` first. Fixed by normalizing with `cygpath -u` before
appending. This had never actually been exercised until the escrow chaincode deploy (the
Phase 1 `doctor` command only prints whether jq is already on PATH; it doesn't exercise
the fallback-and-append path the way `deploy-cc` does), so it shipped un-caught in Phase 1.

### Timing bug (not a Windows issue, but hit hard while writing the live demo) - plain `peer chaincode invoke` does not wait for commit
`network.sh cc invoke` (`ccutils.sh:chaincodeInvoke`) runs a bare
`peer chaincode invoke ...` with no `--waitForEvent` flag. That call returns as soon as
the transaction is endorsed and submitted to the orderer - well before the orderer
actually cuts a block (channel `BatchTimeout: 2s`, configtx.yaml) and peers validate and
commit it. A query immediately following an invoke can therefore read pre-commit state.
(This is distinct from the deploy-time `approveformyorg`/`commit` calls, which *do* use
`ClientWait` and print "committed with status (VALID)" - only the plain data-plane
`invoke` skips this.) Combined with the already-documented `$DELAY`-unset bug (Phase 0.5
NOTES entry - the invoke/query retry loop's `sleep $DELAY` fails silently and retries
instantly instead of backing off), a naive invoke-then-query sequence can flake. Worked
around entirely in our own test harness (`chaincode/escrow/test/integration/common.sh`'s
`do_invoke`, a fixed `sleep 4` after every state-changing call) rather than touching the
vendor script.

### Deploying a second chaincode on the same channel: no surprises
Deploying `escrow` alongside the already-committed `basic` chaincode on `mychannel` (own
Go module, own `go.mod`/vendored deps, same `npcioss/drunix-ccenv:1.0` builder image)
worked exactly like Phase 0.5's `basic` deploy, with one addition: passing
`-ccep "AND('Org1MSP.peer','Org2MSP.peer')"` correctly threads through to every lifecycle
step's `--signature-policy` flag (`approveformyorg`, `checkcommitreadiness`, `commit`) and
is visible verbatim in `peer lifecycle chaincode querycommitted --output json`'s
`validation_parameter` (base64-encoded `SignaturePolicyEnvelope`).

### Live-verified: single-org-endorsed RELEASE is silently dropped, not loudly refused
`peer chaincode invoke` with only `--peerAddresses localhost:7051` (Org1 alone) against
a LOCKED escrow **simulates and submits successfully** (`status:200`, exit code 0) -
proposal simulation has no way to know the transaction will fail endorsement-policy
validation later. The transaction still gets ordered into a block. Only when peers
validate that block against the chaincode's endorsement policy does it get marked
invalid and excluded from the world-state update - invisible from the invoking CLI's own
output, only observable by reading the ledger state before/after. Good thing to know
before building `gateway/` in Phase 3: a submitted single-org transaction will look like
it succeeded at the RPC level; only a subsequent read (or listening for the commit event)
reveals it didn't take effect. This is exactly the "core guarantee" test's proof
strategy - see `chaincode/escrow/test/integration/single_org_release_rejected.sh`.

---
