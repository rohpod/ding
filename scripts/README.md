# Packaging & Tooling Scripts

This directory contains shell automation scripts for assembling, testing, and managing local development builds of **ding**.

---

## 1. `scripts/build-app.sh`

### Purpose
Packages the compiled SwiftPM executable into a native macOS application bundle (`.build/ding.app`) and applies an ad-hoc code signature.

### When to Use
Use this script whenever you need to test functionality that requires a genuine macOS `.app` bundle identity:
* **SMAppService (Open at Login)**: macOS 13+ requires a code-signed application bundle to register items in **System Settings > General > Login Items**.
* **UNUserNotificationCenter (Notifications)**: Notification permissions, banner presentations, sound alerts, and click responses require a recognized bundle identifier (`com.ding.mac`) and code signing.
* **Keychain "Always Allow" Persistence**: Ad-hoc code signing (`codesign -s -`) provides a stable cryptographic `cdhash` and designated requirement so that macOS Keychain remembers authorization across repeated launches of the same built application.
* **Spotlight / Applications Relaunching**: Verifies `applicationShouldHandleReopen` behavior when launching the `.app` bundle while already running.

> **Note**: For day-to-day pure business logic testing, running unit tests (`swift test`) or quick command-line execution (`swift run`) is sufficient and faster. `build-app.sh` is specifically for testing system integrations.

### How to Run

From anywhere in the repository:

```bash
# Build the default, optimized release bundle:
./scripts/build-app.sh

# Or build a debug bundle with unoptimized symbols for troubleshooting with LLDB:
./scripts/build-app.sh debug
```

### Launching the Application

Once built, launch the application using `open`:

```bash
open .build/ding.app
```

#### Gatekeeper & First-Launch Notes
Because development builds use ad-hoc signing (`codesign --sign -`) rather than a paid Apple Developer ID certificate:
1. If macOS flags an untrusted developer prompt on first launch, either:
   - Run `xattr -cr .build/ding.app` to clear the quarantine flag, or
   - Right-click `.build/ding.app` in Finder and click **Open**.
2. When the app accesses Keychain for mail credentials, macOS may prompt for permission. Choosing **Always Allow** will persist across subsequent launches of that exact build.

### Gitignore Behavior
The output bundle is assembled inside `.build/ding.app`. The `.build/` directory is ignored by git in `.gitignore`, preventing multi-megabyte binary artifacts from ever being committed to source control.

---

## 2. `scripts/clean.sh`

### Purpose
Resets local testing state to simulate a completely fresh "first launch" environment.

### What it Does
1. Terminates any running `ding` process (`pkill -x ding`).
2. Unregisters any registered macOS Login Item (`--reset-login-item` via `.build/ding.app`).
3. Resets macOS notification and TCC privacy permissions (`tccutil reset All com.ding.mac`).
4. Clears saved user preferences from macOS `UserDefaults` (`defaults delete com.ding.mac`).

### How to Run

```bash
./scripts/clean.sh
```

---

## 3. `scripts/release.sh`

### Purpose
Dedicated release packaging script that produces a clean, versioned, distributable zip archive (`dist/ding-{VERSION}.zip`) and a SHA-256 checksum file (`dist/ding-{VERSION}.zip.sha256`) ready to attach to a GitHub Release.

### When to Use
Use this script **only when preparing to publish an official new version release**.
For routine local development, feature testing, or system integration checks, use `scripts/build-app.sh` instead.

### What it Does
1. **Version Validation**: Reads `VERSION` from the repository root and validates that it follows strict semantic versioning (`x.y.z` with numeric digits only).
2. **Overwrite Safety**: Checks if a release archive for this exact version already exists in `dist/`. If found, it warns and prompts for confirmation to prevent accidental clobbering (can be bypassed with `--force`).
3. **Build Execution**: Calls `scripts/build-app.sh release --no-run` to compile an optimized release binary and assemble an ad-hoc signed `ding.app` bundle in `.build/`.
4. **Staging & Packaging**: Copies `ding.app` into an isolated staging directory (`.build/release-staging/`) and zips it into `dist/ding-{VERSION}.zip`, preserving symlinks and bundle structure.
5. **Checksum Generation**: Computes a SHA-256 checksum file (`dist/ding-{VERSION}.zip.sha256`) using `shasum -a 256` for integrity verification.
6. **Next Steps Summary**: Prints the archive path, size, SHA-256 hash, and exact terminal commands for tagging and publishing to GitHub.

### How to Run

```bash
# Package the current version:
./scripts/release.sh

# Or overwrite an existing archive without prompt:
./scripts/release.sh --force
```

### Full Release & Publishing Workflow

Follow these steps when cutting a new release:

1. **Update `VERSION`**:
   Edit the single-line `VERSION` file at the repository root with the new semantic version (e.g. `0.2.0`).
2. **Commit the version bump**:
   ```bash
   git add VERSION
   git commit -m "chore: bump version to 0.2.0"
   ```
3. **Create and push a git tag**:
   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```
4. **Package the release artifact**:
   ```bash
   ./scripts/release.sh
   ```
   This outputs `dist/ding-0.2.0.zip` and `dist/ding-0.2.0.zip.sha256`.
5. **Publish the GitHub Release**:
   * **Web UI (Primary)**:
     1. Open your browser and navigate to `https://github.com/rohpod/ding/releases/new`.
     2. Select the tag: `v0.2.0`.
     3. Enter the release title: `ding v0.2.0`.
     4. Add release notes describing changes and improvements.
     5. Drag and drop `dist/ding-0.2.0.zip` and `dist/ding-0.2.0.zip.sha256` into the release binaries/assets area.
     6. Click **Publish release**.
   * **GitHub CLI (`gh`) (Optional shortcut)**:
     ```bash
     gh release create v0.2.0 dist/ding-0.2.0.zip dist/ding-0.2.0.zip.sha256 --title "ding v0.2.0" --generate-notes
     ```

### Gitignore Behavior
All release output is placed inside the top-level `dist/` directory. `dist/` is ignored by git in `.gitignore`, ensuring distributable zip archives and checksum files are never committed to the repository.

