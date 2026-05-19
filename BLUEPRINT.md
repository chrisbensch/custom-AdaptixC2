# BLUEPRINT.md — Unified AdaptixC2 Build Integration

> **Purpose.** This file is the complete, self-contained recipe for assembling the four sibling repos in this workspace into a runnable AdaptixC2 server image plus distributable GUI clients. Hand it to a fresh-context Claude (or human) and they should be able to reproduce the build against either the same upstream snapshots or a newer set, applying the changes verbatim or adapting them where upstream has moved.

---

## 1. Workspace shape

The workspace itself is a git repo. The four upstream projects are git **submodules** pinned to the SHAs in §2; we don't own those repos, so customizations live in `patches/` (applied at build time) rather than committed inside them. Reproduce on another machine with `git clone --recurse-submodules <workspace-repo-url>`.

```
./
├── .git/                 ← workspace repo
├── .gitmodules           ← submodule URLs + paths (commits pinned via gitlinks in §2)
├── .gitignore            ← excludes data/, AdaptixClient-dist/, build/, .claude/, *.log
├── .dockerignore         ← excludes **/.git, **/.gitmodules from build context (see §5.6)
│
├── AdaptixC2/            ← submodule: Adaptix-Framework/AdaptixC2  (server + Qt6 client)
├── Extension-Kit/        ← submodule: Adaptix-Framework/Extension-Kit  (BOFs)
├── Kharon/               ← submodule: entropy-z/Kharon  (PIC agent + HTTP listener)
├── PostEx-Arsenal/       ← submodule: entropy-z/PostEx-Arsenal  (Kharon-flavored modules)
│
├── BLUEPRINT.md          ← this file
├── CLAUDE.md             ← context for future Claude conversations (separate concern)
├── README.md             ← user-facing project overview
├── Dockerfile            ← unified server build (multi-stage, host-arch by default)
├── docker-compose.yml    ← services for build/runtime/build-client
├── profile.kharon.yaml   ← merged server profile template (9 extenders + 2 axscripts, env-var placeholders)
├── build-client-macos.sh ← native macOS .app build script (Apple Silicon arm64)
├── install-prereqs-windows.ps1 ← Windows prerequisite installer (MSYS2 + MinGW64 + Qt6; see §11)
├── LICENSE               ← MIT license (build harness only; submodule contents under their own licenses)
│
├── docker/
│   └── entrypoint.sh     ← runtime image entrypoint: TLS cert-gen + profile rendering on first start (§5.7)
│
├── patches/                                       ← build-time patches against submodules
│   ├── adaptixclient-macos-bundle.patch           ← see §5.5 / §6.1
│   └── extension-kit-nanodump-host-strip.patch   ← see §5.5 / §6.3
│
├── .github/
│   └── workflows/
│       └── build.yml     ← CI: amd64+arm64 image build + healthcheck-based smoke test (§12)
│
├── data/                 ← created at runtime; profile.yaml + credentials.txt + SQLite DB (bind mount, gitignored)
└── AdaptixClient-dist/   ← created during builds; AppImage and .app land here (gitignored)
```

Host: macOS Apple Silicon (arm64). The server image builds for the **host architecture by default** — native arm64 builds on Apple Silicon (≈6 min), or set `DOCKER_DEFAULT_PLATFORM=linux/amd64` to force amd64 under QEMU emulation (≈13 min). Verified to build and run on both arches. The Linux client AppImage builds for either arch via `build-client-linux.sh --arch amd64|arm64` (host default): amd64 takes the upstream `build-client` stage; arm64 takes the new `build-client-kali` stage (§6.4) — kali-rolling provides distro Qt 6.10.2 since aqtinstall has no aarch64 Qt binaries. macOS client targets **arm64 only**.

## 2. Upstream baselines this was applied against

These are the exact commits the integration was designed for. When re-applying after upstream moves, diff against these to spot drift in the patch area.

| Repo | Branch / tag | Commit | Date |
|---|---|---|---|
| AdaptixC2 | tags/v1.1 (dev-v1.2 merged) | `a4b80bf370f704d6843e69433bfb5c06274f57df` | 2026-03-04 |
| Extension-Kit | heads/main | `9413caf85fd83272f5866ef42f9e7ed8db9987d6` | 2026-02-28 |
| Kharon | heads/main | `699ece7085ca48266affb9766450ee0ef0548f26` | 2026-04-02 |
| PostEx-Arsenal | heads/master | `e169261e1e99e69fa17cf8c7cbb00878f5f374de` | 2026-03-13 |

## 3. Pinned versions and rationale

| What | Version | Why |
|---|---|---|
| Go | **1.25.4** (server image base: `golang:1.25-bookworm`) | Matches `AdaptixC2/AdaptixServer/go.mod`. The Adaptix install guide mentions 1.25.8 — newer patch versions are fine, but staying on 1.25.x is required. |
| GOEXPERIMENT | `jsonv2,greenteagc` | Required by upstream Makefile / Dockerfile; preserved in the new Dockerfile as an env default. |
| go-win7 | HEAD of `Adaptix-Framework/go-win7` | Win7-compatible Go runtime needed by Gopher Agent and consumed by Kharon's beacon. Cloned `--depth=1`. |
| Qt (Linux client AppImage, amd64) | **6.9.2** (via aqtinstall, from upstream AdaptixC2/Dockerfile `build-client` stage) | Reused as-is from upstream. |
| Qt (Linux client AppImage, arm64) | **6.10.2** (distro packages from `kalilinux/kali-rolling`, via new `build-client-kali` stage added by `patches/adaptixclient-kali-arm64-stage.patch`) | aqtinstall publishes no Linux aarch64 Qt binaries through 6.11.x; Kali's distro Qt6 fills the gap. API-compatible with 6.9.2. |
| Qt (macOS client) | Homebrew **qt@6** (currently 6.11.x) | Native arm64; works because of the `if(APPLE)` CMake patch. |
| Debian base (build) | `bookworm` | Matches upstream. |
| Ubuntu base (Linux client amd64) | `22.04` | From upstream AdaptixC2/Dockerfile `build-client` stage. |
| Kali base (Linux client arm64) | `kalilinux/kali-rolling:latest` | Provides arm64 Qt 6.10.2; tracked as a rolling distro since this is the only Qt-6.9+ aarch64 source we have. |

## 4. Decisions baked into the integration

These were resolved up-front via `AskUserQuestion`. Repeat them if re-running the planning.

1. **Server runtime layout:** all artifacts (server, extenders, BOFs, axscripts, profile *template*, kharon template) baked into the runtime image. No host-mounted scripts/BOFs.
2. **profile.yaml:** `profile.kharon.yaml` ships in the image as a **template** at `/app/profile.yaml.tmpl` with `__ADAPTIX_TEAMSERVER_PASSWORD__` and `__ADAPTIX_OPERATORS_BLOCK__` placeholders. The entrypoint (`docker/entrypoint.sh`, §5.7) renders it to `/app/data/profile.yaml` on first start using env vars (`ADAPTIX_TEAMSERVER_PASSWORD`, `ADAPTIX_OPERATORS`) or randomly-generated values, persisting the resolved credentials to `/app/data/credentials.txt`. Subsequent starts reuse the rendered file. Only `./data:/app/data` is bind-mounted by compose — the host `profile.kharon.yaml` is no longer authoritative at runtime (edit `data/profile.yaml` and `restart`, or delete it and re-launch with env vars). This removed the previous hard-coded `pass`/`pass1`/`pass2` defaults from the image.
3. **PostEx-Arsenal `postex_sc/`:** trust the checked-in `.bin` files; do not rebuild in the container (saves clang/llvm/nasm runtime in postex_sc subdirs).
4. **macOS bundle:** patch `AdaptixClient/CMakeLists.txt` with `MACOSX_BUNDLE` properties guarded by `if(APPLE)`. Build natively via Homebrew Qt, then `macdeployqt` + RPATH cleanup + ad-hoc resign.
5. **macOS arch:** Apple Silicon **arm64 only** (no universal binary).
6. **Linux AppImage delivery:** add a `client-linux` service to the workspace-root `docker-compose.yml`. For amd64 it points at `AdaptixC2/Dockerfile`'s upstream `build-client` stage (Qt 6.9.2 via aqtinstall, ubuntu:22.04). For arm64 it points at a new `build-client-kali` stage added via `patches/adaptixclient-kali-arm64-stage.patch` (Qt 6.10.2 via distro packages on kali-rolling) — aqtinstall publishes no aarch64 Qt binaries. Target swap is driven by `ADAPTIX_CLIENT_TARGET`; defaults preserve the original amd64 path.
7. **TLS cipher policy:** ECDHE-only suites in `profile.kharon.yaml`. The legacy `TLS_RSA_WITH_AES_*_GCM_*` suites (no forward secrecy) that upstream ships were dropped to enforce PFS.
8. **Upstream version pinning at build time:** `golang:1.25.4-bookworm` (specific patch, not the floating `1.25`) and `go-win7` pinned via `ARG GO_WIN7_SHA` (currently `15ad42b…`). Bumping is a one-line ARG edit; reproducibility is a first-class requirement.

## 5. Files added at workspace root

### 5.1 `/Dockerfile` (server image)

Multi-stage; build context = workspace root; **builds for the host architecture** (no `--platform` pin on `FROM` lines). Pass `--platform=linux/amd64` to docker build (or set `DOCKER_DEFAULT_PLATFORM`) to force a specific arch — verified working on both arm64 and amd64.

- `base` — `golang:1.25.4-bookworm` (pinned patch version) with `mingw-w64 g++-mingw-w64 gcc g++ make build-essential libssl-dev zlib1g-dev nasm clang llvm python3 git wget ca-certificates`. Clones `Adaptix-Framework/go-win7` into `/usr/lib/go-win7` and `git checkout`s the SHA in `ARG GO_WIN7_SHA` (currently `15ad42b…`) before symlinking runtime headers. Sets `GOEXPERIMENT=jsonv2,greenteagc`.
- `build-bofs` — `COPY Extension-Kit /src/Extension-Kit && COPY patches /src/patches && git apply /src/patches/extension-kit-nanodump-host-strip.patch`. The patch fixes an upstream nanodump Makefile bug that breaks on non-amd64 hosts (see §6.3). The build is then split into **two stages** so offline builds still succeed:
  1. **Strict pass.** Hard-coded list of 9 BOF subdirs (`AD-BOF Creds-BOF Elevation-BOF Execution-BOF Injection-BOF LateralMovement-BOF Postex-BOF Process-BOF SAR-BOF`) built one at a time — any failure stops the build. Update this list when upstream adds a BOF subdir (CI catches drift).
  2. **Best-effort pass.** `make -C /src/Extension-Kit/SAL-BOF || echo …` — SAL-BOF runs `python3 download_vulnerable_driver_list.py` over the network at build time; offline builds (and the CI sandbox if it ever loses network egress) tolerate its failure so the rest of the image still ships.
  Finally `COPY PostEx-Arsenal /src/PostEx-Arsenal && make -C /src/PostEx-Arsenal/bofs`.
- `build-server`:
  1. `COPY AdaptixC2 /src/AdaptixC2`
  2. `COPY Kharon/agent_kharon /src/AdaptixC2/AdaptixServer/extenders/agent_kharon`
  3. `COPY Kharon/listener_kharon_http /src/AdaptixC2/AdaptixServer/extenders/listener_kharon_http`
  4. `cd /src/AdaptixC2/AdaptixServer && go work use ./extenders/agent_kharon ./extenders/listener_kharon_http && go work sync`
  5. `make -C /src/AdaptixC2 server-ext` — builds adaptixserver + all 9 extender plugins (Adaptix's Makefile `EXTENDER_DIRS := $(shell find AdaptixServer/extenders -maxdepth 1 -type d ...)` auto-discovers Kharon's two new extenders, no Makefile edit needed).
  6. `make -C /src/AdaptixC2/AdaptixServer/extenders/agent_kharon agent` — explicit second-pass compile of the PIC beacon under `src_beacon/`; re-stages the artifacts into the *source* dist/ directory.
  7. `cp -r /src/AdaptixC2/AdaptixServer/extenders/agent_kharon/dist/. /src/AdaptixC2/dist/extenders/agent_kharon/` — copies the second-pass artifacts back over the first-pass layout so the runtime image ships the beacon binaries alongside the plugin .so. The two-pass reconciliation is **intentional** (see in-Dockerfile comment) — do not collapse it without verifying the beacon ships.
- `runtime` — minimal `debian:bookworm-slim` with `ca-certificates openssl curl` (`curl` is for the HEALTHCHECK). COPYs:
  - `/src/AdaptixC2/dist/` → `/app/` (server, ssl_gen.sh, 404page.html, all 9 extenders)
  - `/src/Extension-Kit` → `/app/Extension-Kit`
  - `/src/PostEx-Arsenal` → `/app/PostEx-Arsenal`
  - workspace `profile.kharon.yaml` → `/app/profile.yaml.tmpl` (template, rendered at first start)
  - `Kharon/listener_kharon_http/profiles/template.json` → `/app/kharon-template.json`
  - workspace `docker/entrypoint.sh` → `/app/entrypoint.sh` (see §5.7; replaces the previous inline-generated entrypoint)
- `EXPOSE 4321` only (4321 is the teamserver; was previously `4321 80 443 8080 8443`, but under `network_mode: host` EXPOSE is a no-op anyway, and beacon listener ports are operator-defined at runtime so they're not knowable at image-build time — listing 80/443/etc. was misleading).
- `HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD curl -sk --max-time 5 -o /dev/null https://127.0.0.1:4321/endpoint || exit 1` — confirms TLS handshake + HTTP layer up. `/endpoint` is a WebSocket upgrade and won't 2xx on a plain GET, so the check intentionally omits `-f`; non-zero exit only on connect/TLS/timeout failure. CI (§12) uses this signal as its smoke-test gate.
- `ENTRYPOINT ["/app/entrypoint.sh"]`. `CMD ["/app/adaptixserver", "-profile", "/app/data/profile.yaml"]` — the profile path lives under `/app/data` (the bind-mounted volume) where the entrypoint renders it on first start.

The full file is at `./Dockerfile` (170 lines). Do not duplicate here — copy verbatim or regenerate from this spec.

### 5.2 `docker-compose.yml`

Three services. The `builder` and `server` services have **no platform pin** (host arch by default; override with `DOCKER_DEFAULT_PLATFORM`). Only `client-linux` is pinned to `linux/amd64` because the AppImage it produces is x86_64 by definition.

```yaml
name: adaptixc2-omni

services:
  builder:                                     # profile: build  — wraps `docker build`
    profiles: ["build"]
    build:
      context: .
      dockerfile: Dockerfile
      target: runtime
    image: adaptixc2-omni:latest
    container_name: adaptixc2-omni-builder
    command: ["true"]

  server:                                      # profile: runtime — runs the server
    profiles: ["runtime"]
    image: adaptixc2-omni:latest
    container_name: adaptixc2-omni-server
    network_mode: host
    volumes:
      # The runtime profile (./data/profile.yaml) is rendered by the entrypoint
      # on first start. Edit it there and `restart` to apply changes.
      - ./data:/app/data
    environment:
      - TZ=${TZ:-UTC}
      # Uncomment and set before first start to pin credentials. Otherwise the
      # entrypoint generates random ones and writes them to data/credentials.txt.
      # - ADAPTIX_TEAMSERVER_PASSWORD=
      # - ADAPTIX_OPERATORS=operator1:secret1,operator2:secret2
    restart: unless-stopped

  client-linux:                                # profile: build-client — Linux AppImage
    profiles: ["build-client"]
    platform: ${ADAPTIX_CLIENT_PLATFORM:-linux/amd64}
    build:
      context: ./AdaptixC2
      dockerfile: Dockerfile
      target: ${ADAPTIX_CLIENT_TARGET:-build-client}
      platforms: [${ADAPTIX_CLIENT_PLATFORM:-linux/amd64}]
      args:
        IMG_ARCH: ${ADAPTIX_CLIENT_IMG_ARCH:-x86_64}
    image: adaptixc2-omni-client-linux-builder:${ADAPTIX_CLIENT_ARCH:-amd64}
    container_name: adaptixc2-omni-client-linux-builder-${ADAPTIX_CLIENT_ARCH:-amd64}
    volumes:
      - ./AdaptixClient-dist:/client-dist-output
    command: sh -c "cp -r /client-dist/. /client-dist-output/"
```

`client-linux` targets one of two stages depending on the `ADAPTIX_CLIENT_TARGET` env var (set by `build-client-linux.sh` based on `--arch`):

- **amd64** → upstream `build-client` (lines ≈21–121 of `AdaptixC2/Dockerfile`): Qt 6.9.2 via aqtinstall, ubuntu:22.04, linuxdeployqt + appimagetool. Unchanged from upstream; we inherit any changes.
- **arm64** → new `build-client-kali` stage added by `patches/adaptixclient-kali-arm64-stage.patch`: kalilinux/kali-rolling + distro Qt 6.10.2, linuxdeploy + linuxdeploy-plugin-qt + appimagetool. The arm64 path exists because aqtinstall publishes no Linux aarch64 Qt binaries through 6.11.x; Kali's distro Qt6 fills the gap. Qt 6.10.2 is API-compatible with 6.9.2 (AdaptixClient pins no minor minimum).

Defaults reproduce the original amd64 path (no env vars, no patch effect on the upstream stage), so existing workflows are unaffected.

**Change from earlier revisions:** the `server` service no longer bind-mounts `./profile.kharon.yaml:/app/profile.yaml:ro`. The host file is now the **template** baked into the image at build time; the **rendered** profile lives under `./data/profile.yaml` (managed by the entrypoint, §5.7). Editing the workspace `profile.kharon.yaml` after first start has no effect on a running container — edit `./data/profile.yaml` and `docker compose --profile runtime restart`, or `rm ./data/profile.yaml` and re-launch with `ADAPTIX_*` env vars to re-render from the template.

### 5.3 `profile.kharon.yaml`

A **template**, not a finished profile. Diffed against `AdaptixC2/AdaptixServer/profile.yaml`:

```diff
 Teamserver:
   interface: "0.0.0.0"
   port: 4321
   endpoint: "/endpoint"
-  password: "pass"
+  password: "__ADAPTIX_TEAMSERVER_PASSWORD__"
   only_password: true
   operators:
-    operator1: "pass1"
-    operator2: "pass2"
+__ADAPTIX_OPERATORS_BLOCK__
+  cert: "/app/data/server.rsa.crt"
+  key: "/app/data/server.rsa.key"
   extenders:
     - "extenders/beacon_listener_http/config.yaml"
     - "extenders/beacon_listener_smb/config.yaml"
     - "extenders/beacon_listener_tcp/config.yaml"
     - "extenders/beacon_listener_dns/config.yaml"
     - "extenders/beacon_agent/config.yaml"
     - "extenders/gopher_listener_tcp/config.yaml"
     - "extenders/gopher_agent/config.yaml"
+    - "extenders/agent_kharon/config.yaml"
+    - "extenders/listener_kharon_http/config.yaml"
   axscripts:
-#    - "Extension-Kit/extension-kit.axs"
+    - "Extension-Kit/extension-kit.axs"
+    - "PostEx-Arsenal/kh_modules.axs"
   …
   tls:
     cipher_suites:
       - "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
       - "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
       - "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
       - "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
-      - "TLS_RSA_WITH_AES_128_GCM_SHA256"
-      - "TLS_RSA_WITH_AES_256_GCM_SHA384"
```

Five categories of change:

1. **Teamserver password** is a placeholder (`__ADAPTIX_TEAMSERVER_PASSWORD__`) rendered by the entrypoint (§5.7) from `$ADAPTIX_TEAMSERVER_PASSWORD` or a random `openssl rand -hex 24`.
2. **Operators block** is a single placeholder line (`__ADAPTIX_OPERATORS_BLOCK__`) the entrypoint expands into a YAML mapping from `$ADAPTIX_OPERATORS` (comma-separated `user:pass` pairs) or a single random `operator1:<random>` default. The previous hard-coded `operator1: pass1` / `operator2: pass2` defaults are gone — there is no longer a passwords-in-public-repo failure mode.
3. **Cert + key paths** point at `/app/data/server.rsa.crt` and `/app/data/server.rsa.key` (the bind-mounted volume), where the entrypoint generates them on first start. Upstream pointed at relative paths against the CWD; we made them absolute so the rendered profile is unambiguous regardless of where the binary is invoked from.
4. **Extenders + axscripts** — the same two additions and one un-commenting that were always here. Order matters for UX (Kharon entries last).
5. **TLS cipher suites** — `TLS_RSA_WITH_AES_*` (no forward secrecy) removed. ECDHE suites only. This is a hardening choice, not an upstream defect; upstream may add them back, in which case keep them removed when re-merging.

These paths resolve relative to `/app/` (server's CWD inside the container), which is exactly where `/app/Extension-Kit/` and `/app/PostEx-Arsenal/` are placed by the runtime stage. AxScript's `ax.script_dir()` resolves to the directory of the loaded `.axs` file — so `kh_modules.axs` finds `bofs/dist/*.x64.o` at `/app/PostEx-Arsenal/bofs/dist/*.x64.o`, and `extension-kit.axs` finds the per-subdir scripts.

### 5.4 `build-client-macos.sh`

Native macOS arm64 build. 185 lines; full file at workspace root. Key steps:

1. **Preflight:** require `Darwin arm64`; require `brew`; verify `cmake`, `qt@6`, `openssl@3` Homebrew kegs.
2. **Icon:** `sips` + `iconutil` convert `AdaptixC2/AdaptixClient/Resources/Logo.png` → `AdaptixClient.icns`. Idempotent (skip if newer than source).
3. **Configure:** `cmake -S AdaptixC2/AdaptixClient -B build/macos -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_PREFIX_PATH="$(brew --prefix qt@6);$(brew --prefix openssl@3)"`.
4. **Build:** `cmake --build build/macos -j$(sysctl -n hw.ncpu)`. Produces `build/macos/AdaptixClient.app` because of the CMake patch (§6.1).
5. **Bundle Qt frameworks:** `"$(brew --prefix qt@6)/bin/macdeployqt" "$APP_BUILD" -verbose=1` (`-dmg` if `--dmg` flag given).
6. **CRITICAL — RPATH cleanup** (this was discovered during the actual build; without it the app crashes on launch):
   - `install_name_tool -add_rpath @executable_path/../Frameworks` on the main exe (only if not already there)
   - Delete every other RPATH on the main exe (e.g. `/opt/homebrew/opt/qt/lib`) via `install_name_tool -delete_rpath`
7. **Ad-hoc resign:** `codesign --force --deep --sign - "$APP_BUILD"` — `install_name_tool` invalidates Homebrew's existing signatures.
8. **Stage:** move `build/macos/AdaptixClient.app` → `AdaptixClient-dist/AdaptixClient.app`.

Flags: `--clean` (wipe build dir first), `--dmg` (also produce `.dmg`).

### 5.5 `patches/`

Build-time patches against submodule trees we don't own. Each is a unified-diff file applied by the relevant build step. The macOS patch is applied/reverted via `trap` around the build (host filesystem); the Dockerfile patches are applied inside the container layer (so the host submodule tree never gets touched).

| Patch | Target | Applied by |
|---|---|---|
| `adaptixclient-macos-bundle.patch` | `AdaptixC2/AdaptixClient/CMakeLists.txt` | `build-client-macos.sh` (host, with auto-revert) |
| `adaptixclient-kali-arm64-stage.patch` | `AdaptixC2/Dockerfile` | `build-client-linux.sh` (host, with auto-revert) |
| `extension-kit-nanodump-host-strip.patch` | `Extension-Kit/Creds-BOF/nanodump/Makefile` | `Dockerfile` `build-bofs` stage (container only) |

When upstream drifts and a patch stops applying, the apply script (or `docker compose build`) fails fast with a clear message. Regenerate the patch from a freshly-rebased manual edit, then commit the new `.patch` file. Don't accumulate patches: if a workaround can be replaced by an upstream change, push for that instead.

### 5.6 `/.dockerignore`

Excludes `**/.git`, `**/.gitmodules`, build outputs, and `.claude/` from every `docker build` context that uses the workspace root. The `**/.git` exclusion is **load-bearing**: each submodule on the host has a `.git` *file* that points (`gitdir: ../.git/modules/<name>`) into the parent repo's `.git/modules/`. Without `.dockerignore`, Docker COPYs that pointer file into the container, where the path it references doesn't exist — and `git apply` inside the container then fails with `fatal: not a git repository`. Excluding the file lets `git apply` operate on a plain directory (which it does fine; it doesn't actually need a repo).

### 5.7 `docker/entrypoint.sh`

First-start bootstrap for the runtime image. Replaces the previous inline-generated cert-only entrypoint with a file COPYed into the image at build time. 59 lines; full file at `./docker/entrypoint.sh`.

Behavior:

1. **TLS certs** — if `/app/data/server.rsa.crt` or `.key` is missing, generate a 2048-bit self-signed pair with `openssl req -x509 -nodes` (subject `/C=US/ST=State/L=City/O=AdaptixC2/CN=localhost`, 10-year validity), `chmod 600` the key.
2. **Profile rendering** — if `/app/data/profile.yaml` is missing:
   - Resolve `ADAPTIX_TEAMSERVER_PASSWORD` (default: `openssl rand -hex 24`).
   - Resolve `ADAPTIX_OPERATORS` (default: `operator1:<openssl rand -hex 16>`). Format: comma-separated `user:pass` pairs.
   - Expand the operators env var into a YAML block (`    name: "pass"` lines) in a temp file.
   - `sed` the template `/app/profile.yaml.tmpl` → `/app/data/profile.yaml`, substituting `__ADAPTIX_TEAMSERVER_PASSWORD__` and inserting the operators block in place of `__ADAPTIX_OPERATORS_BLOCK__`.
   - `chmod 600` the rendered profile.
   - Append the resolved password and operator string to `/app/data/credentials.txt` (also `0600`) and echo the password to the container log so `docker compose logs` captures it on first start.
3. **Exec** — `exec "$@"` invokes the CMD (`/app/adaptixserver -profile /app/data/profile.yaml`).

Subsequent starts skip both blocks: the cert + profile + credentials file already exist. Rotation flow: edit `data/profile.yaml` and restart, or `rm data/profile.yaml` and re-launch with the env vars set.

Why this lives in a separate file (vs. heredoc in the Dockerfile): the script grew enough logic (sed-based templating, IFS handling, persistence) that an inline heredoc would be hard to review and test. Keeping it at `docker/entrypoint.sh` means `shellcheck`-able, diff-able, and editable without rebuilding the image to inspect it.

## 6. Patches to upstream subrepos

### 6.1 `AdaptixC2/AdaptixClient/CMakeLists.txt` — macOS bundle support

**Stored as `patches/adaptixclient-macos-bundle.patch`; applied by `build-client-macos.sh` and auto-reverted on exit.** The block inserts after `add_executable(AdaptixClient …)` (which ended at line 260 in the pinned commit) and before `target_compile_definitions(...)` (line 262). Result:

```cmake
        Source/Utils/FontManager.cpp
        Source/Utils/TitleBarStyle.cpp
)

if(APPLE)
    set(MACOS_ICON "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AdaptixClient.icns")
    set_target_properties(AdaptixClient PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_NAME "AdaptixClient"
        MACOSX_BUNDLE_GUI_IDENTIFIER "io.adaptix.client"
        MACOSX_BUNDLE_BUNDLE_VERSION "1.2.0"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "1.2"
        MACOSX_BUNDLE_ICON_FILE "AdaptixClient.icns"
    )
    if(EXISTS "${MACOS_ICON}")
        target_sources(AdaptixClient PRIVATE "${MACOS_ICON}")
        set_source_files_properties("${MACOS_ICON}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources")
    endif()
endif()

target_compile_definitions(
        AdaptixClient
```

Purely additive; Linux/Windows builds unaffected. The existing `if(WIN32) … elseif(UNIX)` link block at lines 284–305 still applies on Apple (Apple is `UNIX`; `pthread + dl` is correct).

If upstream future `add_executable(...)` arguments change (e.g. they already add `MACOSX_BUNDLE`), drop this patch in favor of upstream's version. Bump `MACOSX_BUNDLE_BUNDLE_VERSION` and `_SHORT_VERSION_STRING` to match the upstream release tag.

### 6.2 Other build-time changes (no source-tree commit needed)

These changes are made **inside the Dockerfile** and do not touch the host source tree:

- `AdaptixC2/AdaptixServer/extenders/agent_kharon` — populated by `COPY Kharon/agent_kharon …` in the Dockerfile.
- `AdaptixC2/AdaptixServer/extenders/listener_kharon_http` — populated by `COPY Kharon/listener_kharon_http …`.
- `AdaptixC2/AdaptixServer/go.work` — `go work use` appends two entries during the build. (`setup_kharon.sh` is the upstream-provided script doing this; we inline the same logic.)
- `AdaptixC2/AdaptixServer/profile.yaml` — replaced inside the runtime image by the workspace-root `profile.kharon.yaml`, COPYed in as `/app/profile.yaml.tmpl` (a template — see §5.3 and §5.7). The entrypoint renders it to `/app/data/profile.yaml` on first start, substituting in credentials from env vars or random defaults. The host file is no longer bind-mounted at runtime.

These should NOT be committed to a submodule working tree — keep them clean so `git status` in any submodule stays empty between builds. The `patches/` mechanism (§5.5), the `trap`-based revert in `build-client-macos.sh`, and the in-container `git apply` for §6.3 enforce this; everything else is Dockerfile-side.

### 6.3 `Extension-Kit/Creds-BOF/nanodump/Makefile` — host-arch strip fix

**Stored as `patches/extension-kit-nanodump-host-strip.patch`; applied inside the container by the Dockerfile's `build-bofs` stage. The host submodule tree is never modified.** The patch deletes one redundant line from upstream nanodump's Makefile:

```diff
 	@$(GCC) source/restore_signature.c -o scripts/restore_signature -static -s -Os
-	@$(STRIP_x64) --strip-all scripts/restore_signature
```

`scripts/restore_signature` is built by the **host** `gcc` (line 78), but upstream then strips it with `x86_64-w64-mingw32-strip` — a Windows cross-strip targeted at PE/COFF. On amd64 hosts the cross-strip happens to accept x86_64 ELF as a side effect of binutils' BFD library, so the bug is invisible. On arm64 hosts gcc produces aarch64 ELF, which the x86_64-targeted strip rejects with `Unable to recognise the format of the input file`, and the BOF build fails. The strip is also redundant: line 78's `-s` flag already strips at link time. Dropping line 79 fixes arm64 and is a no-op on amd64.

Worth pushing upstream as a one-line PR; until then, this patch keeps cross-arch builds working.

### 6.4 `AdaptixC2/Dockerfile` — Kali-rolling arm64 client stage

**Stored as `patches/adaptixclient-kali-arm64-stage.patch`; applied by `build-client-linux.sh` on the host with auto-revert via `trap`, so the submodule tree stays clean between builds.** The patch appends a new `build-client-kali` stage to `AdaptixC2/Dockerfile` — purely additive, the upstream `build-client` stage is unchanged.

Why a second stage instead of parameterizing the first: upstream's `build-client` installs Qt via aqtinstall (`aqt install-qt linux desktop 6.9.2 linux_gcc_64`). aqtinstall publishes no Linux aarch64 Qt binaries for any version through 6.11.x (verified via `aqt list-qt linux desktop --arch 6.9.2` — returns only `linux_gcc_64`). The new stage takes a different approach: base on `kalilinux/kali-rolling`, install Qt 6 via apt (currently Qt 6.10.2; API-compatible with 6.9.2 since AdaptixClient pins no minor minimum), and use `linuxdeploy` + `linuxdeploy-plugin-qt` instead of linuxdeployqt (the latter is amd64-only and unmaintained).

Package set (see the patch for the full list). Five gotchas discovered iteratively that aren't obvious from the apt names:

1. **`ca-certificates` is explicit.** With `--no-install-recommends`, wget alone doesn't pull in CA certs, and downloading the linuxdeploy/appimagetool AppImages over HTTPS fails with `wget` exit code 5 (SSL verification failure). The package list installs `ca-certificates` explicitly.
2. **`qt6-svg-dev` is required** (not just `libqt6svg6`). The bundled `qlementine` vendor library calls `find_package(Qt6 REQUIRED COMPONENTS Core Widgets Svg)`, which needs the CMake config files in `qt6-svg-dev`.
3. **`qt6-declarative-dev` is required** for `Qt6::Qml` (top-level CMakeLists.txt component).
4. **`qt6-base-private-dev` is required** because the bundled `kddockwidgets` vendor library uses `Qt6::WidgetsPrivate`. Without it, configure fails with `Imported target "Qt6::WidgetsPrivate" includes non-existent path "/usr/include/aarch64-linux-gnu/qt6/QtWidgets/6.10.2"`.
5. **`qt6-svg-plugins` is required** for the runtime SVG icon engine plugin (`libqsvgicon.so`). Without it, `linuxdeploy-plugin-qt` fails with `ERROR: Cannot deploy non-existing library file: .../iconengines/libqsvgicon.so`. The `-dev` package alone provides the CMake config but not the runtime plugin .so.

Additional fine points:

- **AppImages get pre-extracted at install time.** Each of `linuxdeploy`, `linuxdeploy-plugin-qt`, and `appimagetool` is downloaded as an AppImage, then `--appimage-extract`-ed into `/opt/<tool>/`, with `/opt/<tool>/AppRun` symlinked into `/usr/local/bin/<tool>`. This avoids needing FUSE at build time (Kali ships no `libfuse2` — only `libfuse3-dev`) and avoids the AppImage runtime's per-invocation extract overhead.
- **`IMG_ARCH` defaults to `aarch64`** — the stage's primary purpose. Override to `x86_64` to produce a distro-Qt amd64 AppImage as an alternative to the aqtinstall path (untested but plumbing supports it).
- **Deprecation warnings during compile** about `QSortFilterProxyModel::invalidateFilter()` (deprecated in Qt 6.10 — use `begin/endFilterChange()` instead). Non-fatal; upstream-fix territory.

Kali rolling is, by definition, a rolling distro. We accept that the Qt version baked into the arm64 AppImage will drift over time; if a future Qt minor breaks the Adaptix client, pin a snapshot tag in the `FROM` line. Build time on Apple Silicon: ≈4 minutes (≈90s apt install + ≈130s compile + ≈30s deploy + ≈10s appimage packaging). Output AppImage: ≈63 MB.

## 7. Build commands

**First-time setup on a fresh machine:**

```bash
git clone --recurse-submodules https://github.com/chrisbensch/AdaptixC2-Omni.git
cd AdaptixC2-Omni
# If you forgot --recurse-submodules: git submodule update --init --recursive
```

From the workspace root:

```bash
# Server image, host-arch (≈6 min native arm64; ≈12 min native amd64; 273–288 MB)
docker compose --profile build build

# Same, but force amd64 under QEMU on an arm64 host (≈13 min)
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose --profile build build

# Run the server  (host networking; SQLite under ./data/)
docker compose --profile runtime up -d
docker compose --profile runtime logs -f
docker compose --profile runtime down

# Linux client AppImage  (≈10 min under QEMU; 57 MB at AdaptixClient-dist/AdaptixClient-x86_64.AppImage)
docker compose --profile build-client build
docker compose --profile build-client up --abort-on-container-exit

# macOS client .app  (≈3–6 min native; 118 MB at AdaptixClient-dist/AdaptixClient.app)
./build-client-macos.sh           # plain
./build-client-macos.sh --clean   # wipe build dir first
./build-client-macos.sh --dmg     # also produce .dmg

# Windows client exe  (on a Windows machine; see §11 for full details)
# Step 1 — install prerequisites once per machine (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File install-prereqs-windows.ps1
# Step 2 — build (standard cmd.exe):
#   cd AdaptixC2\AdaptixClient && build.bat
#   → AdaptixC2\AdaptixClient\dist\AdaptixClient.exe + bundled DLLs
```

## 8. Verification checklist

**Server image:**
1. `docker image inspect adaptixc2-omni:latest --format '{{.Os}}/{{.Architecture}}'` → `linux/arm64` or `linux/amd64` matching the build platform
2. `docker run --rm --entrypoint sh adaptixc2-omni:latest -c 'ls /app/extenders'` → 9 dirs incl. `agent_kharon`, `listener_kharon_http`
3. `docker run --rm --entrypoint sh adaptixc2-omni:latest -c 'ls /app/Extension-Kit/SAL-BOF/_bin /app/PostEx-Arsenal/bofs/dist | head'` → both populated (SAL-BOF may be empty if the image was built offline — see §5.1)
4. `docker compose --profile runtime up -d && docker compose --profile runtime logs --tail=50` → see `Generating self-signed certificates`, `Wrote /app/data/profile.yaml and /app/data/credentials.txt`, `Teamserver password: <hex>`, `Starting server -> https://0.0.0.0:4321/endpoint`, `The AdaptixC2 server is ready`
5. `docker inspect --format '{{.State.Health.Status}}' adaptixc2-omni-server` → `healthy` within ~30 seconds of startup (HEALTHCHECK probes the teamserver TLS endpoint; see §5.1).
6. `cat ./data/credentials.txt` → `teamserver_password=…` and `operators=operator1:…` (mode 600). These are the random defaults if you didn't set `ADAPTIX_TEAMSERVER_PASSWORD` / `ADAPTIX_OPERATORS` before first start.
7. Connect a client to `https://<host>:4321/endpoint` using an operator credential from `data/credentials.txt` (or your `ADAPTIX_OPERATORS` value). Listener creation dialog shows 9 extenders. AxScript Manager shows `extension-kit.axs` and `kh_modules.axs` already loaded.

**Linux AppImage:**
1. `file AdaptixClient-dist/AdaptixClient-x86_64.AppImage` → `ELF 64-bit LSB executable, x86-64, … stripped`
2. On a Linux x86_64 host (or arm64 host with `qemu-user-static`): `chmod +x AdaptixClient-x86_64.AppImage && ./AdaptixClient-x86_64.AppImage` opens the GUI.

**macOS .app:**
1. `file AdaptixClient-dist/AdaptixClient.app/Contents/MacOS/AdaptixClient` → `Mach-O 64-bit executable arm64`
2. `otool -l … | grep -A2 LC_RPATH | grep "path "` → only `@executable_path/../Frameworks` (no `/opt/homebrew/...`)
3. `codesign -dv …` → `Signature=adhoc`, `Identifier=io.adaptix.client`
4. **Portability:** `cp -R AdaptixClient.app /tmp/ && /tmp/AdaptixClient.app/Contents/MacOS/AdaptixClient` — must launch (don't just open the original location).
5. `open AdaptixClient-dist/AdaptixClient.app` — Gatekeeper may prompt on first launch (right-click → Open clears it).

**Windows client exe** (run on the Windows build machine):
1. `dir AdaptixC2\AdaptixClient\dist\AdaptixClient.exe` → file exists and is non-zero.
2. Launch `dist\AdaptixClient.exe` — window appears, no missing-DLL error dialog. SmartScreen may prompt on first run; right-click → "Run anyway" clears it.
3. Connect to `https://<server>:4321/endpoint` — login dialog appears and authenticates.
4. Listener creation dialog shows all 9 extenders; AxScript Manager shows `extension-kit.axs` and `kh_modules.axs` loaded.

## 9. Known issues and gotchas

1. **macOS — macdeployqt does NOT fix the main exe's rpath.** Out of the box it leaves `/opt/homebrew/opt/qt/lib` on the binary, which means `@rpath/libsharpyuv.0.dylib` (and similar transitive libwebp deps) fail to resolve outside the build host → the app crashes at launch with no console output. The fix is in step 6 of `build-client-macos.sh` and is **mandatory** for portability.
2. **macOS — codesign verification errors from macdeployqt are noise** but the ad-hoc resign step at the end of the script makes the final bundle launch on a clean Mac.
3. **macOS — first-launch Gatekeeper warning** is expected because the bundle is ad-hoc signed (no Developer ID). For unattended distribution, codesign with a Developer ID + notarize. Out of scope here.
4. **Linux AppImage — `libfuse2` and `fuse` apt packages** are required inside the build container; already present in `AdaptixC2/Dockerfile`'s build-client stage. Docker Desktop does NOT need fuse access on the *host* to build (only to run AppImages on a Linux host).
5. **Server build — Kharon beacon needs `clang`, `nasm`, `llvm`** in the base stage. These are NOT in upstream `AdaptixC2/Dockerfile`'s `base` (which only had `mingw-w64 + gcc/g++`). Without them `agent_kharon/src_beacon/Makefile` fails because it shells `clang++ -target x86_64-w64-mingw32` and `nasm -f win64`.
6. **Server build — `make -C agent_kharon agent` is redundant** with `make server-ext` (the AdaptixC2 Makefile's `extenders` target invokes each extender's default `all` target, and `agent_kharon`'s `all` is `clean plugin agent`). The Dockerfile keeps it as belt-and-suspenders; if the build slows materially in the future, drop it.
7. **AdaptixC2 Makefile auto-discovery.** Adding more extenders requires only:
   - `COPY new_extender /src/AdaptixC2/AdaptixServer/extenders/new_extender` in the Dockerfile (or commit it to AdaptixC2/AdaptixServer/extenders/);
   - Append to `go.work` (`go work use ./extenders/new_extender`);
   - Add an entry in `profile.kharon.yaml`.
   No Makefile edits needed — `EXTENDER_DIRS := $(shell find AdaptixServer/extenders -maxdepth 1 -type d -exec test -f {}/Makefile \; -print)` finds it automatically.
8. **Build context.** The unified `Dockerfile` requires the workspace root as build context (it COPYs all four sibling repos). The `client-linux` service uses `./AdaptixC2` as its context because it consumes only `AdaptixC2/Dockerfile`'s `build-client` stage.
9. **Host-native by default; arm64 first-class.** The unified Dockerfile no longer pins `--platform=linux/amd64`. On Apple Silicon you get a native arm64 image (≈6 min); on amd64 hosts you get amd64. The Windows artifacts in the image (beacon agent C++, Kharon beacon, Gopher agent) are still cross-compiled to PE x86/x64 regardless of host arch via mingw-w64 / clang. To force amd64 from an arm64 host, set `DOCKER_DEFAULT_PLATFORM=linux/amd64` (uses QEMU; ≈13 min) — required if you need to deploy the resulting image to an x86_64 server. On a Linux arm64 host, ensure `qemu-user-static` is registered (`docker run --rm --privileged tonistiigi/binfmt --install all`) before forcing amd64.
10. **Submodule .git pointer files break in-container `git apply`.** Each submodule on the host has a `.git` *file* containing `gitdir: ../.git/modules/<name>`. Without the workspace-root `.dockerignore`, Docker COPYs that file into the build container, where the path it references doesn't exist — and `git apply` then fails before reading the patch. The `.dockerignore`'s `**/.git` and `**/.gitmodules` lines are load-bearing.
11. **nanodump host-strip bug surfaces only on non-amd64 hosts.** Upstream's nanodump Makefile strips a host-built ELF binary using `x86_64-w64-mingw32-strip` (a Windows cross-strip). On amd64 the cross-strip silently accepts x86_64 ELF; on arm64 it rejects aarch64 ELF and the build dies. Patched out by `patches/extension-kit-nanodump-host-strip.patch`; the strip was redundant anyway (gcc `-s` already strips). See §6.3.
12. **Profile is rendered once, then frozen.** The entrypoint only renders `/app/data/profile.yaml` if it does not already exist. Editing the workspace `profile.kharon.yaml` after first start changes nothing in the running container — the template was already consumed. To change ports, extenders, axscripts, or anything else from the template after first start: edit `data/profile.yaml` directly and `restart`, or `rm data/profile.yaml` and let the entrypoint re-render (and re-generate credentials if env vars aren't set). The split exists so credentials persist across restarts and you can override extenders/axscripts post-deploy without rebuilding the image.
13. **Credentials in `data/credentials.txt` are the *only* place random passwords are recorded.** The entrypoint also echoes the teamserver password to the container log on first start, but `docker logs` rotation may evict it. The file is `chmod 600`. Treat it like an SSH key: don't commit `./data/`, don't email it. If you lose it and didn't set `ADAPTIX_*` env vars, the only recovery is to read the rendered `data/profile.yaml` (or wipe `data/` and start over).
14. **HEALTHCHECK omits `-f` intentionally.** `/endpoint` is a WebSocket upgrade and returns a non-2xx status on a plain GET, so `curl -f` would mark a healthy server as unhealthy. We only care that the server responded *at all* (TCP+TLS+HTTP), so the check uses `curl -sk -o /dev/null` and trusts the exit code (non-zero only on connect/TLS/timeout failure). If a future upstream change makes `/endpoint` 2xx on GET, switching to `-fsk` is a strict improvement.
15. **`docker/entrypoint.sh` operator parsing uses POSIX `IFS=,`.** Operator credentials are split on commas (`user1:pass1,user2:pass2`). Passwords cannot contain commas or colons unless you edit `data/profile.yaml` manually after first render. If you need richer credentials, set them post-render.

## 10. Upgrade path

When refreshing against newer upstreams:

0. **Bump submodule pins.** Per submodule:
   ```bash
   cd AdaptixC2 && git fetch origin && git checkout <new-tag-or-sha> && cd ..
   git -C AdaptixC2 apply --check patches/adaptixclient-macos-bundle.patch  # confirm patch still applies
   git add AdaptixC2 && git commit -m "Bump AdaptixC2 to <tag>"
   ```
   If `git apply --check` fails, jump to step 2 to refresh the patch before committing the bump. Repeat for `Extension-Kit`, `Kharon`, `PostEx-Arsenal`. Update §2 baselines in the same commit (or a follow-up).
1. **`git pull` each subrepo** to a known good tag/commit. Update §2 baselines. *(Subsumed by step 0 above for the submodule case; left here for the non-submodule fallback.)*
2. **Diff-check the patch sites:**
   - `AdaptixC2/AdaptixClient/CMakeLists.txt` (patch: `adaptixclient-macos-bundle.patch`). Find `add_executable(AdaptixClient …)`. If upstream now adds `MACOSX_BUNDLE` or sets bundle props themselves, retire the patch and harmonize. Otherwise re-apply manually, fix any rejected hunks, and regenerate: `git -C AdaptixC2 diff -- AdaptixClient/CMakeLists.txt > patches/adaptixclient-macos-bundle.patch`. Bump `MACOSX_BUNDLE_BUNDLE_VERSION` inside the patch to match the new release tag.
   - `Extension-Kit/Creds-BOF/nanodump/Makefile` (patch: `extension-kit-nanodump-host-strip.patch`). If upstream has fixed the redundant `STRIP_x64 scripts/restore_signature` line themselves (or refactored that target), retire the patch. Otherwise re-apply manually and regenerate: `git -C Extension-Kit diff -- Creds-BOF/nanodump/Makefile > patches/extension-kit-nanodump-host-strip.patch`. Worth checking whether the upstream PR has been merged before re-applying.
3. **Diff-check `AdaptixC2/AdaptixServer/profile.yaml`** vs `profile.kharon.yaml`. If upstream added new HttpServer fields or a new default extender, mirror those into `profile.kharon.yaml` while keeping:
   - The 2 Kharon extender lines and 2 axscripts entries.
   - The `__ADAPTIX_TEAMSERVER_PASSWORD__` and `__ADAPTIX_OPERATORS_BLOCK__` template placeholders (don't let an upstream merge re-introduce a literal `pass` password).
   - The ECDHE-only `cipher_suites` list (drop any TLS_RSA_* lines upstream re-adds).
   - The absolute `/app/data/server.rsa.{crt,key}` paths.
   If upstream rearranges the YAML enough that the entrypoint's `sed` substitutions no longer match (e.g. they move `operators:` indentation), update `docker/entrypoint.sh` in lockstep.
4. **Diff-check the AdaptixC2 client `build-client` Dockerfile stage**. If `QT_VERSION` or apt deps changed, the workspace `client-linux` service inherits the change for free (no edit).
5. **Diff-check `AdaptixC2/Makefile`** for the `EXTENDER_DIRS` glob and the `server-ext` target. Both are stable; if either is renamed, update `Dockerfile` step `make -C /src/AdaptixC2 server-ext`.
6. **Diff-check `Kharon/setup_kharon.sh`** for additional steps. Currently we inline only its 3 critical actions (copy two dirs, `go work use`, `make`). If new prerequisites appear (e.g. a `pip install` step), mirror them in the `base` or `build-server` stage.
7. **Diff-check `Kharon/agent_kharon/src_beacon/Makefile`** for new toolchain deps. The current set (`clang`, `nasm`, `llvm`, `mingw-w64`) covers it; if a future revision adds `python3-foo` or similar, add to `base` stage's apt list.
8. **Diff-check `Extension-Kit/Makefile`**. The recursive build pattern is stable; if new BOF subdirs appear, no Dockerfile change needed.
9. **Diff-check `PostEx-Arsenal/bofs/makefile`**. Same — recursive over `.cc` files. If `postex_sc/` ever ships pre-built binaries that change name, `kh_modules.axs` paths may shift; runtime test will catch it.
10. **Re-run the verification checklist (§8) end-to-end.**

---

## 11. Windows client build

### 11.1 Toolchain: MSYS2 + MinGW64 (not MSVC)

The upstream Windows build path targets **GCC via MSYS2's MinGW64 environment** — not the MSVC toolchain shipped with Visual Studio Community. Evidence:

- `AdaptixClient/CMakeLists.txt` line 10: `set(Qt6_DIR "C:/msys64/mingw64/lib/cmake")` — hard-coded MSYS2 path; this is load-bearing.
- Lines 17–19: `if(WIN32 AND MINGW)` guards control static OpenSSL and the `-Wl,-subsystem,windows` linker flag.
- Lines 297–298: `-static-libgcc -static-libstdc++` and `-Wl,-Bstatic -lwinpthread -Wl,-Bdynamic` are GCC linker flags with no MSVC equivalent.
- `AdaptixClient/build.bat`: prepends `C:\msys64\mingw64\bin` to `PATH` before invoking CMake with `-G Ninja`.

**Visual Studio Community is not required.** MSYS2 installs a complete GCC toolchain and all dependencies. If you want an IDE on Windows, VS Code with the CMake Tools extension and the MinGW64 kit detected from MSYS2 works well. Do not configure a `cl.exe`/MSVC generator — the link flags and runtime assumptions are MinGW-specific.

### 11.2 Prerequisites

#### Automated install (recommended)

A PowerShell script at the workspace root handles everything below in one command. Run from an elevated (Administrator) PowerShell prompt:

```powershell
powershell -ExecutionPolicy Bypass -File install-prereqs-windows.ps1
```

The script installs MSYS2 and Git for Windows via winget, runs the two-pass pacman update, installs all required MinGW64 packages, verifies the binaries, and checks that `Qt6_DIR` in `CMakeLists.txt` matches the MSYS2 path. See the script's inline help (`Get-Help .\install-prereqs-windows.ps1`) for parameters (`-Msys2Root`, `-SkipGit`).

#### Manual install

If you prefer to install by hand or the script hits a snag:

#### Required software

| Software | Notes | Source |
|---|---|---|
| **MSYS2** | Install to `C:\msys64` — the CMakeLists.txt `Qt6_DIR` path is hard-coded to this location. | https://www.msys2.org |
| **Git for Windows** | Needed for the initial clone with `--recurse-submodules`. MSYS2 also ships git but the Windows native client is easier for initial setup. | https://git-scm.com/download/win |

#### Required MSYS2 packages

Open an **MSYS2 MinGW64** shell (Start Menu → "MSYS2 MinGW x64", or run `C:\msys64\msys2_shell.cmd -mingw64`) and run:

```bash
# Step 1 — update the package database; reopen the shell if prompted, then re-run
pacman -Syu

# Step 2 — update remaining packages
pacman -Syu

# Step 3 — compiler toolchain and build tools
pacman -S --needed \
  mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-ninja

# Step 4 — Qt6 meta-package (pulls Core, Gui, Widgets, Network, WebSockets, Sql, Qml, Svg)
pacman -S --needed mingw-w64-x86_64-qt6

# Step 5 — OpenSSL (statically linked per CMakeLists.txt OPENSSL_USE_STATIC_LIBS)
pacman -S --needed mingw-w64-x86_64-openssl
```

Approximate disk cost: MSYS2 base (~600 MB) + toolchain (~500 MB) + Qt6 (~2 GB) = **~3 GB total**.

#### Verify the install

From the MSYS2 MinGW64 shell:

```bash
gcc --version      # x86_64-w64-mingw32-gcc 14.x or later
cmake --version    # 3.28 or later
qmake --version    # Qt version 6.x.x in /mingw64
openssl version    # OpenSSL 3.x
ninja --version    # 1.x
```

### 11.3 Repository setup

From a standard Windows `cmd` or PowerShell prompt (Git for Windows):

```cmd
git clone --recurse-submodules https://github.com/chrisbensch/AdaptixC2-Omni.git
cd AdaptixC2-Omni
```

If you already have a clone without submodules:

```cmd
git submodule update --init --recursive
```

**MSYS2 path adjustment.** If MSYS2 is not at `C:\msys64`, open `AdaptixC2/AdaptixClient/CMakeLists.txt` and change line 10 to match your actual MSYS2 prefix:

```cmake
if(WIN32)
    set(Qt6_DIR "D:/msys64/mingw64/lib/cmake")   # adjust prefix as needed
endif()
```

This is a local working-tree edit in the submodule. Do not commit it — the submodule tree must stay clean (see "Cross-cutting conventions" in CLAUDE.md).

### 11.4 Build

The upstream build script is at `AdaptixC2/AdaptixClient/build.bat`. Run it from a standard Windows `cmd` prompt (not from PowerShell or an MSYS2 bash shell — see gotcha #3 in §11.6):

```cmd
cd AdaptixC2\AdaptixClient
build.bat
```

Output lands in `AdaptixC2\AdaptixClient\dist\`:
- `AdaptixClient.exe`
- Qt6 DLLs and platform plugins (placed by `windeployqt`)
- MinGW runtime DLLs (copied explicitly by the script)

To run the client directly from the build host, launch `dist\AdaptixClient.exe`.

#### Manual equivalent (MSYS2 MinGW64 shell)

If `build.bat` is inconvenient, the same steps in bash:

```bash
cd AdaptixC2/AdaptixClient
cmake -S . -B cmake-build-release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build cmake-build-release --config Release

mkdir -p dist
mv cmake-build-release/AdaptixClient.exe dist/

cd dist
windeployqt.exe AdaptixClient.exe

# Copy MinGW runtime DLLs (adjust ICU version number if needed — see §11.6 gotcha #1)
for dll in \
  libwinpthread-1.dll libgcc_s_seh-1.dll libstdc++-6.dll \
  libfreetype-6.dll libharfbuzz-0.dll libmd4c.dll \
  libpng16-16.dll zlib1.dll libb2-1.dll libdouble-conversion.dll \
  libicuin78.dll libicuuc78.dll libicudt78.dll \
  libpcre2-16-0.dll libpcre2-8-0.dll \
  libbrotlidec.dll libbrotlicommon.dll \
  libzstd.dll libbz2-1.dll \
  libglib-2.0-0.dll libgraphite2.dll \
  libintl-8.dll libiconv-2.dll; do
  cp /mingw64/bin/$dll .
done
```

### 11.5 What the build does (CMakeLists.txt WIN32 path)

When CMake detects `WIN32` and `MINGW`, the following activates in addition to the common build:

| CMake block | Effect |
|---|---|
| `set(Qt6_DIR "C:/msys64/mingw64/lib/cmake")` | Points Qt6 find-package at the MSYS2 installation. |
| `set(OPENSSL_USE_STATIC_LIBS TRUE)` | OpenSSL is statically embedded in `AdaptixClient.exe` — no OpenSSL DLLs to ship. |
| `-Wl,-subsystem,windows` | Suppresses the console window on launch. |
| `target_link_libraries ... wsock32 ws2_32 crypt32 iphlpapi netapi32 version winmm userenv dwmapi` | Windows system libraries for networking, crypto, API version, DWM compositor. |
| `-static-libgcc -static-libstdc++` | GCC and C++ runtime embedded in the exe. |
| `-Wl,-Bstatic -lwinpthread -Wl,-Bdynamic` | winpthread statically linked; remaining deps dynamic. |

#### Why runtime DLLs are still needed despite static GCC

`-static-libgcc -static-libstdc++` embeds these runtimes into `AdaptixClient.exe` itself. However, the Qt6 DLLs (`Qt6Core.dll`, `Qt6Widgets.dll`, etc.) were compiled by MSYS2 with **dynamic** GCC runtime linkage. Those DLLs still require `libgcc_s_seh-1.dll` and `libstdc++-6.dll` to be present at runtime alongside them.

#### Runtime DLL reference

| DLL | Provides |
|---|---|
| `libwinpthread-1.dll` | POSIX thread shim (winpthread) |
| `libgcc_s_seh-1.dll` | GCC runtime (SEH exception model) |
| `libstdc++-6.dll` | C++ standard library |
| `libfreetype-6.dll` | Font rendering |
| `libharfbuzz-0.dll` | Text shaping |
| `libmd4c.dll` | Markdown parser (Qt internals) |
| `libpng16-16.dll` | PNG decoding |
| `zlib1.dll` | zlib compression |
| `libb2-1.dll` | BLAKE2 hash |
| `libdouble-conversion.dll` | Float↔string conversion (Qt) |
| `libicuin78.dll` | ICU Unicode — internationalization |
| `libicuuc78.dll` | ICU Unicode — common |
| `libicudt78.dll` | ICU Unicode — data |
| `libpcre2-16-0.dll` | PCRE2 regex (UTF-16) |
| `libpcre2-8-0.dll` | PCRE2 regex (UTF-8) |
| `libbrotlidec.dll` | Brotli decompression |
| `libbrotlicommon.dll` | Brotli common |
| `libzstd.dll` | Zstandard compression |
| `libbz2-1.dll` | bzip2 |
| `libglib-2.0-0.dll` | GLib (HarfBuzz dependency) |
| `libgraphite2.dll` | Graphite font engine |
| `libintl-8.dll` | gettext internationalization |
| `libiconv-2.dll` | Character encoding conversion |

### 11.6 Verification checklist

1. `dir dist\AdaptixClient.exe` — file exists and is non-zero.
2. `dist\AdaptixClient.exe --help` (or just launch it) — window appears, no missing DLL error dialog.
3. Connect to `https://<server>:4321/endpoint` — login dialog appears.
4. Listener creation dialog shows all 9 extenders; AxScript Manager shows `extension-kit.axs` and `kh_modules.axs` loaded.

### 11.7 Known issues and gotchas

1. **ICU DLL version number changes.** The names `libicuin78.dll` / `libicuuc78.dll` / `libicudt78.dll` embed the ICU version (`78`). MSYS2 updates will bump this (to `79`, `80`, etc.). When `build.bat` fails copying these files, find the current version with:
   ```bash
   pacman -Qi mingw-w64-x86_64-icu | grep Version
   ```
   Then update the three ICU filenames in `build.bat` and in the bash equivalent above.

2. **MSYS2 path is hard-coded in CMakeLists.txt.** `C:/msys64/mingw64/lib/cmake` is set unconditionally for `WIN32` at line 10. Installation to any other path requires a local edit to the submodule file. Keep the submodule tree clean — do not commit this change.

3. **Run `build.bat` from `cmd.exe`, not from PowerShell or an MSYS2 bash shell.** The script uses Windows `copy`/`move` with Windows path separators. PowerShell misinterprets bare `.` in `copy src dst.` as a path component; MSYS2 bash translates backslashes and rejects drive letters. A standard `cmd.exe` prompt is the correct environment.

4. **`windeployqt` must be the MSYS2 MinGW64 binary.** `build.bat` prepends `C:\msys64\mingw64\bin` to `PATH` to ensure this. If a second Qt installation (official Qt installer, vcpkg) is already on the system PATH, it may shadow the MSYS2 `windeployqt` and deploy mismatched DLLs. Clear the system PATH of other Qt entries before running the build, or invoke `build.bat` from a fresh `cmd` with no other Qt present.

5. **`build.bat` syntax defect in lines 17–19 (upstream).** Each of the first three `copy` commands has a period glued to the closing quote (`copy "...\libwinpthread-1.dll".`), which Windows `copy` misinterprets as the destination path. Lines 20–22 repeat the same copies with a corrected trailing space + `.` and succeed; the net result is correct. This defect should be fixed in any improved build script written for this workspace.

6. **No console window in release builds.** `-Wl,-subsystem,windows` hides the console. `printf`/`qDebug()` output and crash messages will not appear in a terminal. For a debug build, temporarily remove this linker flag by configuring with `-DCMAKE_BUILD_TYPE=Debug` and setting `CMAKE_EXE_LINKER_FLAGS` to omit `-Wl,-subsystem,windows`.

7. **No code signing.** The exe and DLLs are unsigned. Windows Defender SmartScreen will block first-run execution on a clean system ("Windows protected your PC"). Right-click → "Run anyway" clears the block for that session. For team distribution, sign with a code-signing certificate and optionally submit for reputation to suppress SmartScreen.

8. **Vendored Konsole terminal widget is Windows-compatible.** `AdaptixClient/Libs/Konsole/` contains no X11, PTY, or POSIX `#ifdef` guards. The widget renders VT102 escape sequences over a data channel from `TerminalWorker.cpp` and ships `windows_conpty.keytab` / `windows_winpty.keytab` keybinding tables. No porting work is needed for the terminal widget.

---

---

## 12. CI: GitHub Actions build workflow

### 12.1 What it does

`.github/workflows/build.yml` builds the runtime image on every PR, every push to `main`, and a weekly cron (Mondays 06:17 UTC). The schedule is the main defense against silent upstream submodule drift — if a transitive dep moves and breaks the build, CI flags it before someone tries to rebuild for an engagement.

Two parallel jobs in a `fail-fast: false` matrix:

| Runner | Arch |
|---|---|
| `ubuntu-latest` | linux/amd64 |
| `ubuntu-24.04-arm` | linux/arm64 |

Per job, the steps are:

1. **Checkout** with `submodules: recursive` (so all four pinned upstream repos are present).
2. **`docker/setup-buildx-action@v3`** — registers the buildx builder.
3. **Build** — `docker compose --profile build build`. Host-arch, just like a local build.
4. **Smoke test** — `docker run -d` the freshly-built image with `-p 4321:4321`, a writable `./data` mount, and `ADAPTIX_TEAMSERVER_PASSWORD=ci-smoke-pw`. Then poll `docker inspect --format '{{.State.Health.Status}}'` every 3 seconds up to 30 iterations (~90s budget) waiting for the HEALTHCHECK to report `healthy`. On failure, dumps `docker logs` for diagnosis.
5. **Teardown** — `docker rm -f` the smoke container in an `if: always()` step so the runner is clean for the next job.

Total wall time: roughly 12–18 minutes per arch (the build dominates; the smoke test is sub-90s once the image is up).

### 12.2 Why arm64 in CI

`ubuntu-24.04-arm` is a real arm64 runner — no QEMU emulation. This is the only place the arm64 path gets exercised on a known-clean machine, so it catches:

- The nanodump host-strip bug on arm64 hosts (the symptom the §6.3 patch was written for — if the patch ever stops applying, CI fails here first).
- Anything Kharon's `clang -target x86_64-w64-mingw32` does that's host-arch-sensitive.
- Subtle differences in how `mingw-w64` packages behave between Debian arm64 and amd64 repos.

If GitHub-hosted arm64 runners ever go away, the fallback is buildx with `--platform=linux/arm64` under QEMU — slower (~3x) but functionally equivalent.

### 12.3 What it doesn't cover

- **Client builds.** Linux AppImage and macOS bundle and Windows exe are not built in CI. The AppImage could be added (it has a self-contained Dockerfile stage); macOS and Windows would need GitHub-hosted runners on those OSes. Out of scope for now.
- **Beacon-spawn end-to-end.** Smoke test only verifies the teamserver responds on TLS; it doesn't connect a client or check that listeners/agents register. Adding a client smoke would require a non-trivial harness (headless Qt or an `axc2`-speaking test client).
- **Submodule SHA freshness.** Cron catches *breakage* from upstream drift, not *availability* of newer upstream. A separate Dependabot-style bot or a manual `git submodule status` review is what surfaces "you're N commits behind upstream."

### 12.4 When CI fails

The most common failure modes, in order of historical likelihood:

1. **`git apply` of `extension-kit-nanodump-host-strip.patch` fails.** Upstream has changed the surrounding Makefile lines. Regenerate the patch (see §10 step 2).
2. **A new BOF subdir appears in `Extension-Kit/` that's not in the strict list in `Dockerfile`'s `build-bofs` stage.** Add it to the list, or move it to the best-effort pass if it has network deps.
3. **Smoke health-check never reports healthy.** Usually means the server crashed at startup — check the `docker logs` dump CI prints on timeout. Common cause: an upstream profile-schema change that broke the entrypoint's `sed` substitutions.
4. **arm64 job times out while amd64 passes.** The 45-minute job timeout is generous, but the first build on a runner has no buildx layer cache. If this becomes chronic, add a `actions/cache` step keyed on submodule SHAs to persist intermediate layers.

---

End of blueprint. If you (future Claude) need to reconstruct any specific file, prefer reading it from disk first — only fall back to recreating from this document if the file is missing.
