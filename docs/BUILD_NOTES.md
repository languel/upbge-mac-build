# UPBGE local build on Apple Silicon — build & patch notes

Built and signed with the maintainer's Apple Developer ID for distribution to students who'd rather not compile UPBGE themselves. Patches and packaging scripts here are not upstream UPBGE — they're a local recipe to keep an Apple-silicon-native build current with master while the official UPBGE Mac releases (last stable: 0.5.0) catch up. PRs welcome at the upstream <https://github.com/UPBGE/upbge>; long-form discussion belongs there.

These notes capture the recipe used to build UPBGE master (Blender 5.2.0 Alpha) natively on an Apple-silicon Mac running macOS 26.4 with Apple Clang 21 and the AGXG17X (M5) Metal driver. Cold build is ~12.5 min on an 18-core M5 with 128 GB RAM after the precompiled libs are cached on disk; incremental rebuilds (typical source edit) are ~10–60 sec.

## TL;DR

```
brew install cmake ninja ccache
cd <repo-root>       # parent of the cloned upbge/ source tree
./build_launcher.command   # or just double-click in Finder
tail -f build.log
open build_darwin/bin/Blender.app
```

The launcher backgrounds `build.sh` and writes status to `build.status` and `build.phase`. Output lands in `<repo-root>/build_darwin/bin/`:

- `Blender.app` — the editor
- `Blenderplayer.app` — the standalone game runtime (UPBGE-specific)

## Layout

```
<repo-root>/
├── upbge/                          # git clone of https://github.com/UPBGE/upbge (with local patches, see below)
├── build_darwin/                   # CMake out-of-source build dir
│   └── bin/
│       ├── Blender.app
│       └── Blenderplayer.app
├── dist/                           # signed/notarized output of package_dmg.sh
│   ├── staging/                    #   intermediate signed copies (reused by --dmg-only)
│   └── upbge-<version>.dmg         #   shippable
├── build.sh                        # idempotent build script
├── build_launcher.command          # Finder-double-clickable wrapper that detaches build.sh
├── run_blender.command             # double-clickable wrapper that runs Blender with stderr captured
├── package_dmg.sh                  # sign + notarize + DMG pipeline
├── package_dmg.command             # Finder-double-clickable wrapper for sign-only
├── run_notarize.command            # one-shot wrapper used to drive --notarize end-to-end
│                                   #   (password is overwritten with a placeholder after each run)
├── extend_dmg_background.py        # rescales upstream background.tif → background_extended.tif
├── build.log                       # full build transcript (grows on each attempt)
├── build.status / build.phase / build.version / build.launched / build.pid
├── blender_run.log                 # stderr/stdout from run_blender.command (if used)
├── notarize.log                    # stdout/stderr from run_notarize.command (if used)
└── BUILD_NOTES.md                  # this file
```

## Prerequisites

- macOS with Apple Silicon. Xcode (full install, not just Command Line Tools) at `/Applications/Xcode.app`. Confirm with `xcode-select -p`.
- Homebrew at `/opt/homebrew/`.
- `build.sh` auto-installs `ninja` and `ccache` via Homebrew if missing. CMake also comes from Homebrew (`/opt/homebrew/bin/cmake`).
- Apple Clang 21+ (Xcode 17+).
- ~5 GB free for the `lib/macos_arm64` precompiled-libs submodule and ~2.5 GB for `build_darwin/`.

## Local patches

`git status` from inside `upbge/` will show these files as locally modified. Each patch is targeted and minimal so it's easy to rebase onto upstream as new master commits land.

| # | File | Why patched |
|---|------|-------------|
| 1 | `source/blender/makesdna/DNA_defs.h` | Apple Clang 21 rejects `[[deprecated]]` placement |
| 2 | `source/blender/draw/engines/eevee/eevee_shader.cc` | Crash guard on null deferred-light shader (NEW) |
| 3 | `source/blender/draw/engines/eevee/shaders/eevee_shadow_tracing_lib.glsl` | BSL-preprocessor incompatibility for Metal (NEW) |
| 4 | `scripts/addons_core/game_engine_add_basic_character.py` | 2.7x → 2.80+ API port |
| 5 | `scripts/addons_core/game_engine_publishing.py` | 2.7x → 2.80+ API port |
| 6 | `scripts/addons_core/bge_easyonline/__init__.py` | Python typo in `game_pre` handler |

### 1. `DNA_DEPRECATED` macro — Apple Clang 21 compatibility

**Symptom:** Build fails at compile time with `error: 'deprecated' attribute cannot be applied to types` on lines like `short blockhandler[8] DNA_DEPRECATED;` in `DNA_space_types.h`.

**Why:** Apple Clang 21 rejects the C++14 `[[deprecated]]` attribute when placed *after* an array declarator. The original macro maps `DNA_DEPRECATED` to `[[deprecated]]` for GCC/Clang/MSVC.

**Fix:** Switch to GCC-style attribute syntax which has more permissive placement rules:

```c
#  if defined(__GNUC__) || defined(__clang__)
#    define DNA_DEPRECATED __attribute__((deprecated))
#  elif defined(_MSC_VER)
#    define DNA_DEPRECATED __declspec(deprecated)
#  else
#    define DNA_DEPRECATED
#  endif
```

If a future upstream fix lands, drop the patch.

### 2. EEVEE deferred-light null-shader guard (crash prevention)

**Symptom:** Hard crash (segfault, EXC_BAD_ACCESS at `0x18`) when switching the viewport to Material Preview / Rendered, or when pressing P. Stack trace shows `GPU_shader_get_default_constant_state(nullptr)` called from `eevee::ShaderModule::request_specializations`.

**Why:** `gpu::StaticShader::is_ready()` (in `source/blender/gpu/GPU_shader.hh`) returns `true` when *either* the shader compiled successfully *or* compilation failed (`shader_ || failed_`). When the deferred-light shaders fail to compile (see patch #3), the EEVEE bitmask code believes `DEFERRED_LIGHTING_SHADERS` is "loaded" and calls `request_specializations`, which then dereferences a null `gpu::Shader *`. The TODO comment above the class even acknowledges the missing failed-compilation API.

**Fix:** In `source/blender/draw/engines/eevee/eevee_shader.cc`, add an early-return guard at the top of `ShaderModule::request_specializations`:

```cpp
for (int i : IndexRange(3)) {
  eShaderType type = eShaderType(DEFERRED_LIGHT_SINGLE + i);
  if (static_shader_get(type) == nullptr) {
    /* Diagnostic: write which shader failed (once per type). */
    /* …writes to /tmp/upbge_shader_fail.log… */
    return false;
  }
}
```

Returning `false` propagates back through `SET_FLAG_FROM_TEST(loaded_shaders, ready, DEFERRED_LIGHTING_SHADERS)` → clears the bit → `skip_render_ = true`. The viewport renders blank instead of crashing. The diagnostic block writes the failing shader's `info_name` to `/tmp/upbge_shader_fail.log` — useful when the underlying compilation issue (patch #3 or another) is unsolved.

This is a defense-in-depth patch — keep it even after the actual shader bug is fixed.

### 3. EEVEE shadow tracing kernel — BSL→MSL preprocessor workaround

**Symptom:** With patch #2 in place, the viewport doesn't crash but renders blank in Material Preview / Rendered. `gpu.shader | ERROR eevee_deferred_light_{single,double,triple}` lines in `blender_run.log` point to `eevee_shadow_tracing_lib.glsl:79:25` with `error: expected unqualified-id` on a line containing `ARRAY_T(float) ARRAY_V(...)`.

**Why:** The original UPBGE-specific PCF code uses a brace-initialized const array:

```glsl
const float kernel[9] = {1.0f, 2.0f, 1.0f,
                         2.0f, 4.0f, 2.0f,
                         1.0f, 2.0f, 1.0f};
```

Blender's BSL preprocessor (`run_preprocessor` in `source/blender/gpu/metal/mtl_shader.mm`) rewrites brace-initialized arrays into `ARRAY_T(type) ARRAY_V(...)` macro calls for cross-backend portability. The macros are defined in `gpu_shader_compat_msl.msl` and *should* expand to plain `{...}` for Metal — but in this codepath the macro definitions don't survive into the final MSL submitted to the Metal compiler. Result: Metal sees the literal text `ARRAY_T(float) ARRAY_V(...)` and rejects it.

The block is bracketed by a `/* End of UPBGE PCF path. */` comment — it's an UPBGE-only addition, not Blender's, so we can rewrite it freely.

**Fix:** Compute the 3×3 Gaussian weights inline instead of indexing an array:

```glsl
float weight = (xx == 0 ? 2.0f : 1.0f) * (yy == 0 ? 2.0f : 1.0f);
vis_sum += vis * weight;
```

Same numerical result (1, 2, 4 weights, sum = 16), no array literal for the BSL preprocessor to mangle. With this in place all three deferred-light shaders compile and EEVEE renders normally.

The deeper bug (BSL preprocessor swallowing `#define`s for the MSL backend) is upstream Blender territory — when they fix it, this workaround can be reverted to the original array form. Probably worth filing a Blender issue with a minimal repro if you want to push it upstream.

### 4. `Add Character` addon — Blender 2.7x → 2.80+ port

**File:** `scripts/addons_core/game_engine_add_basic_character.py`

**Symptom:** `Error: Registering panel class: 'addcharacter' has category 'Add Character'`. Panel never appears.

**Fix:**

- `bl_region_type = 'TOOLS'` → `'UI'` (TOOLS region was deprecated in 2.80; modern category-bearing panels live in the N-panel sidebar = `'UI'`).
- `scene.objects.active` → `view_layer.objects.active`.
- `scene.objects.link(obj)` → `scene.collection.objects.link(obj)`.
- `scene.cursor_location` → `scene.cursor.location`.
- `obj.select = True` → `obj.select_set(True)`.
- Drop the no-longer-existent `scene.render.engine = 'BLENDER_GAME'` assignment — UPBGE runs the BGE on top of EEVEE Next regardless of engine setting.
- Drop removed kwargs (`view_align=`, `layers=`) from `mesh.primitive_cone_add`.
- Switch from individual `register_class` calls to a `_classes` tuple loop.

The BGE-specific surface (`obj.game.physics_type`, `bpy.ops.logic.sensor_add`, etc.) is preserved — those still exist in UPBGE.

### 5. `Game Engine Publishing` addon — Blender 2.7x → 2.80+ port

**File:** `scripts/addons_core/game_engine_publishing.py`

**Symptom:** `module 'bpy.utils' has no attribute 'register_module'` at addon enable.

**Fix:**

- All 14 `PropertyGroup` declarations: `name = bpy.props.X(...)` → `name: bpy.props.X(...)` (annotation syntax required since 2.80).
- `bpy.utils.register_module/unregister_module` (removed in 2.80) → explicit `_classes` tuple + `bpy.utils.register_class` loop.
- All `layout.label("text")` → `layout.label(text="text")` (positional `text` removed).
- `layout.operator(idname, "text")` → `layout.operator(idname, text="text")`.
- Icon renames: `'ZOOMIN'` → `'ADD'`, `'ZOOMOUT'` → `'REMOVE'`.
- Drop the `scene.render.engine == "BLENDER_GAME"` poll check on `RENDER_PT_publish` — that engine is gone, so the check would always be false and the panel would never show. Now polls `context.scene is not None`.

### 6. `EasyOnline` addon — Python typo in `game_pre` handler

**File:** `scripts/addons_core/bge_easyonline/__init__.py:87`

**Symptom:** `TypeError: dirname() takes 1 positional argument but 2 were given` printed on every viewport load and on every P-press.

**Why:** Misplaced closing paren caused `script_name` to be passed as a 2nd positional arg to `os.path.dirname` instead of to `os.path.join`:

```python
# Before (broken):
path = os.path.dirname(os.path.join(os.path.abspath(__file__)),script_name)
# After:
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), script_name)
```

The intent is "join the addon's directory with the script filename" — which is what the corrected form does.

### `uplogic` — bundled at build time (not strictly a patch)

**File:** `build.sh` Phase 5 (post-build step).

`bge_netlogic` (Logic Nodes) depends on the PyPI package `uplogic`. Out of the box the addon shells out to `pip install uplogic` on first use, which works but requires online access on first launch. Phase 5 of `build.sh` pre-installs it via `ensurepip` + `pip install --upgrade uplogic` against the bundled Python:

```bash
PY="$BUILD_DIR/bin/Blender.app/Contents/Resources/5.2/python/bin/python3.13"
"$PY" -m ensurepip --upgrade
"$PY" -m pip install --upgrade uplogic
```

Idempotent — re-running `build_launcher.command` upgrades in place. Non-fatal: if `pip install` fails (no network, etc.) the build still succeeds and the addon's runtime auto-install fallback still works.

## How `build.sh` is structured

The script is idempotent — re-running picks up where it left off:

1. **Phase 0 — prereqs.** Logs Xcode, Clang, CMake, Python, disk, RAM, CPU. Bails out cleanly if a tool is missing. `brew install`s `ninja`/`ccache` if not present.
2. **Phase 1 — `make update`.** Skipped if `lib/macos_arm64` is already populated. First run pulls ~1.3 GB of precompiled platform libs.
3. **Phase 2 — configure + build.** `make ninja ccache BUILD_DIR=…` is the documented Blender fast path. CMake autodetects arm64 + Apple Clang. Failures capture the last 25 log lines into `build.status`.
4. **Phase 3 — locate output.** Looks for `Blender.app` in `build_darwin/bin/`.
5. **Phase 4 — smoke test.** Runs `Blender --version` and writes the result to `build.version`. Failure of this step is treated as a build failure.
6. **Phase 5 — bundle uplogic.** Pre-installs `uplogic` into the bundled Python (see addon section above). Non-fatal.

`build_launcher.command` is the Finder-double-clickable wrapper. It cd's to its own directory, `nohup`s `./build.sh` in the background, writes the PID to `build.pid`, and exits — so Terminal doesn't sit there for the duration.

## Re-running and incremental builds

After editing source:

```
./build_launcher.command          # incremental — ninja figures out what to rebuild
```

Typical incremental rebuild times after these patches landed:

- C++ source change in `eevee_shader.cc` → ~12 sec (one CXX compile + relink).
- GLSL source change in `eevee_shadow_tracing_lib.glsl` → ~12 sec (shader_tool regenerates a few embedded sources, two relinks).
- Python addon change → ~2 sec (file copy only).

To force a from-scratch reconfigure, delete `build_darwin/CMakeCache.txt`:

```
rm build_darwin/CMakeCache.txt
./build_launcher.command
```

To start completely fresh:

```
rm -rf build_darwin
./build_launcher.command
```

## Monitoring while it runs

Useful one-liners:

```
cat build.phase                                        # which phase
cat build.status                                       # SUCCESS / FAILED (or empty while running)
grep -oE '\[[0-9]+/[0-9]+\]' build.log | tail -1       # ninja progress, e.g. [6427/8091]
tail -f build.log                                      # full live transcript
```

A complete cold build emits ~8000 ninja steps. Most are CXX object compiles; the heavyweight units (Cycles, USD, FFmpeg wrappers) are toward the end so progress visibly slows above ~5500.

## Diagnostics — running Blender with full logging

When Blender is launched via Finder double-click, stderr goes to Console.app and is hard to retrieve. `run_blender.command` runs Blender from its own Terminal window and captures everything to `<repo-root>/blender_run.log`:

```
./run_blender.command          # double-click or run from Terminal
```

It launches with `--debug-gpu`, which in particular makes the Metal backend log `gpu.shader | ERROR <shader_name>` lines whenever a fragment/vertex/compute shader fails to compile, and prints the offending shader source location in the error.

Combined with patch #2's `/tmp/upbge_shader_fail.log` (which records each *deferred-light* shader that comes back null), this is enough to identify any future shader regression by name without attaching a debugger.

To launch with extra args from Terminal:

```
<repo-root>/build_darwin/bin/Blender.app/Contents/MacOS/Blender --debug-gpu 2>&1 | tee <repo-root>/blender_run.log
```

## Known runtime issues left unfixed

### `The Lightmapper` addon — `no module bgl`

`bgl` (the legacy direct-OpenGL bindings) was removed in Blender 4.0. `bge_thelightmapper/addon/utility/encoding.py` uses 15 bgl calls and `gui/Viewport.py` uses 4 — direct GL calls (`glActiveTexture`, `glBindTexture`, `glReadPixels`) plus `bgl.Buffer`. Porting to the modern `gpu` module is a real rewrite (different paradigm: `gpu.types.GPUTexture`, framebuffer reads into a typed buffer) rather than a sed. Best left to upstream until they ship a 4.x-compatible release; locally this addon is stuck.

### `Spring Bones` addon — guard miss on `game_pre`

`scripts/addons_core/game_engine_spring_bones.py:399` does `if not my_obj.script_created` without checking `my_obj is not None` first. Throws `AttributeError: 'NoneType' object has no attribute 'script_created'` on every P-press. Non-fatal — the BGE startup proceeds — but spammy. Trivial fix if you want it: `if my_obj is None or not my_obj.script_created`.

### OpenGL backend (`--gpu-backend opengl`) crashes on launch

macOS deprecated OpenGL years ago; the legacy 4.1 driver may not initialize at all under macOS 26's framework stack. This is independent of any Blender bug — using Metal is the right path forward on this machine.

## Distributing — sign + DMG

UPBGE doesn't ship a sign-and-package script in-tree (the official Blender pipeline lives in a separate `blender-buildbot` repo). `package_dmg.sh` here fills that gap. It produces a Developer-ID-signed DMG that students can double-click without fighting Gatekeeper.

```
./package_dmg.sh                                # sign-only, fast
NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./package_dmg.sh --notarize       # full pipeline (recommended)
./package_dmg.sh --source /Applications/        # use already-installed copy instead of build_darwin/bin
./package_dmg.sh --version 0.53-edu             # custom DMG version label (default derived from source)
./package_dmg.sh --dmg-only --notarize          # skip resigning, just rebuild + renotarize the DMG
./package_dmg.sh --plain-dmg                    # skip create-dmg's AppleScript layout step entirely
```

Output: `dist/upbge-<version>.dmg`

### Pipeline

1. **Auto-detects** the first `Developer ID Application: ...` cert in your default keychain via `security find-identity`. Errors out with setup instructions if none is found.
2. **Stages** copies of `Blender.app` and `Blenderplayer.app` into `dist/staging/` — never signs in place. Strips quarantine xattrs.
3. **Signs nested binaries** explicitly. `codesign --deep` is unreliable for Python C extensions (`.so`) and embedded `.dylib`s, so the script `find`s and signs them itself before signing the outer bundle.
4. **Signs the appex** (`Blender.app/Contents/PlugIns/blender-thumbnailer.appex`) with the sandbox entitlements from `upbge/release/darwin/thumbnailer_entitlements.plist`.
5. **Signs the outer apps** with hardened runtime (`--options runtime`) and the main entitlements from `upbge/release/darwin/entitlements.plist` — this enables JIT for Python ctypes, allows unsigned dylib plugins, and grants mic/camera access for Python scripts.
6. **Notarizes** (when `--notarize`): zips each `.app`, submits via `xcrun notarytool submit --wait`, then `xcrun stapler staple` attaches the ticket so it works offline. Auth: env-var `NOTARY_PASSWORD` is the working path on macOS 26 (see "notarytool keychain bug" below); falls back to keychain profile `UPBGE_NOTARY` if env-var is unset.
7. **Idempotent on already-stapled apps**: `notarize_app` calls `xcrun stapler validate` first and skips the upload if the ticket is already attached. Lets you retry the DMG step without re-uploading 320 MB to Apple.
8. **Builds the DMG** via `create-dmg` (polished UI with rescaled background — see "DMG layout" below) or falls back to plain `hdiutil` automatically if create-dmg's AppleScript step times out.
9. **Signs and notarizes the DMG itself** so the download dialog also has a clean signature.

### One-time setup

#### 1. Developer ID Application certificate

Check what you already have:

```
security find-identity -v -p codesigning
```

If you see a line containing `Developer ID Application: <Your Name> (TEAMID)`, you're set. If not (or it lists `Apple Development` / `Apple Distribution` only — those are for Xcode/App Store, not stand-alone distribution), create one:

1. Apple Developer → Certificates, Identifiers & Profiles → Certificates → `+` button.
2. Choose **Developer ID Application** (NOT "Developer ID Installer", NOT "Apple Distribution").
3. It asks for a CSR. Open Keychain Access → menu → Certificate Assistant → Request a Certificate from a Certificate Authority. Save to disk. Upload the resulting `.certSigningRequest` file.
4. Download the issued `.cer` and double-click. It installs into your login keychain.
5. Re-run `security find-identity -v -p codesigning` to confirm.

`xcrun notarytool` and `codesign` will both auto-discover it from there.

#### 2. (Notarization only) App-specific password

Generate one at <https://account.apple.com/account/manage> → Sign-In and Security → App-Specific Passwords. They're 16 lowercase letters split into 4 groups by hyphens. They don't expire unless you revoke them; revoke and rotate after each release if you're cautious.

**On macOS 26, pass it via env var, not keychain.** `xcrun notarytool store-credentials` reports success but the credential isn't actually findable by `notarytool submit` afterwards (see "notarytool keychain bug" in Troubleshooting). Just export the password:

```
NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./package_dmg.sh --notarize
```

The script defaults `NOTARY_APPLE_ID` to `your-apple-id@example.com` and auto-derives `NOTARY_TEAM_ID` from the signing cert's `(TEAMID)`. Override with env vars of the same name if needed.

If you'd rather use a keychain profile (works on older macOS, may work on yours):

```
xcrun notarytool store-credentials UPBGE_NOTARY \
    --apple-id your-apple-id@example.com --team-id YOURTEAMID \
    --password xxxx-xxxx-xxxx-xxxx \
    --keychain ~/Library/Keychains/login.keychain-db
```

Then run `./package_dmg.sh --notarize` with no env var. Verify it actually persisted with `security find-generic-password -s 'com.apple.gke.notary.tool' -a 'UPBGE_NOTARY'` before relying on it — the success message lies on macOS 26.

#### 3. (DMG polish only) `create-dmg` + Finder Automation

```
brew install create-dmg
```

First time you run a DMG with `create-dmg`, macOS 26 prompts Terminal to control Finder for the icon-layout AppleScript. If you miss the prompt the AppleScript times out (`-1712`) and the script auto-falls back to a plain `hdiutil` DMG. To enable the polished layout: **System Settings → Privacy & Security → Automation → Terminal → enable Finder**, then re-run with `--dmg-only` (skips re-signing).

### DMG layout

Window: 720×480 pt. Background: `upbge/release/darwin/background_extended.tif`, generated by `extend_dmg_background.py` — it rescales the upstream `background.tif` (1080×700 px, designed for Blender's smaller 540×350 pt window) to 1440×960 px so it fills the UPBGE window edge-to-edge at retina @2x. Re-run `python3 extend_dmg_background.py` only if you change the upstream background or the window size.

Icon coordinates (in `package_dmg.sh`, points from top-left):

| Slot                 | (x, y)     |
| -------------------- | ---------- |
| `Blender.app`        | (180, 200) |
| `Applications` link  | (540, 200) |
| `Blenderplayer.app`  | (360, 360) |

### Verifying the result

```
spctl -a -t open --context context:primary-signature -v dist/upbge-<version>.dmg
codesign -dvv dist/staging/Blender.app
xcrun stapler validate dist/staging/Blender.app   # only meaningful if --notarize was used
```

A signed-but-not-notarized build: students see "Apple cannot verify ... is free of malware" with no Open button — they have to right-click → Open the first time. A notarized + stapled build: students see "downloaded from the internet, are you sure?" — normal flow.

### Iterating on the DMG layout without re-notarizing

Notarization applies to the bytes of the DMG, so any change to background, icon positions, or window dimensions invalidates the signature. But you can iterate cheaply by skipping `--notarize` until the layout is final.

**Fast inner loop (~30 sec/cycle):**

1. Edit one of:
   - `upbge/release/darwin/background_extended.tif` — drop in a new image (1440×960 px to fill the window at retina). Or edit `extend_dmg_background.py` and re-run it to regenerate from a different source.
   - Icon coordinates in `package_dmg.sh` — `--icon "Blender.app" X Y`, `--app-drop-link X Y`, `--icon "Blenderplayer.app" X Y`.
   - Window size in `package_dmg.sh` — `--window-size W H`. (If you change this, also rerun `extend_dmg_background.py` so the bg matches at retina @2x.)
2. Run `./package_dmg.sh --dmg-only` (no `--notarize`).
3. `open dist/upbge-<version>.dmg` and inspect.
4. Repeat until happy.

The DMG is signed but unnotarized during iteration — fine for local mounting because macOS only enforces notarization on quarantined files (i.e., things downloaded from a browser).

**Final pass once layout is good:**

```
NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./package_dmg.sh --dmg-only --notarize
```

Apps stay stapled and skip; only the DMG gets resubmitted. Single ~5-minute Apple round-trip, no app re-upload.

**What you cannot skip.** There's no way to mutate an already-notarized DMG and keep its notarization. Apple's ticket binds to a specific content hash. Even `hdiutil convert -format UDRW` to mount-and-edit means a new hash on conversion back. `--dmg-only --notarize` is the shortest valid path.

### Troubleshooting

**`notarytool` keychain bug on macOS 26**: `xcrun notarytool store-credentials UPBGE_NOTARY ...` returns "Credentials saved successfully" and Apple validates the password, but `xcrun notarytool submit --keychain-profile UPBGE_NOTARY` later fails with `No Keychain password item found for profile: UPBGE_NOTARY`. Diagnostics: `security find-generic-password -s 'com.apple.gke.notary.tool' -a 'UPBGE_NOTARY'` returns `could not be found` — the credential never landed in any keychain that `notarytool submit` searches. Workaround: pass the password as `NOTARY_PASSWORD` env var; `package_dmg.sh` routes around the keychain entirely when that's set. This was the path that finally worked for the 0.5.2-arm64 release.

**`create-dmg` fails with `Finder got an error: AppleEvent timed out. (-1712)`**: The polished-DMG step uses AppleScript to ask Finder to lay out icons; that AppleEvent times out on macOS 26 the first time Terminal hasn't been pre-granted Finder Automation permission. The script auto-falls back to a plain `hdiutil` DMG so you still get a shippable artifact. To get the polished version: System Settings → Privacy & Security → Automation → Terminal → enable Finder, then re-run with `--dmg-only` (skips re-signing). Or pass `--plain-dmg` to skip create-dmg entirely — the resulting DMG is functional, just no background image / fancy icon arrangement.

**Background doesn't fill the window (white edges)**: the upstream `background.tif` is 1080×700 px, sized for Blender's smaller official DMG window. Re-run `python3 extend_dmg_background.py` to regenerate `background_extended.tif` at the right size for our 720×480 pt window.

**`xcrun: error: cannot be used with the selected Xcode`** during notarization: run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to point xcrun at the full Xcode install, not just CLT.

**Notarization rejected with "main executable failed strict validation"**: a nested `.dylib` or `.so` slipped through unsigned. Re-run with `--source` pointing at a clean copy (avoid signing twice — the script's `xattr -cr` should handle quarantine, but a previously-notarized app re-signed with new entitlements can confuse the validator).

**Re-running after a partial failure**: pass `--dmg-only` — the script reuses the already-signed `dist/staging/` and skips straight to DMG creation. Saves 5+ minutes per iteration.

## Reference

- Source upstream: <https://github.com/UPBGE/upbge>
- Blender build docs (apply to UPBGE almost verbatim): <https://developer.blender.org/docs/handbook/building_blender/mac/>
- `make update` mechanics: `upbge/build_files/utils/make_update.py`
- The `make ninja ccache` and `BUILD_DIR=` conventions: `upbge/GNUmakefile` (header comment lists all targets)
- BSL (Blender Shader Language) preprocessor: `source/blender/gpu/intern/gpu_shader_preprocess.cc`, called from each backend's `mtl_shader.mm` / `gl_shader.cc` / `vk_shader.cc`
- Apple Metal shading language reference: <https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf>
