# ding

[![CI](https://github.com/rohpod/ding/actions/workflows/ci.yml/badge.svg)](https://github.com/rohpod/ding/actions/workflows/ci.yml)

A lightweight, native macOS menu bar app that pushes mail notifications for multiple accounts — free and open source.

ding runs quietly in the background, watches your inbox over IMAP, and notifies you the moment new mail arrives. No Electron, no bundled browser, no subscription — just a small native binary that stays out of your way.

> **There is no server.** ding has no backend, no account system, and no company behind it collecting your data. It talks directly to your mail provider's own IMAP server over TLS and nowhere else. Your credentials are stored only in your Mac's Keychain — they never leave your machine, and the entire codebase is open for you to verify that yourself.

## Features

- **Native macOS app** — built entirely in Swift, no cross-platform framework overhead
- **Low resource usage** — idles at a small RAM footprint, uses IMAP IDLE (push) where supported instead of constant polling
- **Multiple accounts** — Gmail, iCloud, Outlook, Yahoo, and Fastmail, each configured independently
- **Configurable sync** — per-account frequency: Always (push), or poll every 1/5/15/30/60 minutes
- **Configurable notification behavior** — clicking a notification can do nothing, open your default mail app, or open the provider's webmail in your browser
- **Menu bar only** — no Dock icon, no window cluttering your desktop
- **Open at Login** — optional, off by default
- **Update checking** — optional check against the latest GitHub release, no silent auto-install
- **Free and open source** — MIT licensed, no paid tiers, no ads, no telemetry

## Installation

### Download (recommended)

1. Go to the [Releases page](https://github.com/rohpod/ding/releases) and download the latest `ding-x.y.z.zip`.
2. Unzip it and drag `ding.app` into your `/Applications` folder.
3. **First launch:** macOS will block the app because it isn't signed by an Apple-registered developer (ding is free and open source, and a paid Apple Developer account isn't part of that). To open it:
   1. In Finder, right-click (or Control-click) `ding.app` and choose **Open**.
   2. A dialog will warn that ding is from an unidentified developer. Click **Open** again to confirm.
   3. If macOS still blocks it: open **System Settings → Privacy & Security**, scroll down to the Security section, and you should see a message that ding was blocked — click **Open Anyway**, then confirm once more.
   
   You only need to do this once. If you'd rather skip the dialogs entirely, you can instead run this once in Terminal before opening the app:
   ```bash
   xattr -cr /Applications/ding.app
   ```
4. Launch ding. It will appear in your menu bar and open Settings automatically on first launch.
5. Add your first account in **Settings → Accounts**.

> Why the extra step? Apple requires a $99/year Developer Program membership to get apps automatically trusted by macOS. As a free, community-run project, ding doesn't use one — which means you're trusting the source code instead of an Apple certificate. Everything in this repo is open for you (or anyone) to audit.

### Build from source

Requires Xcode Command Line Tools (Swift 6.3+) and macOS 13 or later.

```bash
git clone https://github.com/rohpod/ding.git
cd ding
./scripts/build-app.sh
open .build/ding.app
```

`build-app.sh` compiles a release build, assembles a proper `.app` bundle with the icon, and ad-hoc signs it. See [`scripts/README.md`](scripts/README.md) for details.

## Supported providers

| Provider | Notes |
|---|---|
| Gmail | Requires an [app password](https://myaccount.google.com/apppasswords) (needs 2-Step Verification enabled) |
| iCloud | Requires an [app-specific password](https://appleid.apple.com/account/manage) |
| Outlook / Hotmail / Live | Requires an [app password](https://account.live.com/proofs/AppPassword) |
| Yahoo | Requires an [app password](https://login.yahoo.com/myaccount/security) |
| Fastmail | Requires an [app password](https://app.fastmail.com/settings/security/apppasswords) |

ding never sees or stores your real account password. App passwords are separate, provider-generated credentials, revocable independently at any time, stored only in your Mac's Keychain — never in a plaintext file, never transmitted anywhere except directly to your provider's own mail server over TLS.

Generic/custom IMAP servers aren't supported yet — only the five providers above.

## Why app passwords, not "Sign in with Google/Microsoft"?

OAuth (the "sign in with..." flow) requires the app to be registered and security-reviewed by each provider, which for Gmail specifically involves a paid third-party security audit — not something a free, volunteer FOSS project can currently take on. App passwords avoid that entirely, work identically across all five providers, and keep the whole authentication flow contained to your own Mac. See [Settings → Accounts → Add Account] for an in-app explanation shown when you connect an account.

## How it works

ding uses [swift-nio-imap](https://github.com/apple/swift-nio-imap) to speak IMAP directly. For each account:

- If the server supports **IMAP IDLE** and you've selected "Always," ding holds one lightweight persistent connection and gets notified the instant new mail arrives — no polling delay.
- Otherwise, ding connects briefly at your chosen interval, checks for new messages, and disconnects — nothing lingers between checks.

New-mail detection is based on IMAP UIDs, so you won't get duplicate notifications for mail you've already seen, even across restarts.

## Privacy

- **No server.** ding is 100% client-side — there is no backend service run by this project, and there never will be one for core functionality. Your Mac talks directly to your mail provider.
- Credentials are stored exclusively in the macOS Keychain, never in a plaintext file, never transmitted anywhere except directly to your provider's own mail server over TLS.
- No analytics, no telemetry, no third-party servers involved beyond your mail provider and (optionally) a GitHub API call to check for app updates — and that call sends nothing about you, just checks the latest release tag.
- All source code is in this repository — nothing runs that you can't read yourself.

## Contributing

ding is early (`v0.1.x`) and still rough in places. Issues and pull requests are welcome — a formal contributing guide is coming soon; for now, feel free to open an issue to discuss before starting significant work.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Built with [swift-nio-imap](https://github.com/apple/swift-nio-imap) and [SwiftNIO](https://github.com/apple/swift-nio), both from Apple, licensed under Apache 2.0.
Development of this application was supported by Antigravity.
