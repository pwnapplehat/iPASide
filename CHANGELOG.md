# Changelog

All notable changes to iPASide are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and
[Keep a Changelog](https://keepachangelog.com/).

## [1.1.4] - 2026-08-01

### Fixed

- **On Chinese Windows, Apple ID sign-in showed the 2FA code screen but no code
  ever arrived on the phone** ([#5](https://github.com/pwnapplehat/iPASide/issues/5)).
  1.1.3 fixed the latin-1 crash from issue #3 by keeping ASCII timezone/locale
  values, but Windows locale *display names* like ``Chinese (Simplified)_China``
  are ASCII and were left unchanged. Apple's trusted-device endpoint answers
  **HTTP 500** for that value and never pushes a code - proven live against
  ``gsa.apple.com`` (same request with ``zh_CN`` returns 200). Locales are now
  mapped to Apple-style tags (``zh_CN``, ``en_US``, …), and if Apple rejects the
  2FA trigger the app reports that instead of claiming a code was sent.

## [1.1.3] - 2026-07-31

### Fixed

- **Signing in to an Apple ID failed on non-English Windows with a cryptic
  ``latin-1`` error.** After the password check succeeded, the trusted-device 2FA
  step puts anisette fields on the HTTP request. The upstream anisette package
  fills ``X-Apple-I-TimeZone`` from the OS timezone *display name*, which on a
  Chinese install is ``中国标准时间`` (and similarly localized on other languages).
  HTTP headers are latin-1, so urllib3 raised
  ``'latin-1' codec can't encode characters in position 0-5`` and sign-in never
  reached the code prompt ([#3](https://github.com/pwnapplehat/iPASide/issues/3)).
  Timezone and locale are now rewritten to ASCII Apple-style values (abbreviation
  or ``GMT±HH:MM``, and an ASCII locale tag) at the single place every caller gets
  anisette headers, so GrandSlam 2FA and developer services stay wire-safe. Nine
  regression tests reproduce the exact encode failure and pin the sanitiser.

## [1.1.2] - 2026-07-29

### Fixed

- **Signing an IPA larger than about 2 GB failed immediately with "Unzip failed!".** The
  bundled signer (zsign) reads IPAs through a copy of minizip that, on Windows, falls back
  to 32-bit file offsets, so it could not seek past the 2 GB mark to reach the ZIP index of
  a large app - a 4 GB game's IPA never got past unzipping, no matter how many times you
  tried. Both reading and writing the archive now go through the 64-bit Windows file API
  (iowin32), and the fix is proven by signing a real 4.19 GB IPA end to end: unzip, sign all
  53 frameworks and the app, and repack to a valid 4.19 GB output. Anything under 2 GB was
  never affected, which is why most apps signed fine.

- **Signing in could break permanently with a cryptic archive error.** iPASide sets up Apple
  sign-in using a small set of device libraries it downloads once from a public host and
  caches together with the provisioning state. If that download was intercepted (a proxy or
  captive-portal page arriving in place of the archive) or the cache was left half-written by
  an interrupted first run, every later attempt re-threw a raw "not a gzip/bzip2/xz/tar file"
  error from deep in the archive parser - and the only way out was to find and delete the
  cache file by hand. Now a cache that will not load is discarded and rebuilt automatically,
  the download is verified to be a real archive before it is used (and retried if not), and a
  genuine failure reports that the provisioning server may be down or the network is blocking
  it, instead of a parser stack trace. The libraries are still downloaded, not bundled, so
  nothing of Apple's is redistributed.

## [1.1.1] - 2026-07-28

### Fixed

- **The Install LiveContainer button worked at all.** 1.1.0 shipped with `download()`
  missing the `variant` parameter the command line passed it, so installing LiveContainer
  without supplying an IPA yourself - which is what the button does - failed immediately
  with `download() got an unexpected keyword argument 'variant'`. Every function involved
  had tests; the wiring between them did not. There are now tests that drive each
  `livecontainer` command through the real argument parsing into the real functions,
  stubbing only the network, the device and zsign, so a parameter renamed on one side and
  not the other fails there instead of on someone's PC. Seven of them fail against 1.1.0.

### Added

- **LiveContainer's own icon** on its tab, read from the phone rather than the IPA, so it
  is the icon actually on the home screen.
## [1.1.0] - 2026-07-28

### Added

- **LiveContainer support, which is a way around the three-app limit.** A free Apple ID
  allows three sideloaded apps on a device at once. LiveContainer runs other apps inside
  itself, so the phone counts one however many are loaded into it. One press in the new
  LiveContainer tab downloads the current release, signs it with what it needs, installs
  it, and hands it the signing certificate. Verified end to end on an iPhone 8 Plus with a
  free Apple ID: JIT-less self-test passing, and an app installed inside it and launched.

  Three things had to be established first, none of them obvious:

  - **Free accounts can use app groups.** LiveContainer reaches its certificate through a
    shared container, and the received wisdom is that this needs a paid account. It does
    not: enable the `APG3427HIY` capability on the App ID, assign the group, *then*
    download the profile, and the profile grants it. Order matters and nothing fails
    loudly if you get it wrong - the profile simply comes back without the group.
  - **The entitlements have to be spelled out.** A profile grants `TEAMID.*` for keychain
    access, but LiveContainer looks for 128 explicit
    `TEAMID.com.kdt.livecontainer.shared.N` groups, and other signers write the wildcard
    instead - which is why its maintainers require AltStore or SideStore. The wildcard
    legally covers the explicit entries, so signing with the expanded list is accepted.
    This is what zsign's `-e` is for, and iPASide was not using it.
  - **The certificate cannot be delivered from a PC.** LiveContainer reads it from the app
    group's `UserDefaults`, and that container is unreachable over `house_arrest`: AFC
    lists directories through `..` but refuses to open or stat anything outside the app's
    own container. So iPASide leaves an import request in LiveContainer's `Documents` -
    which *is* writable - and injects a small dylib that performs the import on first
    launch, using the same calls LiveContainer's own Settings would. The dylib is built on
    a macOS CI runner, because an iOS arm64 Mach-O cannot be produced on Windows.

  LiveContainer's own code is not modified. All eleven Mach-O binaries in the bundle,
  including the 1.5 MB framework its logic lives in, are byte-identical to the release
  build; what changes is the code signature, one added `LC_LOAD_DYLIB`, and the
  team-scoped bundle id a free account requires. Its app extensions are kept rather than
  stripped, unlike an ordinary sideload, because `LiveProcess.appex` is its multitasking.

- **Apps run inside LiveContainer, installed from iPASide.** An app placed in
  LiveContainer is not installed on the phone, so it uses none of the three slots and has
  no seven-day expiry of its own - proved on hardware, where one guest app is running on a
  provisioning profile that expired nine months ago and another has no profile at all.
  iOS never installs them, so it never checks. They stop working only when LiveContainer
  does, and iPASide already keeps that refreshed.

  Installing one needs nothing clever: LiveContainer's own importer moves the unzipped
  bundle into place and then patches and signs it, and the patch is triggered by the
  absence of its revision marker. So iPASide writes the bundle over `house_arrest` and
  LiveContainer does the rest - none of its private format is reproduced, and iPASide
  signs nothing. Measured at 7.9 MB/s, so a 300 MB app lands in under a minute.

- **On-device refresh, with the SideStore build.** Each LiveContainer release carries a
  second IPA with SideStore inside the same bundle id, so a store that can re-sign apps on
  the phone costs no extra app slot. iPASide installs that build by default and hands it
  this computer's pairing record.

  The pairing file needed one fix to be usable: usbmux on Windows writes every key a
  lockdown session needs *except* `UDID`, because the file name carries it. Handed to
  SideStore on its own, with no name to read, an otherwise complete record is rejected as
  "invalid or missing". Adding the key is the whole difference - confirmed by SideStore's
  own log, which then reported the file loaded and minimuxer bound to 127.0.0.1.

  Two things it needs that iPASide cannot provide are stated in the app rather than left
  to be discovered: a local device VPN must be connected before a refresh starts, and
  SideStore runs an iOS Shortcut named exactly `TurnOffData` when it finishes. Without
  that Shortcut the Shortcuts app opens with an error even though the refresh worked, and
  Shortcuts cannot be created from a PC.

- **An Account tab.** Certificates, App IDs and devices for any signed-in Apple ID, with
  each certificate labelled by the tool that registered it, and revoke / delete for
  tidying up. This exists because a free team routinely holds several certificates -
  verified holding three at once, iPASide's alongside Xcode's on a Mac and SideStore's on
  a phone - and nothing showed which was which.

- **`livecontainer` engine command** - report status, `--download` a release, `--setup`
  the whole thing, or manage what runs inside it with `--apps`, `--add` and `--remove`.
  `--variant` picks the build. Takes `--udid` / `--connection` and the signed-output
  options like any other device command.

- **`revoke-cert` engine command**, and `--email` on `slots` and `delete-app-id`, so
  account housekeeping can name which Apple ID it means.

### Changed

- **Signing profiles.** A sideload can now name a profile that contributes app groups, an
  explicit entitlements plist, and a dylib to inject. Only the profile's *name* is
  recorded, so a re-sign months later regenerates whatever the app requires then and finds
  the dylib wherever that build keeps it - rather than replaying values, and an install
  path, that were true once.
- **The progress stepper takes a schedule.** Phase names, labels and which phases can
  honestly report a percentage now live in one place, so a flow with different phases is a
  constant rather than a second copy of the state machine. A LiveContainer setup draws five
  steps; a sideload still draws three.

### Fixed

- **iPASide no longer revokes other tools' signing certificates.** When it needed to issue
  a new one it revoked *every* development certificate on the team. Apple scopes that limit
  per machine rather than per account, so a team routinely holds several - which means the
  old behaviour would destroy a user's Xcode certificate, or SideStore's, on a fresh
  install, a lost cache, or an expired certificate. Every app those had signed then stops
  launching, in tools iPASide has no part in. It now revokes only a certificate registered
  under its own machine name. The failed-revocation path no longer swallows the error into
  an `except: pass` either; it is used to explain a request that then fails.
- **Apps with deeply nested frameworks can be signed on Windows.** zsign writes a temporary
  file beside every Mach-O it re-signs, through APIs capped at `MAX_PATH`. A bundle whose
  frameworks nest inside frameworks - a Swift package product names itself twice, once as
  the folder and once as the binary - is ~180 characters deep before the working directory
  is counted, and over the limit zsign dies on an `fopen` with both streams empty and a -1
  exit. Nothing downstream could explain it. The working directory is now sized against the
  IPA up front, and moved somewhere shorter when it will not fit; where nothing fits, it
  says so and names the fix. Found on LiveContainer's SideStore build, but it applies to any
  app with nested Swift package frameworks.
- **`slots` no longer reports the App ID limit as spare capacity.** It printed registered
  identifiers as `N/10`, but the ten is a ceiling on *new* registrations over a rolling
  seven days while the list is what exists - so `2/10` read as eight to spare when the
  week's allowance could already be spent, which is exactly how a refresh gets refused
  after the tool said there was room. Now two separate numbers, with the difference stated,
  and `delete-app-id` says every time that it frees the name rather than the allowance.
- **A refresh now re-delivers LiveContainer's certificate.** Re-signing without doing so is
  harmless while the certificate stays the same and silently wrong when it does not: if
  Apple revokes it or the local cache goes missing, provisioning issues a new one and
  LiveContainer is left holding a copy that no longer matches. Nothing reported that - it
  installed, launched, and only failed when it tried to sign. The same step now delivers
  the pairing file, for the same reason: a refresh reinstalls the app and takes its
  container with it.
- **Two sideloads started in the same frame install once.** Both the sideload and
  LiveContainer flows claimed their "running" flag only after the sign-in probe, so two
  calls could clear the guard before either set it. The button being disabled was doing all
  the work.
- **Copy progress for an app bundle actually moves.** Putting an app into LiveContainer
  emitted a frame per file - 844 of them for one app - and because a bundle's size sits in
  one or two files the percentage jumped from 0 to 100 with nothing in between. Now 29
  frames for the same app, with file counts alongside megabytes.

## [1.0.1] - 2026-07-27

Fixes made after 1.0.0 was published, released under a new version so an installed copy
is actually offered them. 1.0.0's own assets are left alone from here: a published
release's bytes should not change under the people downloading them, and re-releasing the
same number meant the updater had no way to notice there was anything to fetch.

### Fixed

- **Reaching the free-account app limit now reads as a sentence.** iOS allows three
  sideloaded apps per device and refuses the fourth; iPASide surfaced that as a raw
  `AppInstallError` with a Python `set` of tuples inside it. It now names the three apps
  occupying the slots, with the team that signed each, and says what to do. Verified on
  an iPhone 8 Plus.
- **The three-app limit is per device, not per Apple ID** - tested, because the widely
  repeated advice says otherwise. The apps iOS counts can belong to different developer
  teams, and signing in with a second Apple ID and retrying produced the identical
  refusal listing the same three apps. A second account gets you another ten App ID
  *registrations*, which is a different ceiling; it does not get you a fourth installed
  app. The docs said nothing about this while implying otherwise, and now say both.
- **An app built for the wrong kind of device is caught before signing.** A tvOS `.ipa`
  is indistinguishable from an iOS one from the outside - same zip, same
  `Payload/<App>.app` - so sent to an iPhone it installs and never launches. iPASide reads
  `CFBundleSupportedPlatforms` (falling back to `UIDeviceFamily`), compares it against the
  selected device's `DeviceClass`, and refuses only a genuine mismatch.
  `--allow-other-platform` overrides it.

### Added

- **Apple TV is no longer ruled out.** A tvOS `.ipa` going to an Apple TV is allowed
  through, because provisioning turned out not to be the obstacle: Apple registers an
  Apple TV and issues its profile from the same `ios/` endpoints iPASide already calls,
  which is why the `DTDK_Platform`/`subPlatform` hints on those calls are ignored - a
  profile is scoped by the UDIDs in it, not by a platform. Tested as far as is possible
  without the hardware, on a real 134 MB tvOS build: the platform is detected correctly,
  an App ID and profile are issued for it, and zsign signs it in 11 seconds with the
  Mach-O still declaring tvOS afterwards. Untested is the install itself, and one detail
  worth knowing - the profile came back listing `iOS, xrOS, visionOS` because this team
  has only an iPhone registered, so it should include tvOS once an Apple TV is. If you
  have one with a USB port, please report what happens.
- Install progress names the device it is uploading to rather than always saying
  "iPhone", which is both wrong for an Apple TV and less useful than the device's own
  name when two are attached.

### Changed

- The Home hero mark is drawn from artwork cut at the sizes the UI uses, rather than
  shrunk from the 512px master by the image decoder, whose scaler left visibly
  stair-stepped corners.

## [1.0.0] - 2026-07-26

First release. iPASide signs and installs `.ipa` files onto a physical iPhone or iPad
using a free Apple ID, on Windows, with no jailbreak and no paid developer account.
Verified end to end against an iPhone 8 Plus running iOS 16.7.15 over USB.

Everything runs locally. There is no iPASide server, no remote anisette provider and no
telemetry — your Apple ID talks to Apple directly from your own machine, over TLS
verified against Apple's own pinned root.

### Sideloading

- Pick or drop an `.ipa` and iPASide provisions, signs and installs it in one action,
  reporting each phase live: Provision → Sign → Install.
- Apple ID sign-in against Apple's GrandSlam service — modified SRP-6a (SHA-256,
  NG-2048, `s2k` password derivation) with two-step trusted-device 2FA. Your password is
  never passed on a command line and never written to disk.
- Device-provisioning (anisette) headers are generated **in-process and offline**, in
  pure Python. No Apple DLLs, and no third-party anisette server ever sees your session.
- TLS is verified against Apple's bundled `Apple Root CA` chain plus `certifi`.
  Verification is never disabled anywhere in the codebase.
- Full provisioning against Apple's developer services: issues a development
  certificate, registers the device, creates the App ID and downloads the provisioning
  profile. Free accounts are limited to one certificate, so a stale one is revoked
  first, and the App ID slots Apple allows per 7-day window are tracked for you
  (`slots`).
- Signing uses a purpose-built `zsign` (SHA-256 CodeDirectory, canonical DER
  entitlements), reproducibly compiled from source by `tools/zsign/build-zsign.sh`.
- Apps whose bundle id belongs to someone else — Instagram's `com.burbn.instagram`, say
  — are automatically given a team-scoped id, because Apple refuses to register an
  identifier you do not own.

### More than one Apple ID

- Sign in with several and keep them all. Home names the one in use and switches
  between them without asking for a password again — the session is already
  cached — and Settings lists them with their team, adds another, or signs one out
  without disturbing the rest. This matters because a free account may register
  only ten App IDs per 7-day window; a second Apple ID is how you keep going. It does
  not raise how many apps can be installed at once - iOS caps that at three per
  device across every free profile, whichever account signed them.
- **A refresh runs as the account that signed the app**, not whichever is selected.
  Re-signing an installed app with a different team's identity produces something
  iOS will not install over the existing copy, so the app simply stops opening —
  the opposite of what a refresh is for. Each sideload records its team, and each
  account records the team it provisions under, so the two can always be matched.
- When the account that signed an app is not signed in at all, iPASide says so by
  name and team rather than letting Apple answer with bare error 9401 ("An App ID
  with Identifier ... is not available"), which reads like a problem with the app
  instead of with which account is in use.
- Signing material is kept per account. Shared, a second Apple ID found the first
  one's private key, failed to match it against its own team's certificates, and
  revoked that team's only certificate to recover — breaking every app the other
  account had signed.
- Upgrading from a single-account build keeps you signed in: the old session is
  migrated on first read, and not left behind as a second copy to disagree with.

### Choosing where it goes, and how

- **Which device.** With more than one iPhone or iPad attached, pick the target from the
  sidebar; the Sideload screen names the device it is about to write to, directly above
  the button that does it. A single device is selected silently, and the choice is
  remembered between launches. The engine refuses to guess between two devices rather
  than picking one quietly.
- **Every screen follows that choice as you make it.** Home's status cards and the Apps
  list re-read when you pick a different phone, rather than describing whichever one was
  selected when the screen opened — which would put one device's details, transports and
  installed apps under another device's name, with an Uninstall button beside each.
- **Which connection.** Automatic, USB only, or Wi-Fi only. Automatic prefers the cable
  and falls back; the other two are honoured rather than treated as hints, so asking for
  USB fails with a clear message instead of quietly going over the air. Wi-Fi costs much
  more per round trip than it does per megabyte: reading a device's details took 132 ms
  over USB against 575 ms over Wi-Fi, while a complete 299 MB sideload took 95 s over USB
  against 108 s over Wi-Fi. Automatic reaches for the cable because the chatty parts of
  the job dominate, not the upload.

### Tweak injection

- Inject `.dylib` tweaks, or `.deb` packages directly: iPASide unpacks the `ar` archive
  and its `data.tar.{gz,xz,bz2,lzma,zst}` and pulls out every Mach-O dylib, labelled with
  its CPU architecture. Rootful, rootless and roothide layouts are all understood.
- Multiple tweaks per app, added by picker or by dropping them anywhere on the window,
  each row showing the dylib, its architecture and the `.deb` it came from.
- Optional weak linking, and injection into app extensions.

### Keeping apps alive

- Free-account provisioning profiles last 7 days. The **Library** tracks everything you
  have sideloaded with a live expiry countdown, and re-signs on demand per app or all at
  once — showing the same Provision → Sign → Install progress a first install does,
  because that is exactly what a refresh performs.
- An optional daily background refresh renews only what is due, through a Windows
  scheduled task. iPASide does not need to be open for it, a day the PC was off is
  caught up once it is back, and it is neither blocked by nor killed by running on
  battery. Verified by letting the Task Scheduler run it with the app closed: it
  launched with no window, re-signed and reinstalled a due app on the phone in 110
  seconds, and moved its expiry from one day left back to a full seven.

### Keeping the signed `.ipa`, if you want it

- Off by default. When enabled, the signed app is saved as `<original name>_Signed.ipa`
  in a folder you choose, so you can install or inspect it again without signing a
  second time. Settings reports how many are stored and how much space they take, and
  can delete them all after confirming.
- The signing workspace goes to the same folder, so pointing iPASide at a roomier disk
  moves all of the heavy I/O there rather than only the finished file.

### When Windows cannot reach your iPhone

- iPASide needs Apple Mobile Device Service for USB, and says so plainly when it is
  absent instead of implying the phone is unplugged. Three states, three different
  answers: nothing at all when it is running; **Start the service** when it is installed
  but stopped; **Install iTunes** when it is missing.
- Installing fetches Apple's current 64-bit iTunes installer, shows real download
  progress, and verifies it before running: the file must carry a valid Authenticode
  signature **and** be signed by Apple. Apple publishes no checksum, and a signature is
  the stronger claim anyway — a checksum only proves the bytes match a list you were
  handed, while a valid signature proves Apple produced them. Anything else is deleted
  and refused.

### Managing what is installed

- The **Apps** list shows everything on the device with its real home-screen icon, read
  from SpringBoard as a second pass so the list never waits on artwork.
- Uninstall from the app, with confirmation. Removing something from the Library
  uninstalls it from the device it was actually installed onto, which the registry
  records — not whichever device happens to be selected now.

### Advanced options

- Override the bundle id, display name and version; strip app extensions, the watch app
  or `UISupportedDevices`; enable file sharing.

### The app itself

- A chromeless Flutter desktop shell with seven screens — Home, Sideload, Library, Apps,
  Sign in, Diagnostics, Settings — in both light and dark themes, following the system
  theme with a manual override.
- Drop an `.ipa` anywhere on the window and it loads, switching to Sideload on its own;
  drop a `.deb` or `.dylib` and it joins the selected app's tweak list. Your selection
  survives moving between screens.
- Motion throughout — staggered entrances, hover lift, press feedback, an animated
  stepper — all respecting the OS "reduce motion" setting, and tuned so a screen settles
  in about a third of a second rather than assembling itself in front of you.
- **Diagnostics** reports the real state of your toolchain: Apple Mobile Device Service,
  the anisette provider, connected devices and the SDKs.
- Expected failures read as sentences. An unreachable device says which one and what to
  do about it, and an `.ipa` that has been moved or deleted since you chose it says so
  by name — which is the one a background refresh weeks later is most likely to hit.
  Only an actual bug produces a stack trace.

### Install progress you can actually read

- The install step streams the AFC upload byte by byte ("Uploading to iPhone · 120 /
  232 MB"), then `installd`'s own sub-steps as they happen — staging, extracting,
  inspecting, preflighting, verifying, creating the container, installing, sandboxing,
  finalising. Roughly 70 progress events per install, ending at 100%. iPASide drives the
  upload and the `installd` exchange itself, because the underlying library reports no
  upload progress and discards `installd`'s status.

### In-app updates

- iPASide compares its version against the latest GitHub release at startup — a version
  check only, nothing is downloaded uninvited. On request it downloads the installer and
  verifies its SHA-256 against the release's published `SHA256SUMS.txt` before offering
  to install it.
- Fail-closed throughout: a release with no checksums, or a download whose hash does not
  match the entry **for its filename**, is refused and discarded. Installing is always
  your click. A checksum published alongside the installer proves integrity, not
  authenticity, so an unattended install will only be defensible once releases are
  code-signed. Every release ships `SHA256SUMS.txt`.

### Installer

- A wizard in iPASide's own colours rather than the stock one: dark whatever the Windows
  theme, the brand mark on a panel, and a progress bar in the app's accent gradient. One
  screen carries the single real choice, then it installs.
- Upgrades are transactional. The previous install is renamed aside — a metadata-only
  move on the same volume, so milliseconds rather than copying hundreds of MB — and the
  upgrade commits only once the new engine *answers*: `ipaside_engine version` eagerly
  imports pymobiledevice3, unicorn's native library, cryptography and Pillow, so a zero
  exit proves the payload runs rather than merely arrived. Anything else restores what
  was there before, including a setup cancelled mid-copy. Every step is recorded in
  `%LOCALAPPDATA%\iPASide\install.log`.
- Uninstalling removes the program but leaves your signing material and settings alone.

### Performance

- Cold start is a few hundred milliseconds. The engine is a resident process
  (newline-delimited JSON over stdio) that imports once and serves many commands rather
  than paying Python startup per command, and it is prewarmed while the window is coming
  up.
- The engine is adopted into a Windows Job Object, so it is reaped even if iPASide is
  force-killed, and child processes are terminated as a tree so nothing strands `zsign`
  or device helpers.
- iPASide runs the engine it shipped, isolated from the environment, so a `PYTHONPATH`
  set elsewhere on the machine cannot substitute a different one.
- Shipped bytecode is precompiled, so a fresh install does not spend its first launch
  compiling Python.

### The engine on its own

- Everything the UI does is available as a CLI: `doctor`, `devices`, `device-info`,
  `developer-mode`, `apps`, `app-icons`, `install`, `uninstall`, `anisette`,
  `apple-support`, `login`, `teams`, `provision`, `sign`, `sideload`, `inspect`,
  `prepare`, `resolve-tweak`, `installs`, `refresh`, `signed`, `forget`, `slots`,
  `delete-app-id` and `version` — plus `serve`, the resident mode the app drives.
  `--json` works on all of them, and output is UTF-8 so non-ASCII app names survive
  Windows. Device commands take `--udid` and `--connection usb|wifi|auto`; `login`
  takes `--accounts`, `--use <email>` and `--logout [--email <email>]`.

### Quality

- A pytest suite over the engine and a Flutter suite over the shell, both run in CI
  alongside a full installer build on every push. Releases are built locally, verified
  against a real device, and published by hand — CI never uploads to a release, because
  there is no iPhone on a build runner.

### Known limitations

- **The installer is not code-signed**, so Windows SmartScreen will warn on first run.
  Verify the download against `SHA256SUMS.txt` if you want certainty. A signing
  certificate is the intended fix.
- **Signed apps expire after 7 days** and need re-signing. That is Apple's limit on free
  accounts, not ours — the Library and background refresh exist to make it painless.
- **Only three sideloaded apps can be installed at once**, per device. iOS enforces
  this itself, at install time, counting every app signed by any free Apple ID - so a
  second account does not add slots. Confirmed against an iPhone 8 Plus: the fourth
  install is refused with `ApplicationVerificationFailed`, and the three apps it
  named belonged to two different teams. Only a paid account lifts it.
- **App extensions are stripped**, so widgets, share sheets, keyboards and watch apps
  will not work. Free accounts cannot provision them.
- **App Store `.ipa` files are FairPlay-encrypted** and cannot be re-signed. iPASide
  detects this while inspecting and tells you rather than failing obscurely.
- **An app built for the wrong device is caught before signing.** A tvOS `.ipa` is
  indistinguishable from an iOS one from the outside - same zip, same
  `Payload/<App>.app` - so sent to an iPhone it installs and never launches. iPASide
  reads `CFBundleSupportedPlatforms` (falling back to `UIDeviceFamily`), compares it
  against the selected device's lockdown `DeviceClass`, and refuses only a genuine
  mismatch. `--allow-other-platform` overrides it.
- **Apple TV is not ruled out, only untested.** Provisioning is not the obstacle it
  appears to be: Apple registers an Apple TV and issues its profile through the same
  `ios/` endpoints iPASide already calls, which is why `DTDK_Platform`/`subPlatform` on
  those calls are ignored - a profile is scoped by the UDIDs in it, not by a platform.
  A tvOS `.ipa` going to an Apple TV is therefore allowed through. What is untested is
  reaching the device: a model with a USB port should pair over usbmux like any other,
  while a portless Apple TV needs network pairing over
  `_remotepairing-manual-pairing._tcp`, which is not implemented.
- **Tested with a free Apple ID, on one phone.** A complete sideload has been verified
  over both USB and Wi-Fi. Paid accounts should work and avoid the limits above, and two
  phones through the device picker is covered by tests rather than by hardware, but a
  free account and a single device is what has actually been exercised.
- **Wi-Fi needs Wi-Fi sync enabled** for the device, which is what makes Windows advertise
  it over the network at all. If iPASide reports the phone as USB-only while it is plainly
  on the same network, restarting Bonjour Service and Apple Mobile Device Service is what
  makes it appear — Apple's service discovers devices at startup and does not always pick
  up a change made after it.
- **Windows only** at present. The shell was chosen with a macOS port in mind; the
  deferred work is written down in [docs/macos-port.md](docs/macos-port.md).
