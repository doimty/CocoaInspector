# CocoaInspector

iOS process inspector for roothide jailbreak: SwiftUI app (`Inspector/`), XPC daemon (`CocoaInspectord/`), CLI (`CocoaInspectorCLI/`), shared wire/data layer (`Shared/`, `InspectorClient/`).

## Build

- `make build` — validates inputs (`check`), runs the macOS data-layer test harness (`harness`), then builds the unsigned iOS app + daemon + CLI via xcodebuild. Requires `xcodebuild`, `ldid`, `dpkg-deb`.
- `make deb` — build + ad-hoc sign + package the roothide `.deb`; prints its sha256. Output path: `make print-deb-path`.
- `make harness` — run just the shared data-layer tests on macOS (fast; no device needed).
- Build settings live in `Configuration/*.xcconfig`, not in `project.pbxproj`. `Configuration/Version.xcconfig` is the single source of the app, daemon, CLI, and `.deb` version — change it with `make set-version VERSION=1.2.3 [BUILD=n]`; `make check` fails if a version is hardcoded back into the project file.
- Optional local overrides go in the git-ignored `Configuration/Developer*.xcconfig` files (for example `DEVELOPMENT_TEAM`). See `Configuration/Developer.xcconfig.example`.
- Pushing a `vX.Y.Z` tag makes CI apply that version, build the package, and publish it to a GitHub release. CI is a single job on the GitHub-hosted `macos-26` runner — build, package verification, and release all run there; no self-hosted machine.
- `project.pbxproj` must keep `objectVersion = 77` so Xcode 16+ and the CI runner's Xcode can read it; newer Xcode betas rewrite it on GUI save, and `make check` fails when that happens — revert that line.
- SourceKit/editor diagnostics in this repo are frequently stale false positives (`PBXFileSystemSynchronizedRootGroup`); trust `xcodebuild` output, not the editor.

## Install on a jailbroken device

Install the package produced by `make deb` with your usual roothide workflow (Sileo, `dpkg`, etc.). The archive installs `Inspector.app`, `/usr/bin/cocoainspector`, `/usr/libexec/cocoainspectord`, and the on-demand LaunchDaemon plist.

After install, validate with:

```sh
sudo /usr/bin/cocoainspector self-test   # expect all PASS
uiopen -b wiki.qaq.Inspector             # launch the app
```

Clean up any temporary upload copies after install. Do not leave stray package files on the device.

## On-device inspection: our CLI only (enforced)

All process inspection and verification on the device MUST go through our own CLI — never spawn or fork system tools (`ps`, `pgrep`, `top`, etc.; most don't exist on the device anyway):

- `sudo /usr/bin/cocoainspector list` — pid / ppid / uid / threads / mem / name
- `sudo /usr/bin/cocoainspector inspect <pid>` — full JSON for one process (all collectors, incl. `executablePath`)
- `sudo /usr/bin/cocoainspector details <kind> <pid>`, `watch`, `signal`, `self-test`

Dogfooding the CLI is the point: if it can't answer a question about a process, that's a product gap to fix, not a reason to shell out.
