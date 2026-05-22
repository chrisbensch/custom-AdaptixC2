# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This is a workspace git repo. The four upstream projects of the Adaptix C2 ecosystem live underneath as **git submodules** pinned to specific commits (see `BLUEPRINT.md` §2 for the SHA table). The workspace itself adds a build harness that composes them into one runtime image; each upstream project also still builds independently via its own Makefiles. For the user-facing overview see `README.md`; for the full integration recipe see `BLUEPRINT.md`.

| Directory | What it is |
|---|---|
| `AdaptixC2/` | Submodule. The core framework: Go teamserver + Qt6/C++ GUI client + the default Go-plugin extenders (HTTP/SMB/TCP/DNS beacon listeners, beacon agent, Gopher listener/agent). |
| `Extension-Kit/` | Submodule. The official BOF (Beacon Object File) collection. C/C++ sources cross-compiled with mingw-w64 to `.x64.o`/`.x32.o` artifacts plus AxScript (`.axs`) command wrappers. |
| `Kharon/` | Submodule. Third-party PIC agent + HTTP listener that plugs into Adaptix as additional extenders. Upstream design grafts onto an existing `AdaptixC2/` checkout via `setup_kharon.sh`; in this workspace the `Dockerfile` inlines those same steps at build time. |
| `PostEx-Arsenal/` | Submodule. Standalone BOF + post-ex shellcode collection (`bofs/`, `postex_sc/`) loaded into Adaptix via `kh_modules.axs` (Kharon-flavored commands). |

Authorized red-team / pentest tooling. The `AdaptixC2` `LICENSE` and READMEs make the legal boundary explicit — preserve those notices.

## Build harness (this workspace)

These workspace files compose the integration. They — not the upstream Makefiles — are the canonical entry points for any "build the whole thing" task:

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build, **host-arch by default** (verified arm64 + amd64): `base` (Go 1.25.10 + mingw-w64 + clang/nasm/llvm; `go-win7` pinned via `ARG GO_WIN7_SHA`) → `build-bofs` (Extension-Kit with the nanodump patch applied — 9 BOFs strict, SAL-BOF best-effort because of its network fetch — + PostEx-Arsenal) → `build-server` (server + 9 extenders, including Kharon grafted at build time) → `runtime` (debian-slim with `curl` for HEALTHCHECK, `gosu` for privilege drop, and `libcap2-bin` for `setcap`; unprivileged `adaptix` user UID/GID 10001 created; `setcap cap_net_bind_service=+ep` on `/app/adaptixserver` so listeners can bind `:80/:443/:53` after the UID drop clears caps; entrypoint COPYed from `docker/entrypoint.sh`; `EXPOSE 4321` only; `HEALTHCHECK` probes `https://127.0.0.1:4321/endpoint`). Force a specific arch with `DOCKER_DEFAULT_PLATFORM=linux/amd64`. |
| `docker-compose.yml` | Three profiles: `build` (host-arch), `runtime` (host-networking server with `./data` bind-mount only — no profile bind-mount; profile is rendered into `data/profile.yaml` on first start; **runs with `read_only: true`, `tmpfs:/tmp`, `cap_drop:[ALL]` + `cap_add:[CHOWN, SETUID, SETGID, NET_BIND_SERVICE]`, `security_opt:no-new-privileges`, `mem_limit: 4g` / `pids_limit: 4096` (overridable via `ADAPTIX_MEM_LIMIT` / `ADAPTIX_PIDS_LIMIT`), and a 30 MB bounded JSON log** so the server runs as UID 10001 with a minimal cap set and can't take down the host), `build-client` (Linux AppImage — multi-arch via `ADAPTIX_CLIENT_*` env vars, defaults to `linux/amd64` for backward compatibility). Optional `ADAPTIX_TEAMSERVER_PASSWORD` / `ADAPTIX_OPERATORS` env vars pin credentials at first render. |
| `profile.kharon.yaml` | The server profile **template** baked into the runtime image at `/app/profile.yaml.tmpl`. Diff vs. upstream `AdaptixC2/AdaptixServer/profile.yaml`: adds the two Kharon extenders and the two AxScript module sets (`Extension-Kit/extension-kit.axs`, `PostEx-Arsenal/kh_modules.axs`), replaces literal passwords with `__ADAPTIX_TEAMSERVER_PASSWORD__` and `__ADAPTIX_OPERATORS_BLOCK__` placeholders, points `cert`/`key` at `/app/data/server.rsa.{crt,key}`, trims TLS cipher suites to ECDHE-only (no PFS-less RSA suites), and **replaces the framework-fingerprint 404 headers** (`Server: AdaptixC2`, `Adaptix-Version: v1.2`) with `Server: nginx` only. |
| `docker/404page.html` | Defensive replacement for upstream's `AdaptixC2/AdaptixServer/404page.html` (which renders `<h1>AdaptixC2 404</h1>` and a phrase about "connection details" — both passive-enumeration tells). Ships an nginx-default-shaped page so it pairs with the `Server: nginx` header. COPYed in the Dockerfile runtime stage **after** the upstream dist COPY so it overrides. |
| `docker/entrypoint.sh` | Runtime image's first-start bootstrap. Starts as root so it can `chown root:root /app/data` (the bind mount comes in with the host's ownership; this dance is required because our cap set deliberately omits `DAC_OVERRIDE`), generates a self-signed ECDSA P-256 cert (365-day validity, SAN `DNS:localhost,IP:127.0.0.1` by default; override via `ADAPTIX_TLS_SAN` / `ADAPTIX_TLS_SUBJECT`) into `/app/data/` if missing, renders `/app/profile.yaml.tmpl` → `/app/data/profile.yaml` substituting `ADAPTIX_TEAMSERVER_PASSWORD` and `ADAPTIX_OPERATORS` (env vars or `openssl rand` defaults), and persists the resolved credentials to `/app/data/credentials.txt` (mode 600). Finally `chown -R adaptix:adaptix /app/data` to hand state over, then `exec gosu adaptix "$@"` to launch the server as UID 10001. Subsequent starts reuse the rendered profile — edit `data/profile.yaml` and restart, or `rm` it to re-render. See `BLUEPRINT.md` §5.7. |
| `scripts/` | Host-side helper scripts. All resolve a `REPO_ROOT` one level up from their own location, so they can be invoked from any cwd (`./scripts/<name>` from the repo root is the documented form). New cross-cutting build/dev helpers belong here, not at the workspace root. |
| `scripts/build-client-macos.sh` | Native Apple Silicon `.app` build (Homebrew Qt + macdeployqt + RPATH cleanup + ad-hoc sign). Applies and reverts `patches/adaptixclient-macos-bundle.patch` around the build via `trap`, so the AdaptixC2 submodule tree stays clean. |
| `scripts/build-client-linux.sh` | Wrapper around the `build-client` compose profile. `cd`s into `$REPO_ROOT` before invoking compose so the workspace `docker-compose.yml` resolves its relative paths. Applies `patches/adaptixclient-kali-arm64-stage.patch` (auto-revert via `trap`) so the submodule stays clean, then drives one of two Dockerfile stages depending on `--arch`: amd64 → original `build-client` (ubuntu:22.04 + aqtinstall Qt 6.9.2 + linuxdeployqt), arm64 → new `build-client-kali` (kalilinux/kali-rolling + distro Qt 6.10.2 + linuxdeploy + linuxdeploy-plugin-qt). The arm64 path exists because aqtinstall publishes no Linux aarch64 Qt binaries through 6.11.x; Kali's distro Qt6 fills the gap. `--arch host\|amd64\|arm64` (default: host). Output: `AdaptixClient-{x86_64,aarch64}.AppImage` in `./AdaptixClient-dist/`. Host != target runs under QEMU. `--clean` wipes the dist dir; layer cache is preserved. |
| `scripts/install-prereqs-windows.ps1` | Windows prerequisite installer. Installs MSYS2 and Git for Windows via winget, runs the two-pass pacman update, and installs all MinGW64 packages (toolchain, Qt6, OpenSSL, CMake, Ninja) required by `AdaptixC2/AdaptixClient/build.bat`. Run once per machine from an elevated PowerShell prompt at the repo root (`powershell -ExecutionPolicy Bypass -File scripts\install-prereqs-windows.ps1`) before building the Windows client. See `BLUEPRINT.md` §11. |
| `patches/` | Build-time patches against submodule trees. We don't own the upstream repos, so persistent customizations live here as unified diffs and are applied/reverted by the relevant build step. Currently: `adaptixclient-macos-bundle.patch` (macOS bundle CMake block, applied on host with auto-revert by `scripts/build-client-macos.sh`), `adaptixclient-kali-arm64-stage.patch` (adds a `build-client-kali` Dockerfile stage that builds the Linux client from kalilinux/kali-rolling + distro Qt6 for arm64; original `build-client` stage is unchanged, so amd64 builds are byte-equivalent to upstream; applied on host with auto-revert by `scripts/build-client-linux.sh`), and `extension-kit-nanodump-host-strip.patch` (nanodump host-arch strip fix, applied inside the build container). |
| `.dockerignore` | Excludes `**/.git` and `**/.gitmodules` from the build context. Load-bearing — without it, submodule `.git` pointer files leak into the build and break in-container `git apply` with `not a git repository`. |
| `.github/workflows/build.yml` | CI: builds the runtime image on `ubuntu-latest` (amd64) and `ubuntu-24.04-arm` (arm64) for every PR, every push to `main`, and a weekly cron (Mondays 06:17 UTC). Smoke-tests the image with the same hardened posture compose enforces (read-only rootfs, `cap_drop:ALL` + the four cap-adds, `no-new-privileges`), waits for the HEALTHCHECK to report healthy, then asserts PID 1 is running as UID 10001 (catches a dropped `exec gosu` in the entrypoint) and that the 404 page + rendered profile don't carry framework-identifying strings. **Trivy scan blocks `CRITICAL`/`HIGH` CVEs (`ignore-unfixed: true`); CycloneDX SBOM uploaded as a per-arch workflow artifact.** Catches upstream submodule drift, Dockerfile regressions, fingerprint-leak reverts, and base-image CVE drift early. See `BLUEPRINT.md` §12. |
| `LICENSE` | MIT license for the build harness only. Submodule contents remain under their respective upstream licenses (preserve those notices). |
| `BLUEPRINT.md` | Exhaustive integration recipe: every Dockerfile stage, every patch, every gotcha, the upstream-refresh flow, and the verification checklist. **Read this before changing the build.** |
| `README.md` | User-facing project overview and quick start. |

When changing the integrated build, edit harness files; do not commit modifications inside any submodule tree (see "Cross-cutting conventions" below).

**Runtime credentials.** The image ships with **no built-in passwords**. On first start the entrypoint either honors `ADAPTIX_TEAMSERVER_PASSWORD` / `ADAPTIX_OPERATORS` env vars or generates random ones and writes them to `./data/credentials.txt` (mode 600). Treat that file like a secret. To rotate, edit `./data/profile.yaml` and restart, or wipe `./data/` and re-launch with the env vars set.

## AdaptixC2 — build & run

All commands run from `AdaptixC2/`. The top-level `Makefile` orchestrates three artifacts:

```bash
# One-shot dev build (clean + server + client + extenders → ./dist/)
make all

# Pieces
make server              # Go teamserver only
make extenders           # All Go-plugin .so extenders only
make client              # Qt6 GUI (single-threaded cmake build)
make client-fast         # Qt6 GUI (parallel, uses nproc)
make server-ext          # server + extenders (no client) — typical VPS build

# Cleanup
make clean               # remove ./dist
make clean-all           # also remove *.o/*.so/*.a/build_error.log/cmake_error.log
make help                # full target list
```

System prerequisites are installed by `./pre_install_linux_all.sh <server|client|all>` (apt-only; pins **Go 1.25.4** and clones `Adaptix-Framework/go-win7` into `/usr/lib/go-win7` for Win7-compatible Gopher Agent builds). Server/extender builds set `GOEXPERIMENT=jsonv2,greenteagc` — keep that flag if invoking `go build` directly.

### Run the server

```bash
cd dist
./ssl_gen.sh                                  # generate server.rsa.crt / server.rsa.key
./adaptixserver -profile profile.yaml [-debug]
```

`profile.yaml` (copied into `dist/` by `make server`) is the only config: it lists operator credentials, the bind interface/port (default `0.0.0.0:4321/endpoint`), TLS cert paths, the set of extender `config.yaml`s to load, and any AxScript files to auto-load. `make` does **not** create the certs — `ssl_gen.sh` must run before first launch (the runtime Docker image does this automatically in its entrypoint).

### Docker workflow

```bash
make docker-build-server-ext     # build server+extenders inside container, output -> AdaptixServer/server-dist/
make docker-build-client         # build Linux AppImage, output -> AdaptixClient/client-dist/
make docker-up                   # run server runtime container (auto-generates certs on first start)
make docker-logs                 # follow logs
make docker-down                 # stop
make docker-clean-all            # nuke every Docker artifact incl. server-dist/
```

Compose profiles (`build-server`, `build-extenders`, `build-server-ext`, `build-client`, `runtime`) gate which services run; the Makefile wraps them. Runtime container uses `network_mode: host` and mounts `AdaptixServer/server-dist/profile.yaml` read-only and `server-dist/data/` for state.

### Tests

There is no test target and no `_test.go` files in the server. Treat changes as integration-tested by running the server + connecting a client.

## AdaptixC2 — architecture

**Process model.** Three independently built binaries:

1. **AdaptixServer** (Go) — one teamserver process. `main.go` parses `-profile`, instantiates a `Teamserver` (`core/server/server.go`), then calls `ts.Start()`. The teamserver opens an HTTPS+WebSocket listener on the configured endpoint via `core/connector/`, registers Gin route handlers (`core/server/ts_endpoints.go`), restores agents/listeners/pivots from SQLite, and loops.
2. **AdaptixClient** (Qt6/C++23) — operator GUI. Connects via WebSocket; receives sync packets (`SpAgent*`, `SpListener*`, etc.) and renders sessions, listeners, downloads, screenshots, terminal, file/process browsers, credentials, targets, chat, and a sessions graph. Build is CMake-driven and pulls vendored `kddockwidgets`, `qlementine`, and `Konsole` from `AdaptixClient/Libs/`.
3. **Extenders** (Go plugins, `.so`) — listeners and agents loaded at runtime via `plugin.Open` (`core/extender/`). Each lives in `AdaptixServer/extenders/<name>/`, has its own `go.mod`, a `config.yaml`, an optional `ax_config.axs` UI script, and a `Makefile` invoking `go build -buildmode=plugin -ldflags="-s -w" ...`. The Go workspace (`go.work`) `use`s every extender so a single `go build` resolves cross-module dependencies. **When adding a new extender, also `go work use ./extenders/<name>`** — `setup_kharon.sh` does this automatically for Kharon.

**Plugin API.** Extender ↔ teamserver contract is the external `github.com/Adaptix-Framework/axc2` package. Every listener plugin exports `InitPlugin(ts any, moduleDir, listenerDir string) adaptix.PluginListener` and implements `Create / Start / Edit / Stop / GetProfile / InternalHandler`. Agents export an analogous interface. The teamserver injects itself as an `interface` (only the methods the plugin needs — see e.g. `Teamserver` interface in `extenders/beacon_listener_http/pl_main.go`). **Never import internal teamserver types from a plugin** — go through `axc2`.

**Server core layout** (`AdaptixServer/core/`):

- `server/` — the `Teamserver` struct and all `ts_*.go` domain methods (one file per concern: `ts_agent.go`, `ts_listeners.go`, `ts_tunnels.go`, `ts_screenshots.go`, etc.) plus managers: `mgr_broker.go` (event broker), `mgr_task.go` (task manager), `mgr_tunnel.go`, `mgr_handler_*.go`. `ts_syncpacket.go` builds the `SpXxx` packets shipped to clients.
- `connector/` — the HTTP/WS handler. `tc_*.go` files are the per-resource Gin handlers (auth, agents, listeners, tunnels, downloads, creds, screenshot, chat, targets, OTP, axscript).
- `extender/` — plugin loader. `ex_listener.go`, `ex_agent.go`, `ex_service.go` are the typed wrappers around loaded `.so`s.
- `database/` — SQLite via `mattn/go-sqlite3`. `db_*.go` per table: agents, listeners, tasks, downloads, screenshots, creds, targets, pivots, chat, consoles. Restored on startup by `Teamserver.RestoreData()`.
- `axscript/` — embedded JS engine (`dop251/goja`) exposing the `ax.*` bridge to operator scripts. `bridge_*.go` exposes commands/events/packing/IPC; `manager.go` loads scripts from profile + client. The same engine runs server-side; the client has its own (`AdaptixClient/Source/Client/AxScript/`) for UI extensions.
- `eventing/` — internal pub/sub used by the broker.
- `profile/` — YAML profile parsing/validation.
- `utils/` — `logs/` (file + stdout), `token/` (JWT, OTP), `safe/` (`safe.Map`, `safe.Slice`, `safe.SafeQueue` — used everywhere instead of mutex-protected maps), `krb5/`.

**Persistence.** SQLite file path comes from `logs.RepoLogsInstance.DbPath`. The `RestoreData()` flow on startup re-hydrates agents (with their hosted task/tunnel queues), pivots, and listeners (re-calls `TsListenerStart` and re-applies "Paused" status). Agents marked `Terminated` come back inactive.

**Sync model.** Mutating server operations call `TsSyncAllClients(packet)` to push a sync packet to every connected client. The client's `WebSocketWorker` dispatches by packet type to widget-level update methods.

**AxScript.** Two surfaces: server scripts (validated in profile, run in the goja engine for command pre-hooks, packing helpers, etc.) and client scripts (loaded via `Script Manager` in the GUI, wrap commands/menus/forms). The client engine lives in `AdaptixClient/Source/Client/AxScript/` (`AxScriptManager`, `AxScriptEngine`, `BridgeApp/Event/Form/Menu`, `AxCommandWrappers`, `AxElementWrappers`). When wiring a new BOF UI, the convention is a `*.axs` script that calls `ax.create_command`, `addArgFlag*`, and `setPreHook(...)` to translate args → `bof_pack` → `execute bof <path> <packed>` (see `PostEx-Arsenal/kh_modules.axs` and `Extension-Kit/*/*.axs` for canonical examples).

### Beacon agent build (the most involved piece)

`extenders/beacon_agent/` builds two things from one `make`:

1. The Go plugin (`agent_beacon.so`) — server-side payload generator/handler.
2. Four Windows beacon variants (`objects_http/`, `objects_smb/`, `objects_tcp/`, `objects_dns/`) — C++ object files cross-compiled with `x86_64-w64-mingw32-g++` and `i686-w64-mingw32-g++` from `src_beacon/beacon/*.cpp`. Each transport gets `-D BEACON_HTTP|SMB|TCP|DNS` and three build modes (`-D BUILD_SVC|BUILD_DLL|BUILD_SHELLCODE`) for x64 and x86. The `src_beacon/Makefile` parallelizes via `-j$(nproc)` and trims `miniz` (`-DMINIZ_NO_STDIO`...) to drop CRT deps. The `.o`s are not linked here — the server's `agent_beacon` plugin links them at payload-generation time using a `config.cpp` template (`src_beacon/files/config.tpl`) that gets per-build values patched in.

When touching beacon C++ code, run `make` inside `extenders/beacon_agent/src_beacon/` for fast iteration; the outer Makefile wraps it.

## Extension-Kit — build BOFs

Run from `Extension-Kit/`. Two parallel build systems exist:

```bash
make                  # canonical: recurses into every BOF subdir, drops .x64.o/.x32.o into <subdir>/_bin/
make clean
make docker-build     # build all BOFs inside the bundled Debian container

# CMake (newer alternative)
cmake -B build && cmake --build build --target build-all-bofs
cmake --build build --target clean-all-bins
```

Both paths require **mingw-w64** (`x86_64-w64-mingw32-gcc`/`g++`, `i686-w64-mingw32-gcc`/`g++`, optional posix variant). On Ubuntu/Kali: `apt install g++-mingw-w64-x86-64-posix gcc-mingw-w64-x86-64-posix mingw-w64-tools`.

`SAL-BOF/Makefile` runs `python3 ./privcheck/download_vulnerable_driver_list.py` during build — it touches the network. Skip that target offline.

Each subdir (`AD-BOF`, `Creds-BOF`, `Elevation-BOF`, `Execution-BOF`, `Injection-BOF`, `LateralMovement-BOF`, `Postex-BOF`, `Process-BOF`, `SAL-BOF`, `SAR-BOF`) has a sibling `*.axs` that registers the commands; `extension-kit.axs` is the umbrella that `script_load`s all of them. Load `extension-kit.axs` via the client's **AxScript → Script manager → Load new** to pick up everything.

`add_agent.sh <agent_name>` patches every `register_commands_group` in every `.axs` so a new agent type is registered alongside `"beacon"` and `"gopher"`.

Headers in `_include/` (`adaptix.h`, `beacon.h`, `bofdefs.h`) are shared by every BOF — changes to them ripple across the kit.

## Kharon — install as Adaptix extenders

Kharon is **not standalone**; it grafts onto an existing `AdaptixC2/` tree. After `apt install nasm clang llvm`, run from `Kharon/`:

```bash
./setup_kharon.sh --ax /path/to/AdaptixC2 [--action all|agent-full|agent-modules|agent-code|listener] [--pull]
```

The script (1) copies `agent_kharon/` and `listener_kharon_http/` to `AdaptixC2/AdaptixServer/extenders/`, (2) `go work use`s them and `go work sync`s, (3) builds via the per-extender `Makefile`s, and (4) stages outputs into `AdaptixC2/dist/extenders/`. After install, add the two new lines to `AdaptixC2/AdaptixServer/profile.yaml` `extenders:` list (`extenders/agent_kharon/config.yaml` and `extenders/listener_kharon_http/config.yaml`) — `setup_kharon.sh` does **not** edit the profile.

`agent_kharon/` is split into `src_server/` (Go plugin), `src_loader/` (PIC loader), `src_core/` (BOF API proxy + injection kit), `src_beacon/` (the PIC beacon itself with stack spoofing/indirect syscalls/sleep mask). The agent Makefile builds plugin + beacon; `src_beacon/Makefile` is invoked with `prebuild-x64`. See `Kharon/doc/{2.Setup,3.Build,6.Dev}.md` for build flags, custom-loader hooks, and obfuscation internals before changing `src_beacon/Source/Evasion/MemObf.cc` or `Source/Evasion/Spoof.cc`.

## PostEx-Arsenal — Kharon-flavored modules

```bash
cd PostEx-Arsenal/bofs
make           # cross-compiles every .cc under active_script/, az/, dotnet_list/, lateralmov/, stealer/ → bofs/dist/*.x64.o
make clean
```

`include/` is the shared header set. `postex_sc/` (dotnet_ldr, keylogger, reflection, template) holds raw shellcode-style post-ex payloads with their own per-folder build setup.

`kh_modules.axs` is the entry script — load it via the client's AxScript manager. It defines composite commands (`remote-exec winrm/wmi/scm/dcom`, `dotnet listversions/inline`, etc.) whose pre-hooks `ax.bof_pack` arguments and dispatch to `bofs/dist/<name>.<arch>.o` via `execute bof`. This module set targets the **Kharon** agent type (note the script name); when adapting for `beacon` or `gopher`, register the agent name in the relevant `register_commands_group` calls (or use `Extension-Kit/add_agent.sh`).

## Cross-cutting conventions

- **Go version pin.** Two paths diverge intentionally: the **Docker pipeline** uses `golang:1.25.10-bookworm@sha256:154bd70…` (bumped reactively when Trivy in CI flags a Go-stdlib CVE); the **upstream native installer** `pre_install_linux_all.sh` still pins **1.25.4**. Within 1.25.x is in-policy per BLUEPRINT §3 — bump the Docker pin when CI tells you to. `GOEXPERIMENT=jsonv2,greenteagc` for both paths. The native installer wipes `/usr/local/go` and reinstalls — be aware on shared machines.
- **Cross-compilation only (server artifacts).** All Windows C++ payloads (beacon, Gopher agent, BOFs) are cross-compiled on Linux/macOS via mingw-w64 (`x86_64-w64-mingw32-*`, `i686-w64-mingw32-*`). There is no MSVC build path for these. Exception: the **Windows GUI client** (`AdaptixClient`) is built natively on a Windows machine using MSYS2 + MinGW64 — see `BLUEPRINT.md` §11 and `scripts/install-prereqs-windows.ps1`.
- **Plugin contract = `axc2` package.** Don't reach into teamserver internals from an extender; the plugin can only see what the typed `Teamserver` interface in its own `pl_main.go` declares.
- **`go.work` is authoritative.** Adding/removing an extender requires `go work use` / removing the entry — `setup_kharon.sh` is the reference.
- **Profile-driven.** Server behavior (which extenders, which scripts, who can log in) lives entirely in `profile.yaml`. Restart the server to apply profile changes; there is no hot-reload.
- **AxScript bridges (`ax.*`)** are stable across server and client engines. `script_dir()`, `arch(id)`, `bof_pack(fmt, args)`, `execute_alias(id, cmdline, real_cmd, msg)`, `create_command/addArgFlag*/setPreHook` are the building blocks every BOF wrapper uses.
- **Dev branch.** Both `AdaptixC2` and `Extension-Kit` READMEs ask contributors to push to `dev`, not `main`.
- **Don't commit inside submodule trees.** The four upstream repos are git submodules pinned to specific SHAs — we don't own those repos. Persistent customizations go in `patches/` (unified diffs applied at build time and reverted on exit) or are made Dockerfile-side at COPY time. To bump a submodule: `cd <submod> && git fetch && git checkout <new-sha> && cd .. && git -C <submod> apply --check patches/...patch && git add <submod> && git commit`. See `BLUEPRINT.md` §6 (patch catalog) and §10 (full upgrade flow).
