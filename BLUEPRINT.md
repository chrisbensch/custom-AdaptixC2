# BLUEPRINT.md — Unified AdaptixC2 Build Integration

> **Purpose.** This file is the complete, self-contained recipe for assembling the four sibling repos in this workspace into a runnable AdaptixC2 server image plus distributable GUI clients. Hand it to a fresh-context Claude (or human) and they should be able to reproduce the build against either the same upstream snapshots or a newer set, applying the changes verbatim or adapting them where upstream has moved.

---

## 1. Workspace shape

The workspace itself is a git repo. The four upstream projects are git **submodules** pinned to the SHAs in §2; we don't own those repos, so customizations live in `patches/` (applied at build time) rather than committed inside them. Reproduce on another machine with `git clone --recurse-submodules <workspace-repo-url>`.

```
/Users/chrisbensch/zTemp/claude-adaptixc2/
├── .git/                 ← workspace repo
├── .gitmodules           ← submodule URLs + paths (commits pinned via gitlinks in §2)
├── .gitignore            ← excludes data/, AdaptixClient-dist/, build/, .claude/, *.log
│
├── AdaptixC2/            ← submodule: Adaptix-Framework/AdaptixC2  (server + Qt6 client)
├── Extension-Kit/        ← submodule: Adaptix-Framework/Extension-Kit  (BOFs)
├── Kharon/               ← submodule: entropy-z/Kharon  (PIC agent + HTTP listener)
├── PostEx-Arsenal/       ← submodule: entropy-z/PostEx-Arsenal  (Kharon-flavored modules)
│
├── BLUEPRINT.md          ← this file
├── CLAUDE.md             ← context for future Claude conversations (separate concern)
├── Dockerfile            ← unified server build (multi-stage, linux/amd64)
├── docker-compose.yml    ← services for build/runtime/build-client
├── profile.kharon.yaml   ← merged server profile, 9 extenders + 2 axscripts
├── build-client-macos.sh ← native macOS .app build script (Apple Silicon arm64)
│
├── patches/                              ← build-time patches against submodules
│   └── adaptixclient-macos-bundle.patch  ← see §5.5 / §6.1
│
├── data/                 ← created at runtime; SQLite DB persistence (bind mount, gitignored)
└── AdaptixClient-dist/   ← created during builds; AppImage and .app land here (gitignored)
```

Host: macOS Apple Silicon (arm64). Server image targets **linux/amd64** (QEMU emulation). Linux client AppImage targets **x86_64**. macOS client targets **arm64 only**.

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

Multi-stage; build context = workspace root; every stage `--platform=linux/amd64`.

- `base` — Debian-based golang image with `mingw-w64 g++-mingw-w64 gcc g++ make build-essential libssl-dev zlib1g-dev nasm clang llvm python3 git wget ca-certificates`. Clones `Adaptix-Framework/go-win7` into `/usr/lib/go-win7` and symlinks runtime headers. Sets `GOEXPERIMENT=jsonv2,greenteagc`.
- `build-bofs` — `COPY Extension-Kit /src/Extension-Kit && make -C /src/Extension-Kit` then `COPY PostEx-Arsenal /src/PostEx-Arsenal && make -C /src/PostEx-Arsenal/bofs`. SAL-BOF's `python3 download_vulnerable_driver_list.py` is allowed to fail offline; rest of BOFs still build.
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

The full file is at `/Users/chrisbensch/zTemp/claude-adaptixc2/Dockerfile` (143 lines). Do not duplicate here — copy verbatim or regenerate from this spec.

### 5.2 `/docker-compose.yml`

Three services, each `platform: linux/amd64`:

```yaml
name: adaptixc2-unified

services:
  builder:                                     # profile: build  — wraps `docker build`
    profiles: ["build"]
    platform: linux/amd64
    build:
      context: .
      dockerfile: Dockerfile
      target: runtime
      platforms: [linux/amd64]
    image: adaptixc2-unified:latest
    container_name: adaptixc2-builder
    command: ["true"]

  server:                                      # profile: runtime — runs the server
    profiles: ["runtime"]
    platform: linux/amd64
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

Native macOS arm64 build. 163 lines; full file at workspace root. Key steps:

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

Build-time patches against submodule trees we don't own. Each is a unified-diff file that the relevant build script `git apply`s on entry and reverts on exit (via `trap`), so the submodule working tree stays clean between builds — preserving the §6.2 rule.

| Patch | Target | Applied by |
|---|---|---|
| `adaptixclient-macos-bundle.patch` | `AdaptixC2/AdaptixClient/CMakeLists.txt` | `build-client-macos.sh` |

When upstream drifts and a patch stops applying, the apply script fails fast with a clear message. Regenerate the patch from a freshly-rebased manual edit, then commit the new `.patch` file. Don't accumulate patches: if a workaround can be replaced by an upstream change, push for that instead.

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

### 6.2 No other persistent patches

These changes are made **at build time inside the Dockerfile** and do not touch the source tree:

- `AdaptixC2/AdaptixServer/extenders/agent_kharon` — populated by `COPY Kharon/agent_kharon …` in the Dockerfile.
- `AdaptixC2/AdaptixServer/extenders/listener_kharon_http` — populated by `COPY Kharon/listener_kharon_http …`.
- `AdaptixC2/AdaptixServer/go.work` — `go work use` appends two entries during the build. (`setup_kharon.sh` is the upstream-provided script doing this; we inline the same logic.)
- `AdaptixC2/AdaptixServer/profile.yaml` — replaced inside the runtime image by the workspace-root `profile.kharon.yaml`.

These should NOT be committed to a submodule working tree — keep them clean so `git status` in any submodule stays empty between builds. The `patches/` mechanism (§5.5) and the `trap`-based revert in `build-client-macos.sh` enforce this for the one persistent diff we have; everything else is Dockerfile-side.

## 7. Build commands

**First-time setup on a fresh machine:**

```bash
git clone --recurse-submodules <workspace-repo-url> claude-adaptixc2
cd claude-adaptixc2
# If you forgot --recurse-submodules: git submodule update --init --recursive
```

From `/Users/chrisbensch/zTemp/claude-adaptixc2/`:

```bash
# Server image  (≈13 min on Apple Silicon under QEMU; 282 MB)
docker compose --profile build build

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
1. `docker image inspect adaptixc2-unified:latest --format '{{.Os}}/{{.Architecture}}'` → `linux/amd64`
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
9. **arm64 host** building amd64: relies on Docker Desktop's QEMU emulation (binfmt_misc). On a Linux arm64 host, ensure `qemu-user-static` is registered (`docker run --rm --privileged tonistiigi/binfmt --install all`).

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
2. **Diff-check the patch site** at `AdaptixC2/AdaptixClient/CMakeLists.txt`:
   - Find `add_executable(AdaptixClient …)`. If upstream now adds `MACOSX_BUNDLE` or sets bundle props themselves, retire `patches/adaptixclient-macos-bundle.patch` and harmonize.
   - Otherwise re-apply the patch manually, fix any rejected hunks, and regenerate it: `git -C AdaptixC2 diff -- AdaptixClient/CMakeLists.txt > patches/adaptixclient-macos-bundle.patch`. Bump `MACOSX_BUNDLE_BUNDLE_VERSION` inside the patch to match the new release tag.
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
