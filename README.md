# UPBGE macOS Builds (unofficial)

> **⚠️ This is NOT the official UPBGE project.**
> The official project lives at **<https://github.com/UPBGE/upbge>** — report engine bugs, ask questions, and contribute there.
> This repo only exists to provide **unofficial, signed & notarized Apple Silicon builds** of recent UPBGE `master`, primarily for my students, and for anyone else who wants a current native macOS build while official Mac releases catch up.

## What you get

Each [Release](../../releases) contains a `UPBGE-<date>-<commit>.dmg` with:

- **Blender.app** — UPBGE editor (Blender + the integrated game engine)
- **Blenderplayer.app** — standalone game runtime

Builds are native `arm64`, code-signed with a Developer ID, and notarized by Apple — they open without Gatekeeper warnings. Built from UPBGE `master`, which currently tracks the Blender 5.2 series.

## Not official — what that means

- No warranty; `master` is a development branch and may be unstable.
- Don't report bugs in these builds to UPBGE unless you can reproduce them in an official build — they may be caused by the local patches below.
- UPBGE and Blender are © their respective contributors, licensed GPL. This repo redistributes builds under the same license; the exact source is the upstream commit named in each release plus the patches in [`patches/`](patches/).

## Local patches

A handful of small patches are applied before building (Apple Clang 21 / Metal fixes and addon Python API ports — see [`docs/BUILD_NOTES.md`](docs/BUILD_NOTES.md) for full rationale). Patches are dropped as soon as upstream fixes land. If a patch stops applying, the CI build warns in the release notes.

## How builds are made

GitHub Actions (`.github/workflows/build.yml`) on Apple Silicon runners:

1. Clone `UPBGE/upbge@master` (or a chosen ref), apply `patches/`.
2. Build with the standard `make ninja ccache` path (`scripts/build.sh`).
3. Sign every nested Mach-O, sign the apps with hardened runtime, notarize via `notarytool`, staple, package as DMG (`scripts/package_dmg.sh`).
4. Publish a GitHub Release. Runs weekly; skipped when upstream hasn't changed.

The same scripts work locally on any Apple Silicon Mac — see `docs/BUILD_NOTES.md`.

### CI secrets (for forks who want signed builds)

| Secret | Contents |
|---|---|
| `MACOS_CERT_P12` | base64 of your "Developer ID Application" cert + key exported as .p12 |
| `MACOS_CERT_PASSWORD` | password of the .p12 |
| `NOTARY_APPLE_ID` | Apple ID email |
| `NOTARY_TEAM_ID` | 10-char team ID |
| `NOTARY_PASSWORD` | app-specific password |

Without secrets the workflow still produces an unsigned DMG (right-click → Open on first launch).

## License

GPL-3.0-or-later, matching upstream UPBGE/Blender. See upstream for full license texts.
