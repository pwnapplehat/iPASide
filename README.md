<div align="center">

<img src="docs/brand/icon.png" alt="iPASide" width="128" height="128">

# iPASide

**Put any app on your iPhone, from Windows, with just your Apple ID.**

No jailbreak. No paid developer account. No closed-source middleman.

[![Download](https://img.shields.io/github/v/release/pwnapplehat/iPASide?label=download&style=for-the-badge&color=6366f1)](https://github.com/pwnapplehat/iPASide/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-informational?style=for-the-badge)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows%2010%2F11-64--bit-blue?style=for-the-badge)](#get-started)
[![Website](https://img.shields.io/badge/ipaside.com-visit-8c5cf0?style=for-the-badge)](https://ipaside.com)
[![CI](https://img.shields.io/github/actions/workflow/status/pwnapplehat/iPASide/ci.yml?branch=main&style=for-the-badge&label=CI)](https://github.com/pwnapplehat/iPASide/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-907-4cc38a?style=for-the-badge)](#quality)

*Open source, end to end. Nothing between your Apple ID and Apple.*

</div>

---

## Get started

**1. Install iPASide.** Download the installer from the
[latest release](https://github.com/pwnapplehat/iPASide/releases/latest) and run it.
It installs just for you and never asks for administrator rights.

You also need Apple's **[Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k)**
app (or iTunes) — that is what lets Windows talk to your iPhone over USB.

> **Windows will warn you.** It says *"Windows protected your PC"* because the
> installer is not code-signed, and a signing certificate is a recurring cost this
> project does not have. Choose **More info ▸ Run anyway**. If you would rather not
> trust a prebuilt file, every build step is scripted —
> see [Build it yourself](#build-it-yourself).

**2. Sign in.** Open iPASide and sign in with your Apple ID, then enter the code
Apple sends to your other device. A spare Apple ID is a good idea rather than your
main one.

**3. Plug in your iPhone**, unlock it, and tap **Trust**.

**4. Sideload.** Go to **Sideload**, drag an `.ipa` onto the window, and press
**Sideload to iPhone**.

**5. Trust the app on your phone.** Open **Settings ▸ General ▸ VPN & Device
Management** on the iPhone and trust your developer profile. The app will now open.

**6. Turn on auto-refresh** in iPASide's Settings. Apple's free signatures expire
after 7 days; this re-signs your apps before they do, in the background, without
iPASide needing to be open.

## What it looks like

**Home** — your phone, your Apple ID, and how the two are connected.

![iPASide Home](docs/screenshots/home.png)

**Sideload** — drop in an `.ipa` and it reads the app's own icon and details, then
tells you exactly which device it is about to install to.

![Sideload](docs/screenshots/sideload.png)

**Library** — everything you have sideloaded, and how long each has left. Refresh
one or all of them.

![Library](docs/screenshots/library.png)

**LiveContainer** — install it in one press, then add apps to it from here. They run
inside it rather than on your phone, so the three-app limit stops being the thing you
plan around.

![LiveContainer](docs/screenshots/livecontainer.png)

**Account** — every certificate on your Apple ID and which tool registered it, so you
can tidy up without breaking something you did not know was there.

![Account](docs/screenshots/account.png)

**Settings** — pick your connection, decide whether to keep signed `.ipa` files and
where they go, and turn on background refresh.

![Settings](docs/screenshots/settings.png)

**Diagnostics** — one page that tells you whether everything it needs is working.

![Diagnostics](docs/screenshots/diagnostics.png)

There is a full light theme too, and the sun in the title bar switches to it.

![Light theme](docs/screenshots/home-light.png)

## What it can do

- **Sign and install any `.ipa`** with a free Apple ID, over **USB or Wi-Fi** —
  and you choose which, or let it prefer the cable.
- **Drag and drop anywhere** in the window. It reads the app's icon, version and
  contents straight from the file.
- **Inject tweaks** — drop in `.deb` packages (rootful, rootless or roothide) or
  raw `.dylib` files, as many as you like. Dylibs are pulled out of `.deb`s for you.
- **Get past the three-app limit, with LiveContainer.** One press installs
  [LiveContainer](https://github.com/LiveContainer/LiveContainer), signs it with the
  entitlements it needs, and hands it your signing certificate so it can sign apps on
  the phone itself. Then **put apps inside it straight from iPASide** — they are never
  installed on the phone, so they use none of your three slots, and they have no 7-day
  expiry of their own. Verified end to end on an iPhone 8 Plus with a free Apple ID.
- **Refresh on the phone, no PC.** iPASide installs the LiveContainer build that carries
  SideStore and hands it this computer's pairing file, so the phone can re-sign its own
  apps. You sign into that SideStore once, with the same Apple ID iPASide uses — iPASide
  bakes its certificate in, so SideStore reuses that identity instead of replacing it. It
  also needs a local device VPN connected, and an iOS Shortcut named `TurnOffData` that
  iPASide cannot create for you — the app says all of this rather than letting you find out.
- **See and manage your Apple ID's account.** Certificates, App IDs and devices, for any
  Apple ID you have signed in. Each certificate says which tool registered it, because
  Apple counts them per machine and revoking the wrong one breaks a different tool's apps.
- **Keep your apps working.** The Library counts down each app's 7 days, and a
  daily background task re-signs whatever is due — no need to leave iPASide open.
- **Use more than one Apple ID.** Keep several signed in and switch without typing
  a password again — useful when one account has used up its ten App IDs for the
  week. A refresh always re-signs as the account that signed the app, because a
  different one produces something your phone will not install over it.
- **Watch it happen.** Provisioning, signing and installing are reported as they
  occur, down to the upload's byte count and the phone's own install steps.
- **Manage what is installed**, with real home-screen icons, and uninstall from
  your PC.
- **Advanced options** when you want them: custom bundle id or display name, strip
  extensions or device restrictions, enable Files-app sharing.
- **Keep the signed `.ipa`** if you want to reinstall it later without signing
  again, in a folder you choose.
- **Updates that check themselves.** iPASide notices a new release and verifies the
  download against the release's published checksums before it will run it. Nothing
  is downloaded uninvited, and nothing unverified is ever run.
- **Light and dark themes**, a chromeless window, and a single instance.

Your Apple ID is used **only** to sign in to Apple, over a connection pinned to
Apple's own certificate authority. It is never sent anywhere else, and there is no
iPASide server.

## What Apple's free account will not let you do

These are Apple's limits, not iPASide's. It works within them and tries to make
them visible rather than surprising:

- Apps **stop opening after 7 days** until they are re-signed. Use **Library ▸
  Refresh**, or leave auto-refresh on.
- **Only 3 sideloaded apps can be installed at once, per device.** Your phone counts
  every app signed by any free Apple ID, so a second account does not add slots -
  verified on hardware, and it is the limit most people run into first. This is the one
  limit here with a way around it: see **LiveContainer** above, which runs apps inside
  itself so the phone only ever counts one.
- You get roughly **10 App IDs per 7 days** - a separate ceiling, about registering
  identifiers rather than installing apps. The Library, and the `slots` command, show
  what you have used, and a second Apple ID gets you another ten of these.
- **App extensions** usually have to be removed — widgets, share sheets, keyboards
  and watch apps will not work. Each would need its own App ID.
- **Apps bought from the App Store cannot be re-signed.** They are encrypted;
  iPASide tells you when it sees one instead of failing obscurely.
- **Apple TV is not blocked, but it is untested.** iPASide refuses only a genuine
  mismatch - a tvOS `.ipa` sent to an iPhone, or an iOS one sent to an Apple TV - because
  an app built for the wrong device installs and then never launches. A tvOS `.ipa` going
  to an Apple TV is allowed through: Apple registers an Apple TV and issues its profile
  from the same endpoints iPASide already uses for a phone, so signing is not the
  obstacle. What is untested here, for want of an Apple TV, is reaching one. A model with
  a USB port should pair over usbmux like any other device; a portless Apple TV needs
  network pairing over `_remotepairing-manual-pairing._tcp`, which iPASide does not
  implement. If you have one, please report what happens.

## How it works

A Windows app driving a Python engine that does the Apple-facing work:

```
┌─────────────────────────────┐    JSON over stdio     ┌──────────────────────────┐
│  iPASide.Flutter (Dart)     │ ─────────────────────▶ │  iPASide.Engine (Python) │
│  chromeless desktop UI      │ ◀───────────────────── │  pymobiledevice3 + GSA   │
│  drag-drop, live progress   │     progress events    │  auth + anisette + zsign │
└─────────────────────────────┘                        └──────────────────────────┘
```

- **Device I/O** — `pymobiledevice3` (pure Python, Windows-native): pairing,
  lockdown, `installation_proxy` install, AFC staging, Developer Mode.
- **Apple ID auth** — GrandSlam (GSA, a modified SRP-6a) with **anisette** data
  generated locally, in-process and offline. No 32-bit Apple DLLs, no remote server.
- **TLS** — Apple's own `Apple Root CA` is pinned, and verification is never
  disabled anywhere in the codebase.
- **Provisioning** — the same `developerservices2.apple.com` API Xcode uses.
- **Signing** — a modern `zsign` (SHA256-only CodeDirectory, canonical DER
  entitlements), built from source, with dylib injection and extension stripping.
- **Auto-refresh** — a registry tracks each install's expiry, and a daily Windows
  scheduled task runs `iPASide.exe --auto-refresh` to re-sign what is due.

## Build it yourself

You need the **Flutter SDK** (3.44+) with **Visual Studio 2022** and its "Desktop
development with C++" workload, **Python 3.12**, and **MSYS2** to build `zsign`.
Windows **Developer Mode** must be on, because Flutter wires plugins up with
symlinks.

```powershell
# 1. Python engine (dev)
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements-dev.txt

# 2. zsign (from an MSYS2 shell) -> src/iPASide.Engine/ipaside_engine/vendor/zsign.exe
bash tools/zsign/build-zsign.sh

# 3. Run the engine directly
cd src\iPASide.Engine
python -m ipaside_engine doctor
python -m ipaside_engine devices

# 4. Run the desktop app (dev; it finds the engine via the .venv automatically)
cd src\iPASide.Flutter
flutter run -d windows

# 5. Tests
python -m pytest                                  # engine
cd src\iPASide.Flutter; flutter test              # app

# 6. Full installer (portable engine + Flutter runner + Inno Setup)
powershell -File packaging\build-installer.ps1 -Version 1.0.0
```

Releasing is documented in [docs/releasing.md](docs/releasing.md), and the deferred
macOS work in [docs/macos-port.md](docs/macos-port.md).

## Engine CLI

The engine works on its own, without the app. Every command takes `--json`:

| Command | What it does |
|---|---|
| `doctor` | Check that everything it needs is working |
| `devices` / `device-info` | List or inspect connected devices |
| `login` | Apple ID sign-in (`--email`, `--code`, `--status`, `--accounts`, `--use`, `--logout`) |
| `inspect <ipa>` | Read an IPA's identity and icon without extracting it |
| `sideload <ipa>` | Provision, sign and install, with all the advanced options |
| `livecontainer` | LiveContainer: `--setup`, `--variant`, and `--apps` / `--add` / `--remove` for the apps inside it |
| `installs` / `refresh` / `forget` | Manage the registry and renew signatures |
| `signed` | Report or clean up kept `.ipa` files (`--clean`) |
| `slots` / `revoke-cert` / `delete-app-id` | An Apple ID's certificates, App IDs and devices; `--email` picks which account |
| `apps` / `uninstall` | Apps installed on the device |

Device commands take `--udid` to pick a phone and `--connection usb|wifi|auto` to
pick how to reach it.

## Status

Working end to end, and verified that way rather than assumed: iPASide signs and
installs real apps onto a physical **iPhone 8 Plus (iOS 16.7.15)** with a free
Apple ID, over USB. Each release is installed and driven against that device before
it is published.

Not yet verified: a full install over Wi-Fi (talking to the device over Wi-Fi does
work), two phones attached at once, and paid developer accounts.

LiveContainer is verified the same way: signed with the entitlements it needs, its
JIT-less self-test passing, and an app installed inside it and launched. Its
multitasking extension (`LiveProcess.appex`) is left in place but untested under a free
profile.

## Quality

**1,062 automated tests**, run on every push along with a full installer build:

| Suite | Tests | Files | What it covers |
|---|---|---|---|
| Engine (pytest) | 340 | 20 | Apple ID auth, provisioning, app groups, signing, `.deb` tweak extraction, install progress, device selection, multi-account, LiveContainer entitlements, pairing files, certificate scoping, Windows path limits, expiry, error phrasing |
| App (Flutter) | 722 | 38 | Every view model, the engine transport, update planning, settings, the platform layer, motion, scroll |

CI runs three jobs per push - `Engine tests`, `App analyze + tests`, `Build installer` -
and lints are errors, not warnings. The badge above links to the runs.

What tests cannot cover is a real phone, so each release is also driven by hand against
an iPhone 8 Plus on iOS 16.7.15 over both USB and Wi-Fi before it is published. Several
things in the changelog were found that way rather than by reasoning: the free-account
three-app ceiling is per *device* and not per Apple ID, and a background refresh really
does re-sign and reinstall with the app closed.

## Legal

iPASide installs apps onto **your own device** using **your own Apple ID** — the
same mechanism Xcode uses to run an app you wrote. Only install software you are
entitled to run. iPASide is not affiliated with Apple Inc. Apple, iPhone and iOS
are trademarks of Apple Inc.

## License

[MIT](LICENSE) © 2026 iPASide Contributors.
