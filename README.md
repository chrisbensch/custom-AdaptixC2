# AdaptixC2-Omni

A reproducible, pinned, single-command build of the [AdaptixC2](https://github.com/Adaptix-Framework/AdaptixC2) framework integrated with [Kharon](https://github.com/entropy-z/Kharon), the [Extension-Kit BOF collection](https://github.com/Adaptix-Framework/Extension-Kit), and the [PostEx-Arsenal modules](https://github.com/entropy-z/PostEx-Arsenal) — packaged as one Dockerized server image plus Linux and macOS GUI clients.

Originally bootstrapped from Mitchell's [AdaptixC2 + Kharon installation guide](https://mitchells-journal.gitbook.io/writings/adaptixc2-and-nakasendo/0.1.-adaptixc2-and-kharon-installation-guide); this repo replaces the manual setup with a checked-in, version-pinned build harness so the same artifact can be reproduced anywhere with one clone + one build.

This repository **does not fork** any upstream project. It tracks the four upstream repos as git submodules pinned to specific commits, builds them together via a unified `Dockerfile`, and applies a single small build-time patch from `patches/` so submodule trees stay clean. The intent is: clone, build, run — and reproduce the exact same artifact on any machine, today or in six months.

> **Authorized use only.** AdaptixC2, Kharon, and the BOF/post-ex modules included here are red-team and adversary-emulation tooling. Use them only against systems you own or are explicitly authorized to test. Upstream license terms (see each submodule's `LICENSE`) apply to that code.

---

## What this gets you

A single `docker compose build` produces a runtime image containing:

- **AdaptixC2 teamserver** (Go) at the pinned upstream commit.
- **Nine extender plugins** built and ready to load:
  - 4 default Adaptix beacon listeners (HTTP, SMB, TCP, DNS) + the beacon agent
  - The Adaptix Gopher TCP listener + Gopher agent
  - **Kharon** PIC agent + Kharon HTTP listener
- **BOF + post-ex artifacts** pre-built into the image:
  - All [Extension-Kit](https://github.com/Adaptix-Framework/Extension-Kit) BOFs (`AD-BOF`, `Creds-BOF`, `Elevation-BOF`, `Execution-BOF`, `Injection-BOF`, `LateralMovement-BOF`, `Postex-BOF`, `Process-BOF`, `SAL-BOF`, `SAR-BOF`)
  - All [PostEx-Arsenal](https://github.com/entropy-z/PostEx-Arsenal) BOFs and shellcode under `bofs/dist/` and `postex_sc/`
- **Profile pre-merged** (`profile.kharon.yaml`) so all 9 extenders register on first start and both AxScript module sets (`extension-kit.axs`, `kh_modules.axs`) auto-load.
- **TLS auto-bootstrap** — the entrypoint generates a self-signed ECDSA P-256 cert (365-day validity, SAN from `ADAPTIX_TLS_SAN` env var or `DNS:localhost,IP:127.0.0.1` default) on first run; persistent state lives in `./data/` via a bind-mount.
- **Hardened runtime posture** — server runs as unprivileged UID 10001 with a read-only rootfs, `cap_drop:[ALL]` plus the four caps it actually needs (`CHOWN`, `SETUID`, `SETGID`, `NET_BIND_SERVICE`), `no-new-privileges`, mem/PID/log-size limits, ECDHE-only TLS suites, and an nginx-decoy 404 page so passive enumeration can't fingerprint the framework. Trivy + CycloneDX SBOM run in CI. Full breakdown in [BLUEPRINT.md §5 / §12](./BLUEPRINT.md).

Plus separate workflows for the GUI clients:

- **Linux AppImage** (x86_64) built inside a Docker container — reuses the upstream `build-client` Dockerfile stage, no duplication.
- **macOS .app bundle** (Apple Silicon / arm64) built natively via Homebrew Qt, with portable RPATHs and ad-hoc signing — Adaptix does not ship an official macOS build.
- **Windows exe** (x86_64) built natively on a Windows machine using MSYS2 + MinGW64; `scripts/install-prereqs-windows.ps1` automates the prerequisite setup.

---

## Quick start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/chrisbensch/AdaptixC2-Omni.git
cd AdaptixC2-Omni
```

If you forgot `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Build & run the server

Requires Docker Desktop, OrbStack, or any Docker engine. The image builds for the host architecture by default — verified working on both `linux/arm64` and `linux/amd64`.

```bash
# Build the server image, host-arch
#   ≈6 min native on Apple Silicon (arm64)
#   ≈12 min native on amd64
#   273–288 MB depending on arch
docker compose --profile build build

# Force amd64 from an arm64 host (uses QEMU; ≈13 min) — useful when targeting
# an x86_64 server for deployment.
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose --profile build build

# Run it (host networking; SQLite state persisted to ./data/)
docker compose --profile runtime up -d
docker compose --profile runtime logs -f

# Stop
docker compose --profile runtime down
```

On first start the entrypoint generates random teamserver credentials and writes them to `./data/credentials.txt` (mode 600). The container log prints only a render confirmation — the password itself is never echoed, so `docker logs` can't be used to recover the credential after the fact. Read `./data/credentials.txt` instead. To set your own values instead of the random defaults, export them before the first `up`:

```bash
export ADAPTIX_TEAMSERVER_PASSWORD='your-strong-password'
export ADAPTIX_OPERATORS='operator1:secret1,operator2:secret2'
docker compose --profile runtime up -d
```

The rendered profile lives at `./data/profile.yaml` and is reused on subsequent starts. To rotate credentials or change other settings, edit that file and run `docker compose --profile runtime restart`. The committed [`profile.kharon.yaml`](./profile.kharon.yaml) is the *template* used at first render; editing it after first start has no effect — delete `./data/profile.yaml` and restart to re-render from the template.

The TLS cert generated on first start is ECDSA P-256, 365-day validity, with `subjectAltName=DNS:localhost,IP:127.0.0.1`. For a real deployment, override before the first `up`:

```bash
export ADAPTIX_TLS_SAN='DNS:c2.example.com,IP:10.0.0.5'   # openssl SAN format
export ADAPTIX_TLS_SUBJECT='/CN=c2.example.com'           # optional; overrides issuer DN
docker compose --profile runtime up -d
```

To rotate the cert later, `rm ./data/server.rsa.crt ./data/server.rsa.key` and restart (env vars get re-read). The `.rsa.` in the filenames is historical — the cert is ECDSA.

The server runs as an unprivileged user (UID/GID 10001, `adaptix`) inside the container with a read-only rootfs, only the four capabilities it actually needs (`CHOWN`, `SETUID`, `SETGID`, `NET_BIND_SERVICE`), and `no-new-privileges`. Files written by the entrypoint into `./data/` end up owned by UID 10001 on the host — if you need to read them as your shell user, `sudo chown -R "$USER" ./data` or just `sudo cat ./data/credentials.txt`.

### 3. Build a client

**Linux AppImage (amd64 or arm64):**

```bash
./scripts/build-client-linux.sh                  # host arch (amd64 or arm64)
./scripts/build-client-linux.sh --arch amd64     # force x86_64 (Qt 6.9.2 via ubuntu:22.04 + aqtinstall)
./scripts/build-client-linux.sh --arch arm64     # force aarch64 (Qt 6.10.2 via kali-rolling + distro packages)
# → AdaptixClient-dist/AdaptixClient-{x86_64,aarch64}.AppImage
```

amd64 builds use the upstream `build-client` Dockerfile stage as-is. arm64 builds use a new `build-client-kali` stage (added by `patches/adaptixclient-kali-arm64-stage.patch`, auto-reverted on script exit) — aqtinstall has no aarch64 Qt binaries through 6.11.x, so Kali's distro Qt6 fills the gap.

**macOS Apple Silicon `.app`:**

```bash
# Prerequisites: Homebrew with cmake, qt@6, openssl@3
brew install cmake qt@6 openssl@3

./scripts/build-client-macos.sh           # plain build
./scripts/build-client-macos.sh --clean   # wipe build dir first
./scripts/build-client-macos.sh --dmg     # also produce a .dmg
# → AdaptixClient-dist/AdaptixClient.app  (~118 MB, arm64-only)
```

The script applies the macOS-bundle patch on entry, builds, fixes RPATHs for portability, ad-hoc signs the bundle, and reverts the patch on exit so the AdaptixC2 submodule tree stays clean.

**Windows x86_64 (native build on a Windows machine):**

```powershell
# Step 1 — install prerequisites (once per machine, from an Administrator PowerShell):
powershell -ExecutionPolicy Bypass -File scripts\install-prereqs-windows.ps1
# Installs MSYS2 + Git via winget, then all MinGW64 packages (~2 GB, 5-15 min).

# Step 2 — build (from a standard cmd.exe prompt, not PowerShell):
cd AdaptixC2\AdaptixClient
build.bat
# → dist\AdaptixClient.exe + bundled DLLs
```

The upstream build uses **MSYS2 + MinGW64 + Ninja** — Visual Studio / MSVC is not required. See [BLUEPRINT.md §11](./BLUEPRINT.md) for the complete prerequisites, per-step explanation, DLL reference table, and all Windows-specific gotchas (including the ICU version-bump issue and the `windeployqt` PATH requirement).

**Windows x86_64 (containerized build, host stays clean):**

```powershell
# Requires Docker Desktop in Windows container mode.
.\scripts\build-client-windows-container.ps1

# Or let the script ask Docker Desktop to switch from Linux containers first.
.\scripts\build-client-windows-container.ps1 -SwitchToWindowsEngine
# → AdaptixClient-dist\windows\AdaptixClient.exe + deployed DLLs/plugins
```

This path installs MSYS2 and Qt inside a Windows Server Core build image rather than on your workstation. Docker Desktop's engine switch is global: while in Windows container mode, Linux-container workflows like the server image build are unavailable until you switch back.

### 4. Connect

Point the client at `https://<server-host>:4321/endpoint` and log in. The listener-creation dialog will show all nine extenders; the AxScript Manager shows `extension-kit.axs` and `kh_modules.axs` already loaded.

---

## Repository layout

```
AdaptixC2-Omni/
├── AdaptixC2/            ← submodule: Adaptix-Framework/AdaptixC2  (server + Qt6 client)
├── Extension-Kit/        ← submodule: Adaptix-Framework/Extension-Kit  (BOFs)
├── Kharon/               ← submodule: entropy-z/Kharon  (PIC agent + HTTP listener)
├── PostEx-Arsenal/       ← submodule: entropy-z/PostEx-Arsenal  (Kharon-flavored modules)
│
├── Dockerfile            ← unified server build (multi-stage, host-arch by default)
├── docker-compose.yml    ← profiles: build / runtime / build-client
├── profile.kharon.yaml   ← merged server profile, 9 extenders + 2 axscripts
├── scripts/              ← host-side build helpers
│   ├── build-client-linux.sh        ← Linux AppImage build (amd64 + arm64 via Docker)
│   ├── build-client-macos.sh        ← native macOS .app build (Apple Silicon arm64)
│   ├── build-client-windows-container.ps1 ← Windows exe build via Windows container
│   └── install-prereqs-windows.ps1  ← Windows prerequisite installer (MSYS2 + MinGW64 + Qt6)
├── docker/
│   ├── entrypoint.sh                ← first-start bootstrap (TLS cert, profile render, drop to UID 10001)
│   ├── 404page.html                 ← defensive nginx-shaped 404 (overrides upstream's framework-branded page)
│   └── Dockerfile.windows-client    ← Windows Server Core + MSYS2 client build image
├── patches/              ← build-time patches against submodules
│   ├── adaptixclient-macos-bundle.patch
│   ├── adaptixclient-kali-arm64-stage.patch
│   └── extension-kit-nanodump-host-strip.patch
├── .dockerignore         ← excludes submodule .git pointer files from build context
│
├── BLUEPRINT.md          ← detailed integration recipe (read this when refreshing or debugging)
├── CLAUDE.md             ← context file for AI coding assistants
├── README.md             ← you are here
│
├── data/                 ← runtime state (gitignored; bind-mounted into the server container)
└── AdaptixClient-dist/   ← client build outputs (gitignored)
```

The four submodules contain the actual upstream source. Your clone of *this* repo is small (under 1 MB) and contains only the build harness; submodule contents are pulled from the canonical upstream remotes at clone time.

---

## What's customized vs. upstream

Every customization is either a workspace-root file we authored or a tracked patch — no upstream tree carries committed modifications.

| Customization | Lives in | Why |
|---|---|---|
| Unified server Dockerfile | `Dockerfile` | Single image with server + 9 extenders + BOFs + axscripts; one build, one artifact. |
| Compose orchestration | `docker-compose.yml` | Three profiles (`build`, `runtime`, `build-client`) covering the full lifecycle. |
| Kharon + AxScripts wired into server profile | `profile.kharon.yaml` | Adds the two Kharon extenders and the two AxScript module sets to the upstream default profile. Also strips the framework-fingerprint 404 headers (`Server: AdaptixC2`, `Adaptix-Version: v1.2`) for a `Server: nginx` decoy. |
| First-start bootstrap entrypoint | `docker/entrypoint.sh` | Renders the profile template, generates the TLS cert, persists credentials, then drops privileges to UID 10001 via `gosu`. Replaces the upstream inline cert-only entrypoint. |
| Defensive 404 page | `docker/404page.html` | Overrides upstream's `<h1>AdaptixC2 404</h1>` page with an nginx-default-shaped body that matches the `Server: nginx` header decoy. COPYed in the Dockerfile after the upstream dist COPY. |
| macOS bundle CMake additions | `patches/adaptixclient-macos-bundle.patch` | Upstream `AdaptixClient/CMakeLists.txt` doesn't set `MACOSX_BUNDLE`, so a plain `make` produces a bare exe. The patch adds an `if(APPLE)` block setting bundle properties; `scripts/build-client-macos.sh` applies and reverts it around each build. |
| nanodump host-strip fix | `patches/extension-kit-nanodump-host-strip.patch` | Upstream nanodump strips its host-built `restore_signature` ELF with the Windows cross-strip, which breaks on arm64 hosts. The patch deletes the redundant strip line; `gcc -s` on the prior line already strips it. Applied inside the build container by the Dockerfile. |
| arm64 client build via kali-rolling | `patches/adaptixclient-kali-arm64-stage.patch` | aqtinstall publishes no Linux aarch64 Qt binaries through 6.11.x, so the upstream `build-client` Dockerfile stage can't target arm64. The patch appends a new `build-client-kali` stage that uses kali-rolling's distro Qt 6.10.2 + `linuxdeploy` instead. Purely additive — the original `build-client` stage is unchanged, so amd64 builds are byte-equivalent to upstream. Applied on the host by `scripts/build-client-linux.sh` with auto-revert. |
| macOS native build script | `scripts/build-client-macos.sh` | macdeployqt + RPATH cleanup + ad-hoc signing — required to produce a portable Apple Silicon `.app` that launches outside the build host. |
| Windows prerequisite installer | `scripts/install-prereqs-windows.ps1` | Automates the one-time setup of MSYS2, MinGW64 toolchain, Qt6, OpenSSL, CMake, and Ninja needed by `build.bat` on a Windows machine. |
| Kharon graft inside the build | (Dockerfile-only, no source-tree change) | The Dockerfile copies `Kharon/agent_kharon` and `Kharon/listener_kharon_http` into `AdaptixServer/extenders/` and runs `go work use` *inside* the container, mirroring what `Kharon/setup_kharon.sh` does — but only inside the build, never on the host tree. |
| Build-context hygiene | `.dockerignore` | Excludes `**/.git` so submodule `.git` pointer files (which reference paths outside the build context) don't break in-container `git apply`. |

See [BLUEPRINT.md §6](./BLUEPRINT.md) for the full diff and rationale of every patch.

---

## Pinned upstream commits

The submodules are locked to these SHAs:

| Submodule | Source | Commit | Date |
|---|---|---|---|
| AdaptixC2 | [Adaptix-Framework/AdaptixC2](https://github.com/Adaptix-Framework/AdaptixC2) | `a4b80bf` (v1.1, dev-v1.2 merged) | 2026-03-04 |
| Extension-Kit | [Adaptix-Framework/Extension-Kit](https://github.com/Adaptix-Framework/Extension-Kit) | `9413caf` | 2026-02-28 |
| Kharon | [entropy-z/Kharon](https://github.com/entropy-z/Kharon) | `699ece7` | 2026-04-02 |
| PostEx-Arsenal | [entropy-z/PostEx-Arsenal](https://github.com/entropy-z/PostEx-Arsenal) | `e169261` | 2026-03-13 |

Plus one upstream that's pulled in during the Docker build (not a submodule, pinned via `ARG` in the Dockerfile):

| Build-time dep | Source | Commit |
|---|---|---|
| go-win7 | [Adaptix-Framework/go-win7](https://github.com/Adaptix-Framework/go-win7) | `15ad42b` |

Bumping any submodule is a single submodule-bump commit (see below). Bumping `go-win7` is a one-line edit to the `GO_WIN7_SHA` ARG in [`Dockerfile`](./Dockerfile).

---

## Refreshing against newer upstream

When upstream moves and you want to pull in their changes:

```bash
cd AdaptixC2
git fetch origin
git checkout <new-tag-or-sha>
cd ..

# Confirm our patch still applies cleanly to the new tree
git -C AdaptixC2 apply --check patches/adaptixclient-macos-bundle.patch

# Commit the bump
git add AdaptixC2
git commit -m "Bump AdaptixC2 to <new-tag>"
```

If `git apply --check` fails, the upstream `CMakeLists.txt` has drifted into the patch's hunks; regenerate it manually per [BLUEPRINT.md §10](./BLUEPRINT.md). Repeat the same flow for the other three submodules. For full diff-check guidance (profile merges, Dockerfile inheritance, toolchain dep changes), follow the §10 upgrade path in BLUEPRINT.md end-to-end.

---

## Architecture in one paragraph

AdaptixC2 splits into three independently-built pieces: a Go **teamserver** (one process, SQLite-backed, HTTPS+WebSocket on `:4321/endpoint`), a Qt6/C++ **GUI client** (operator UI, connects via WebSocket and renders sync packets), and a set of **extender Go-plugins** (`.so` files loaded at runtime — every listener and every agent type is a plugin). The teamserver–extender contract is the [`axc2`](https://github.com/Adaptix-Framework/axc2) package; plugins never reach into teamserver internals. Operator behavior is scriptable via **AxScript** (a `goja`-embedded JS engine, both server- and client-side) — that's how BOFs are wrapped into operator commands and how the Kharon and Extension-Kit module sets register their UI. See [CLAUDE.md](./CLAUDE.md) for a deeper architectural tour written for AI coding assistants.

---

## Further reading

- **[BLUEPRINT.md](./BLUEPRINT.md)** — exhaustive integration recipe: every Dockerfile stage explained, every patch's diff, every gotcha encountered during the build, the upstream-refresh flow, and the verification checklist.
- **[CLAUDE.md](./CLAUDE.md)** — codebase tour and conventions, intended as context for Claude Code or other AI coding assistants when working in this tree.
- Upstream documentation:
  - [AdaptixC2 docs](https://adaptix-framework.gitbook.io/adaptix-framework)
  - [Kharon docs](https://github.com/entropy-z/Kharon/tree/main/doc)
  - [Extension-Kit README](https://github.com/Adaptix-Framework/Extension-Kit#readme)
- Original installation walkthrough this repo started from: [Mitchell's journal — AdaptixC2 + Kharon install guide](https://mitchells-journal.gitbook.io/writings/adaptixc2-and-nakasendo/0.1.-adaptixc2-and-kharon-installation-guide).

---

## Credits

All of the actual offensive-security functionality in this build is the work of upstream maintainers. This repository is a build-and-integration harness; full credit for the framework and modules belongs to:

- **AdaptixC2** — [Adaptix-Framework](https://github.com/Adaptix-Framework) and contributors — the teamserver, GUI client, extender plugin API, and default listeners/agents
- **Extension-Kit** — [Adaptix-Framework](https://github.com/Adaptix-Framework) and contributors — the official BOF collection and AxScript wrappers
- **Kharon** — [__oblivion](https://github.com/entropy-z) ([@entropy-z](https://github.com/entropy-z)) — the PIC agent with stack spoofing, sleep obfuscation, and indirect syscalls
- **PostEx-Arsenal** — [__oblivion](https://github.com/entropy-z) ([@entropy-z](https://github.com/entropy-z)) — the Kharon-flavored BOF and post-ex shellcode module collection

The original installation walkthrough that guided the Kharon integration was written by **Mitchell** and published at [Mitchell's Journal — AdaptixC2 + Kharon Installation Guide](https://mitchells-journal.gitbook.io/writings/adaptixc2-and-nakasendo/0.1.-adaptixc2-and-kharon-installation-guide). That article is what this build harness automates.

If you find a bug in the framework, an agent, or a BOF, please file it upstream — not here. File issues here only when something in the *build harness* (Dockerfile, profile, macOS script, patches) is broken.

---

## License

The build harness in this repository (`Dockerfile`, `docker-compose.yml`, `profile.kharon.yaml`, `scripts/`, `patches/`, `docker/`, `.github/`, `BLUEPRINT.md`, `CLAUDE.md`, `README.md`) is released under the [MIT License](./LICENSE).

Submodule contents are governed by their own upstream licenses; consult each submodule's `LICENSE` file before redistribution. In particular, AdaptixC2 carries explicit notices about authorized use that you must preserve.
