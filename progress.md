# iOS 15 Compatibility Work

## Baseline

- Upstream: `OwnGoalStudio/CocoaInspector`
- Branch: `main`
- Commit: `f92d9332d15e3f10dffc14fed5c8beb505ebd2c9` (`Release 0.1.3`)
- Package: roothide `iphoneos-arm64e`
- Existing minimum runtime: iOS 17.0 in `Makefile`, Xcode project, and Debian control metadata
- Architecture boundaries: SwiftUI app (`Inspector/`), shared model/client (`Shared/`, `InspectorClient/`), root XPC daemon (`CocoaInspectord/`), CLI (`CocoaInspectorCLI/`)

## Hypothesis

Lowering the deployment target alone is insufficient. The app must replace unconditional iOS 16/17 SwiftUI, Observation, localization, formatting, and clock APIs with iOS 15-compatible equivalents while preserving the XPC protocol and daemon/CLI behavior.

## Success Criteria

- App, daemon, and CLI compile with `IPHONEOS_DEPLOYMENT_TARGET=15.0`.
- Debian metadata requires `firmware (>= 15.0)` and remains roothide `iphoneos-arm64e`.
- Process list, search, sort, filter, pause, details, export/share, and signal confirmation remain available.
- Shared data-layer harness passes.
- Cloud package build succeeds with no unavailable-API diagnostics or incompatible arm64e warning.
- Package inspection confirms iOS 15 minimum OS metadata, arm64e slices, expected files/entitlements, and no forbidden iOS 16/17-only source constructs on the iOS 15 path.

## Independent Failure Signals

- Compiler reports an API unavailable before iOS 16/17.
- App links against an unavailable runtime framework such as Observation.
- Package control still requires firmware 17.0.
- Mach-O minimum OS remains above 15.0.
- A compatibility replacement removes or breaks a user workflow.
- Daemon/CLI protocol or collector tests regress.

## Ablations

- Deployment target only: expected to fail on Observation, NavigationStack, ContentUnavailableView, LabeledContent, ShareLink, modern toolbar placements, and clock/formatting APIs.
- UI-only compatibility: expected to compile farther but still fail package acceptance if Debian firmware metadata remains 17.0.
- Full source + metadata compatibility: expected to compile at target 15.0; device-only private collector behavior remains a separate runtime verification gate.

## Evidence Plan

1. Inventory unavailable APIs and runtime symbols.
2. Convert state ownership to `ObservableObject` / `@Published` / environment object.
3. Add iOS 15 UI compatibility components and replace unavailable APIs.
4. Update deployment/package/docs metadata.
5. Run source scans and host data-layer tests.
6. Run a pinned cloud build, inspect logs and resulting package/Mach-O metadata.
7. Record remaining device-only verification explicitly.

## Implementation

- Replaced Observation with `ObservableObject`, `@Published`, `@StateObject`, and `@EnvironmentObject` while preserving the existing persistence keys and sampling lifecycle.
- Replaced post-iOS-15 SwiftUI surfaces with `NavigationView`, custom unavailable/labeled-content views, and a `UIActivityViewController` share sheet.
- Replaced post-iOS-15 formatting and localization calls with `ByteCountFormatter`, `NSLocalizedString`, and localized format helpers using the existing catalog keys.
- Set the Xcode project, Makefile override, and Debian firmware dependency to iOS 15.0.
- Pinned CI to the current `macos-15` image's Xcode 16.4 / iPhoneOS 18.5 SDK and added minimum-OS/package/log checks.
- Added `Scripts/check-ios15-compatibility.sh`; `make check`, `make build`, and `make deb` now run it through the Makefile dependency chain.

## Verification

Passed on the Linux host:

- `./Scripts/check-ios15-compatibility.sh`
- `make compatibility`
- Bash syntax checks for compatibility, build-wrapper, version, and packaging scripts
- Workflow YAML parse and string-catalog JSON parse
- Localization-helper key comparison against `Localizable.xcstrings`
- Full baseline diff whitespace check
- Current GitHub `macos-15` runner inventory confirms `/Applications/Xcode_16.4.app` and iPhoneOS SDK 18.5

Not available on this host:

- `make harness`, `make build`, and `make deb` require macOS/Xcode; this host has no `xcodebuild`, Apple SwiftUI SDK, or `ldid`.
- Mach-O `minos`, signed entitlements, package contents, and build-log checks therefore remain CI gates rather than locally observed results.
- Private collector behavior and roothide launch/install behavior require an iOS 15 device.

## Status

- [x] Baseline and architecture locked
- [x] Unavailable-API inventory
- [x] State model compatibility
- [x] SwiftUI and localization compatibility
- [x] Package/build metadata compatibility
- [x] Host static verification
- [ ] macOS/Xcode build and data-layer harness
- [ ] Cloud package verification
- [ ] iOS 15 roothide runtime verification
