# BLUEPRINT.md — Unified AdaptixC2 Build Integration

> **Purpose.** This file is the complete, self-contained recipe for assembling the four sibling repos in this workspace into a runnable AdaptixC2 server image plus distributable GUI clients. Hand it to a fresh-context Claude (or human) and they should be able to reproduce the build against either the same upstream snapshots or a newer set, applying the changes verbatim or adapting them where upstream has moved.

---

## 1. Workspace shape

The workspace itself is a git repo. The four upstream projects are git **submodules** pinned to the SHAs in §2; we don't own those repos, so customizations live in `patches/` (applied at build time) rather than committed inside them. Reproduce on another machine with `git clone --recurse-submodules <workspace-repo-url>`.

```
custom-AdaptixC2/         ← workspace root (this directory)
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
├── profile.kharon.yaml   ← merged server profile, 9 extenders + 2 axscripts
├── build-client-macos.sh ← native macOS .app build script (Apple Silicon arm64)
│
├── patches/                                       ← build-time patches against submodules
│   ├── adaptixclient-macos-bundle.patch           ← see §5.5 / §6.1
│   └── extension-kit-nanodump-host-strip.patch   ← see §5.5 / §6.3
│
├── data/                 ← created at runtime; SQLite DB persistence (bind mount, gitignored)
└── AdaptixClient-dist/   ← created during builds; AppImage and .app land here (gitignored)
```

Host: macOS Apple Silicon (arm64). The server image builds for the **host architecture by default** — native arm64 builds on Apple Silicon (≈6 min), or set `DOCKER_DEFAULT_PLATFORM=linux/amd64` to force amd64 under QEMU emulation (≈13 min). Verified to build and run on both arches. The Linux client AppImage stays pinned to **linux/amd64** because it produces an x86_64 AppImage by definition. macOS client targets **arm64 only**.

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
| Qt (Linux client AppImage) | **6.9.2** (via aqtinstall, from existing AdaptixC2/Dockerfile build-client stage) | Reused as-is from upstream. |
| Qt (macOS client) | Homebrew **qt@6** (currently 6.11.x) | Native arm64; works because of the `if(APPLE)` CMake patch. |
| Debian base (build) | `bookworm` | Matches upstream. |
| Ubuntu base (Linux client) | `22.04` | From AdaptixC2/Dockerfile build-client stage. |

## 4. Decisions baked into the integration

These were resolved up-front via `AskUserQuestion`. Repeat them if re-running the planning.

1. **Server runtime layout:** all artifacts (server, extenders, BOFs, axscripts, profile, kharon template) baked into the runtime image. No host-mounted scripts/BOFs.
2. **profile.yaml:** ship a finalized `profile.kharon.yaml` — no envsubst at start, no template mounting.
3. **PostEx-Arsenal `postex_sc/`:** trust the checked-in `.bin` files; do not rebuild in the container (saves clang/llvm/nasm runtime in postex_sc subdirs).
4. **macOS bundle:** patch `AdaptixClient/CMakeLists.txt` with `MACOSX_BUNDLE` properties guarded by `if(APPLE)`. Build natively via Homebrew Qt, then `macdeployqt` + RPATH cleanup + ad-hoc resign.
5. **macOS arch:** Apple Silicon **arm64 only** (no universal binary).
6. **Linux AppImage delivery:** add a `client-linux` service to the workspace-root `docker-compose.yml` that points at `AdaptixC2/Dockerfile`'s existing `build-client` stage. No duplication.

## 5. Files added at workspace root

### 5.1 `/Dockerfile` (server image)

Multi-stage; build context = workspace root; **builds for the host architecture** (no `--platform` pin on `FROM` lines). Pass `--platform=linux/amd64` to docker build (or set `DOCKER_DEFAULT_PLATFORM`) to force a specific arch — verified working on both arm64 and amd64.

- `base` — Debian-based golang image with `mingw-w64 g++-mingw-w64 gcc g++ make build-essential libssl-dev zlib1g-dev nasm clang llvm python3 git wget ca-certificates`. Clones `Adaptix-Framework/go-win7` into `/usr/lib/go-win7` and symlinks runtime headers. Sets `GOEXPERIMENT=jsonv2,greenteagc`.
- `build-bofs` — `COPY Extension-Kit /src/Extension-Kit && COPY patches /src/patches && git apply /src/patches/extension-kit-nanodump-host-strip.patch && make -C /src/Extension-Kit` then `COPY PostEx-Arsenal /src/PostEx-Arsenal && make -C /src/PostEx-Arsenal/bofs`. The patch fixes an upstream nanodump Makefile bug that breaks on non-amd64 hosts (see §6.3). SAL-BOF's `python3 download_vulnerable_driver_list.py` is allowed to fail offline; rest of BOFs still build.
- `build-server`:
  1. `COPY AdaptixC2 /src/AdaptixC2`
  2. `COPY Kharon/agent_kharon /src/AdaptixC2/AdaptixServer/extenders/agent_kharon`
  3. `COPY Kharon/listener_kharon_http /src/AdaptixC2/AdaptixServer/extenders/listener_kharon_http`
  4. `cd /src/AdaptixC2/AdaptixServer && go work use ./extenders/agent_kharon ./extenders/listener_kharon_http && go work sync`
  5. `make -C /src/AdaptixC2 server-ext` — builds adaptixserver + all 9 extender plugins (Adaptix's Makefile `EXTENDER_DIRS := $(shell find AdaptixServer/extenders -maxdepth 1 -type d ...)` auto-discovers Kharon's two new extenders, no Makefile edit needed).
  6. `make -C /src/AdaptixC2/AdaptixServer/extenders/agent_kharon agent` — explicit (also runs as part of the agent_kharon default `all` target via step 5; safe redundancy).
  7. Re-sync any in-source `dist/` artifacts back into `/src/AdaptixC2/dist/extenders/agent_kharon/`.
- `runtime` — minimal `debian:bookworm-slim` with `ca-certificates openssl`. COPYs:
  - `/src/AdaptixC2/dist/` → `/app/` (server, ssl_gen.sh, 404page.html, all 9 extenders)
  - `/src/Extension-Kit` → `/app/Extension-Kit`
  - `/src/PostEx-Arsenal` → `/app/PostEx-Arsenal`
  - workspace `profile.kharon.yaml` → `/app/profile.yaml` (overwrites upstream default)
  - `Kharon/listener_kharon_http/profiles/template.json` → `/app/kharon-template.json`
  - generates `/app/entrypoint.sh` inline (cert-gen on first run, then exec server)
- `EXPOSE 4321 80 443 8080 8443`. `ENTRYPOINT /app/entrypoint.sh`. `CMD /app/adaptixserver -profile /app/profile.yaml`.

The full file is at `./Dockerfile` (149 lines). Do not duplicate here — copy verbatim or regenerate from this spec.

### 5.2 `/docker-compose.yml`

Three services. The `builder` and `server` services have **no platform pin** (host arch by default; override with `DOCKER_DEFAULT_PLATFORM`). Only `client-linux` is pinned to `linux/amd64` because the AppImage it produces is x86_64 by definition.

```yaml
name: adaptixc2-unified

services:
  builder:                                     # profile: build  — wraps `docker build`
    profiles: ["build"]
    build:
      context: .
      dockerfile: Dockerfile
      target: runtime
    image: adaptixc2-unified:latest
    container_name: adaptixc2-builder
    command: ["true"]

  server:                                      # profile: runtime — runs the server
    profiles: ["runtime"]
    image: adaptixc2-unified:latest
    container_name: adaptixc2-server
    network_mode: host
    volumes:
      - ./data:/app/data
    environment:
      - TZ=${TZ:-UTC}
    restart: unless-stopped

  client-linux:                                # profile: build-client — Linux AppImage
    profiles: ["build-client"]
    platform: linux/amd64
    build:
      context: ./AdaptixC2
      dockerfile: Dockerfile
      target: build-client
      platforms: [linux/amd64]
    image: adaptixc2-client-linux-builder:latest
    container_name: adaptixc2-client-linux-builder
    volumes:
      - ./AdaptixClient-dist:/client-dist-output
    command: sh -c "cp -r /client-dist/. /client-dist-output/"
```

`client-linux` deliberately reuses **`AdaptixC2/Dockerfile`**'s existing `build-client` stage (lines ≈21–121 in upstream): Qt 6.9.2 via aqtinstall, ubuntu:22.04, linuxdeployqt + appimagetool. No duplication — if upstream changes the stage, we inherit it.

### 5.3 `/profile.kharon.yaml`

Copy of `AdaptixC2/AdaptixServer/profile.yaml` with two diffs (relative to upstream default):

```diff
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
```

All other fields (Teamserver port 4321, endpoint `/endpoint`, default operator creds `operator1:pass1` / `operator2:pass2`, HttpServer + tls block) match upstream untouched. Operator should change passwords pre-deploy.

These paths resolve relative to `/app/` (server's CWD inside the container), which is exactly where `/app/Extension-Kit/` and `/app/PostEx-Arsenal/` are placed by the runtime stage. AxScript's `ax.script_dir()` resolves to the directory of the loaded `.axs` file — so `kh_modules.axs` finds `bofs/dist/*.x64.o` at `/app/PostEx-Arsenal/bofs/dist/*.x64.o`, and `extension-kit.axs` finds the per-subdir scripts.

### 5.4 `/build-client-macos.sh`

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

### 5.5 `/patches/`

Build-time patches against submodule trees we don't own. Each is a unified-diff file applied by the relevant build step. The macOS patch is applied/reverted via `trap` around the build (host filesystem); the Dockerfile patches are applied inside the container layer (so the host submodule tree never gets touched).

| Patch | Target | Applied by |
|---|---|---|
| `adaptixclient-macos-bundle.patch` | `AdaptixC2/AdaptixClient/CMakeLists.txt` | `build-client-macos.sh` (host, with auto-revert) |
| `extension-kit-nanodump-host-strip.patch` | `Extension-Kit/Creds-BOF/nanodump/Makefile` | `Dockerfile` `build-bofs` stage (container only) |

When upstream drifts and a patch stops applying, the apply script (or `docker compose build`) fails fast with a clear message. Regenerate the patch from a freshly-rebased manual edit, then commit the new `.patch` file. Don't accumulate patches: if a workaround can be replaced by an upstream change, push for that instead.

### 5.6 `/.dockerignore`

Excludes `**/.git`, `**/.gitmodules`, build outputs, and `.claude/` from every `docker build` context that uses the workspace root. The `**/.git` exclusion is **load-bearing**: each submodule on the host has a `.git` *file* that points (`gitdir: ../.git/modules/<name>`) into the parent repo's `.git/modules/`. Without `.dockerignore`, Docker COPYs that pointer file into the container, where the path it references doesn't exist — and `git apply` inside the container then fails with `fatal: not a git repository`. Excluding the file lets `git apply` operate on a plain directory (which it does fine; it doesn't actually need a repo).

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
- `AdaptixC2/AdaptixServer/profile.yaml` — replaced inside the runtime image by the workspace-root `profile.kharon.yaml`.

These should NOT be committed to a submodule working tree — keep them clean so `git status` in any submodule stays empty between builds. The `patches/` mechanism (§5.5), the `trap`-based revert in `build-client-macos.sh`, and the in-container `git apply` for §6.3 enforce this; everything else is Dockerfile-side.

### 6.3 `Extension-Kit/Creds-BOF/nanodump/Makefile` — host-arch strip fix

**Stored as `patches/extension-kit-nanodump-host-strip.patch`; applied inside the container by the Dockerfile's `build-bofs` stage. The host submodule tree is never modified.** The patch deletes one redundant line from upstream nanodump's Makefile:

```diff
 	@$(GCC) source/restore_signature.c -o scripts/restore_signature -static -s -Os
-	@$(STRIP_x64) --strip-all scripts/restore_signature
```

`scripts/restore_signature` is built by the **host** `gcc` (line 78), but upstream then strips it with `x86_64-w64-mingw32-strip` — a Windows cross-strip targeted at PE/COFF. On amd64 hosts the cross-strip happens to accept x86_64 ELF as a side effect of binutils' BFD library, so the bug is invisible. On arm64 hosts gcc produces aarch64 ELF, which the x86_64-targeted strip rejects with `Unable to recognise the format of the input file`, and the BOF build fails. The strip is also redundant: line 78's `-s` flag already strips at link time. Dropping line 79 fixes arm64 and is a no-op on amd64.

Worth pushing upstream as a one-line PR; until then, this patch keeps cross-arch builds working.

## 7. Build commands

**First-time setup on a fresh machine:**

```bash
git clone --recurse-submodules https://github.com/chrisbensch/custom-AdaptixC2.git
cd custom-AdaptixC2
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
```

## 8. Verification checklist

**Server image:**
1. `docker image inspect adaptixc2-unified:latest --format '{{.Os}}/{{.Architecture}}'` → `linux/arm64` or `linux/amd64` matching the build platform
2. `docker run --rm --entrypoint sh adaptixc2-unified:latest -c 'ls /app/extenders'` → 9 dirs incl. `agent_kharon`, `listener_kharon_http`
3. `docker run --rm --entrypoint sh adaptixc2-unified:latest -c 'ls /app/Extension-Kit/SAL-BOF/_bin /app/PostEx-Arsenal/bofs/dist | head'` → both populated
4. `docker compose --profile runtime up -d && docker compose --profile runtime logs --tail=50` → see `Generating self-signed certificates`, `Starting server -> https://0.0.0.0:4321/endpoint`, `The AdaptixC2 server is ready`
5. Connect a client to `https://<host>:4321/endpoint` with `operator1:pass1`. Listener creation dialog shows 9 extenders. AxScript Manager shows `extension-kit.axs` and `kh_modules.axs` already loaded.

**Linux AppImage:**
1. `file AdaptixClient-dist/AdaptixClient-x86_64.AppImage` → `ELF 64-bit LSB executable, x86-64, … stripped`
2. On a Linux x86_64 host (or arm64 host with `qemu-user-static`): `chmod +x AdaptixClient-x86_64.AppImage && ./AdaptixClient-x86_64.AppImage` opens the GUI.

**macOS .app:**
1. `file AdaptixClient-dist/AdaptixClient.app/Contents/MacOS/AdaptixClient` → `Mach-O 64-bit executable arm64`
2. `otool -l … | grep -A2 LC_RPATH | grep "path "` → only `@executable_path/../Frameworks` (no `/opt/homebrew/...`)
3. `codesign -dv …` → `Signature=adhoc`, `Identifier=io.adaptix.client`
4. **Portability:** `cp -R AdaptixClient.app /tmp/ && /tmp/AdaptixClient.app/Contents/MacOS/AdaptixClient` — must launch (don't just open the original location).
5. `open AdaptixClient-dist/AdaptixClient.app` — Gatekeeper may prompt on first launch (right-click → Open clears it).

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
3. **Diff-check `AdaptixC2/AdaptixServer/profile.yaml`** vs `profile.kharon.yaml`. If upstream added new HttpServer fields or a new default extender, mirror those into `profile.kharon.yaml` while keeping the 2 Kharon extender lines and 2 axscripts entries.
4. **Diff-check the AdaptixC2 client `build-client` Dockerfile stage**. If `QT_VERSION` or apt deps changed, the workspace `client-linux` service inherits the change for free (no edit).
5. **Diff-check `AdaptixC2/Makefile`** for the `EXTENDER_DIRS` glob and the `server-ext` target. Both are stable; if either is renamed, update `Dockerfile` step `make -C /src/AdaptixC2 server-ext`.
6. **Diff-check `Kharon/setup_kharon.sh`** for additional steps. Currently we inline only its 3 critical actions (copy two dirs, `go work use`, `make`). If new prerequisites appear (e.g. a `pip install` step), mirror them in the `base` or `build-server` stage.
7. **Diff-check `Kharon/agent_kharon/src_beacon/Makefile`** for new toolchain deps. The current set (`clang`, `nasm`, `llvm`, `mingw-w64`) covers it; if a future revision adds `python3-foo` or similar, add to `base` stage's apt list.
8. **Diff-check `Extension-Kit/Makefile`**. The recursive build pattern is stable; if new BOF subdirs appear, no Dockerfile change needed.
9. **Diff-check `PostEx-Arsenal/bofs/makefile`**. Same — recursive over `.cc` files. If `postex_sc/` ever ships pre-built binaries that change name, `kh_modules.axs` paths may shift; runtime test will catch it.
10. **Re-run the verification checklist (§8) end-to-end.**

---

End of blueprint. If you (future Claude) need to reconstruct any specific file, prefer reading it from disk first — only fall back to recreating from this document if the file is missing.
