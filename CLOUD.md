# Cloud build requirements

GitHub Actions must build MacPhone with the newest stable Apple SDK available on
the current macOS runner generation. The current baseline is:

- runner: `macos-26`
- Xcode: `/Applications/Xcode.app` (stable runner symlink)
- minimum Xcode major: 26
- minimum linked macOS SDK major: 26

Every cloud build must run `script/verify_apple_toolchain.sh` before compiling
and `script/verify_binary_sdk.sh` against the finished executable. A workflow
must fail instead of publishing if either check detects an older toolchain.

Update this file, `AGENTS.md`, and the workflow gates together when Apple and
GitHub advance the stable runner/toolchain generation.
