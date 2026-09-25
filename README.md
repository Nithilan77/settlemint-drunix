# settlemint-drunix

Citi × NPCI Drunix Hackathon (CHL-7007) build. This repo wraps the upstream `drunix/`
clone (a Hyperledger Fabric fork with a Lite Peer / Committing Peer / Validation Service
model and a YugabyteDB SQL state DB) with our own application code, kept entirely
separate from the vendor tree.

**Status:** Phase 2 — escrow chaincode core (state machine + dual-org endorsement
guarantee) implemented, unit-tested, and deployed/demonstrated live. No dispute path, no
oracle, no private data collections yet. See [`docs/architecture.md`](docs/architecture.md)
for the system design and [`NOTES.md`](NOTES.md) for the full incident-by-incident log
everything below is distilled from.

## Layout

```
settlemint-drunix/
├── drunix/            vendor clone — Fabric fork + drunix-network test-network. Not ours,
│                      don't edit, NOT committed to this repo — see "Getting drunix/" below.
├── chaincode/
│   └── escrow/        our chaincode (Phase 2 core — state machine only)
├── gateway/            our application-layer service talking to the Fabric Gateway (Phase 2+)
├── web/                our frontend (Phase 2+)
├── network/            our helper scripts wrapping drunix-network/test-network (see below)
├── docs/               architecture and design docs
└── NOTES.md            running log of every Windows/Drunix deviation and workaround
```

## Getting `drunix/`

`drunix/` is excluded from this repo (`.gitignore`) and must never be committed here —
every time `network/net.sh up` brings the network up it generates **real private keys and
MSP/TLS material** on disk under `drunix/drunix-network/test-network/{crypto-config,
organizations,channel-artifacts}/`, and that must never leave your machine. `drunix/` is
also just a vendor clone with its own separate git history; nesting it inside this repo's
history would be the wrong way to track it even setting the key material aside.

Clone it yourself, into the repo root, before running anything else:

```bash
git clone https://github.com/npci/drunix.git drunix
```

(`network/net.sh` and everything else in this README assumes `drunix/` exists at the repo
root as an ordinary, git-ignored directory — that's it, no submodule wiring needed.)

## Prerequisites

- **Windows 11 with WSL2** installed (Docker Desktop needs it; Home edition has no
  Hyper-V, so WSL2 is the only backend option). `wsl --install` from an admin PowerShell,
  then reboot, if not already done.
- **Docker Desktop**, running, with the WSL2 backend confirmed (`docker info` succeeds).
- **Git for Windows** (gives you the Git-Bash shell everything here assumes).
- **Go** and **jq** — if missing, install with:
  ```
  winget install -e --id GoLang.Go
  winget install -e --id jqlang.jq
  ```
  then open a **new** Git-Bash window (PATH only updates for new shells — see
  Workaround 1 below). `network/net.sh` will also auto-locate them from their standard
  install paths even if the current shell's PATH is stale.

Everything else (native Fabric tool binaries, container images, channel, chaincode) is
handled by `network/net.sh`.

## Quickstart

```bash
git clone <this-repo-or-just-cd-in>
cd settlemint-drunix
./network/net.sh doctor      # sanity check: docker, go, jq, built tools, images
./network/net.sh bootstrap   # up -> create-channel -> deploy-cc, in one shot
```

`bootstrap` takes a few minutes the first time (image pulls + YugabyteDB cold start).
When it finishes you'll have all 11 containers running, `mychannel` created and joined
by both orgs, and the sample `basic` chaincode installed, approved, and committed.

Then try a transaction:

```bash
./network/net.sh invoke '{"Args":["InitLedger"]}'
./network/net.sh query  '{"Args":["GetAllAssets"]}'
```

Tear down when done:

```bash
./network/net.sh down
```

## Why a wrapper script, not just `drunix/.../network.sh` directly

Getting the vendor `test-network/network.sh` working on this stack (Windows 11 Home +
Docker Desktop/WSL2 + Git-Bash) took six distinct workarounds, discovered the hard way
during Phase 0 / 0.5 (full writeup in `NOTES.md`). `network/net.sh` bakes all six in so
nobody has to rediscover them:

1. **Go and jq aren't on PATH right after `winget install`.** A fresh shell picks up the
   updated PATH; until then, `net.sh` locates them from their standard install locations
   (`C:\Program Files\Go\bin`, `%LOCALAPPDATA%\Microsoft\WinGet\Packages\jqlang.jq_*`) and
   adds them to `PATH` for itself.

2. **No `make` on stock Windows/Git-Bash**, so the native Fabric tool binaries
   (`peer`, `cryptogen`, `configtxgen`, `configtxlator`, `osnadmin`) that
   `network.sh`'s prereq check requires can't be built with `make peer` as documented.
   `net.sh build-tools` replicates the Makefile's build rule directly with
   `go install`, and `net.sh up` runs it automatically if the binaries aren't there yet.

3. **`network.sh up`/`down` need `MSYS_NO_PATHCONV=1`, scoped to exactly those two
   commands.** `network.sh` bind-mounts `${DOCKER_SOCK}` (defaults to
   `/var/run/docker.sock`) into the peer/orderer/vscc containers. Git-Bash's MSYS layer
   rewrites that POSIX path into a Windows path under the Git install directory before
   Docker ever sees it, so volume creation fails with "Access is denied." Setting
   `MSYS_NO_PATHCONV=1` for just the `up`/`down` invocation stops that.

4. **Every other command must run *without* `MSYS_NO_PATHCONV`.** `createChannel`,
   `deployCC`, and `cc invoke`/`cc query` all shell out to native Windows Go binaries
   (`configtxgen.exe`, `peer.exe`, `configtxlator.exe`) that need normal path translation
   to resolve config file paths — with `MSYS_NO_PATHCONV=1` still set, they fail
   immediately with "system cannot find the file specified." `net.sh` explicitly unsets
   it for these.

5. **The chaincode builder image isn't pre-pulled, and its tag doesn't match the
   others.** Chaincode install uses Fabric's low-level Docker API build path, which
   (unlike `docker build`) never auto-pulls a missing base image. `net.sh deploy-cc`
   pulls `npcioss/drunix-ccenv:1.0` first (note: tag `1.0`, not `1.0.0` like the
   orderer/peer/vscc images).

6. **YugabyteDB's cold start can outlast `network.sh`'s fixed 30-second sleep**,
   especially on a first-time init — it can take 2+ minutes for the YSQL layer to accept
   connections. If the peer/orderer/vscc containers start before that, they panic and
   exit once (`connection refused` dialing port 5433). `net.sh up` polls
   `yugabyted status` on both orgs until YSQL reports ready, then restarts any of the
   known race-prone containers that exited, and reports final status.

## `network/net.sh` commands

| Command | What it does |
|---|---|
| `doctor` | Checks Docker, Go, jq, built tool binaries, and the ccenv image; reports what's missing |
| `build-tools` | `go install`s the native Fabric tool binaries (Workaround 2) |
| `up` | Brings the 11-container network up (Workarounds 3, 6) |
| `down` | Tears it down (Workaround 3) |
| `create-channel` | Creates + joins `mychannel` on both orgs (Workaround 4) |
| `deploy-cc` | Pulls the ccenv image and deploys the default sample chaincode (Workarounds 4, 5) |
| `invoke '<json>' [ccname]` | e.g. `invoke '{"Args":["InitLedger"]}'` |
| `query '<json>' [ccname]` | e.g. `query '{"Args":["GetAllAssets"]}'` |
| `status` | Container table + a quick scan of each container's logs for panic/fatal/error |
| `bootstrap` | `up` → `create-channel` → `deploy-cc` |

Run `network/net.sh` with no arguments for the same usage summary.

## Inspecting the state DB directly

Chaincode state lands in YugabyteDB as one schema per channel and one table per
chaincode (confirmed in Phase 0.5 — see `docs/architecture.md`). To look at it directly:

```bash
docker exec -it yugabyte-org1 sh -c \
  "PGPASSWORD=yugabyte ysqlsh -h \$(hostname) -U yugabyte -d yugabyte -c 'select * from mychannel.basic;'"
```

(`-h $(hostname)` is required — connecting via `-h localhost` from *inside* the
container fails; use the container's own hostname or `127.0.0.1` won't resolve
correctly against the YSQL listener in this image.)

## Next

Phase 2 will fill in `chaincode/escrow/`, `gateway/`, and `web/` with actual business
logic. Nothing in those directories yet.
