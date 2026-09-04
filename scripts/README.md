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
