# Release builds

- After producing and verifying a release build, update `.build/release-latest` to point to its directory using a relative symlink.
- The linked directory must contain the finished `mac-vnc-server` executable. Keep the previous link intact if the build or verification fails.
- Give the user `.build/release-latest/mac-vnc-server` as the stable executable path, together with the release version.
- Updating this link does not authorize restarting any running server.
