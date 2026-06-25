# Claude instructions for MacPhone

Follow [AGENTS.md](AGENTS.md) as the authoritative engineering and release policy.

In particular, never build or publish MacPhone with an older default GitHub
Actions Xcode. Use the current stable Apple toolchain, run
`./script/verify_apple_toolchain.sh`, verify the linked SDK with
`./script/verify_binary_sdk.sh`, and visually inspect the launched app's native
macOS appearance before release.
