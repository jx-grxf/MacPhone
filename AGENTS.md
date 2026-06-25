# MacPhone agent instructions

## Apple toolchain

- Build, test, package, and release with the newest stable Apple toolchain available on the selected GitHub runner.
- GitHub Actions must use the current macOS runner generation (`macos-26` at present) and `/Applications/Xcode.app`, which is the runner's stable Xcode symlink.
- Never rely on an older runner's default Xcode. Before every macOS build, run `./script/verify_apple_toolchain.sh`.
- Every distributable executable must pass `./script/verify_binary_sdk.sh`; currently it must link against macOS SDK 26 or newer.
- When GitHub publishes a newer stable macOS/Xcode runner generation, update the runner and minimum-version gates in the same change.
- Do not lower the deployment target or SDK to work around compiler errors. Preserve compatibility with `#available` checks while compiling against the newest SDK.

## SwiftUI and design

- Use current native macOS SwiftUI APIs and system structures first: `NavigationSplitView`, native toolbars, semantic materials, and system controls.
- On macOS 26+, preserve the automatic Liquid Glass appearance. Do not paint opaque custom backgrounds over system sidebars, toolbars, sheets, or root panes.
- Use new APIs behind availability checks when the deployment target supports older macOS versions.
- Significant UI or release changes require a local build with the current Xcode, an actual `.app` launch, and visual verification before publishing.

## Releases

- A green compile alone is insufficient. Verify the active Xcode/SDK, linked binary SDK, app launch, DMG, Sparkle ZIP/appcast, hashes, and the public download URLs.
- Do not publish or retain a release built with an older Apple SDK when a newer stable SDK is required by these instructions.
