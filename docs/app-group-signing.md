# App Group signing

iPASide keeps `com.apple.security.application-groups` when that entitlement is already in the IPA. This is the normal sideload path. It is not a special case for one app.

EscapeOS 0.3.0 is the app that made the gap obvious. Its container access uses [worse_query](https://github.com/forcequitOS/worse_query), which needs an App Group the installed app is actually signed with. The same signer behavior applies to any other IPA that carries `group.*` identifiers.

## What was going wrong

A free provisioning profile grants only what was registered on the App ID before Apple issued the profile. App Groups are one of those features. The signer then signs with that profile.

If the IPA's executable was signed with `group.com.ipaside.escapeos` and iPASide never told Apple about that identifier, the new profile did not include it. The installed app lost the group. `containerURL(forSecurityApplicationGroupIdentifier:)` returned nil, and EscapeOS reported that it could not open the other app's data.

A custom certificate does the same kind of replacement from the other direction. eSign, using a distribution certificate whose profile already had its own groups (`group.<TEAM>.*`), installed EscapeOS with those groups and not `group.com.ipaside.escapeos`. Looking up only the original identifier failed even though the phone had real group containers. The device log for that install listed the certificate's groups under `com.apple.security.application-groups` and `GroupContainers`, and did not list `group.com.ipaside.escapeos`.

## What iPASide does now

On every sideload, before `ensure_signing_assets` downloads the profile:

1. `ipaside_engine.ipa.app_group_identifiers` opens the IPA, finds `Payload/<App>.app/<CFBundleExecutable>`, and reads the entitlements plist embedded in that executable.
2. It keeps strings that start with `group.`.
3. `run_sideload` unions those identifiers with any groups a named signing profile already requires. LiveContainer's groups stay. The IPA's groups are added if they are not already in that list.
4. `provision.ensure_signing_assets` enables the App Groups feature on the App ID, creates any missing group, assigns the groups, and only then downloads the profile. The literal `group.*` string is registered first. App Group identifiers are unique across every Apple Developer team, so if another team already holds that string Apple refuses it. iPASide lists the team's groups again. If the string is still absent, it registers `group.….<TEAMID>` instead and assigns that. An identifier this team can register is left unchanged.

The signer is not given a replacement entitlements plist for this. An explicit plist would replace the profile's entitlements. The profile Apple returns is what gets signed, and that profile now includes the groups.

Refresh signs from the original IPA again, so the same read happens on the next refresh. The group list does not have to be stored in the install record.

## How the entitlements are found

The code signature stores the entitlements as an XML plist inside the Mach-O, next to other plists. `_groups_in_signature` does not take the first `<?xml` in the file. It finds `com.apple.security.application-groups`, then the `<?xml` before that key and the `</plist>` after it, and parses that document. A blob that is not well-formed XML is skipped. The same key can appear again in a non-XML section of the signature; that copy is ignored if it does not parse as the entitlements plist.

Covered by `tests/test_ipa.py`:

- an executable that contains an entitlements plist yields its `group.*` identifiers, once each
- a value that does not start with `group.` is ignored
- an IPA with no such plist yields an empty list

The EscapeOS 0.3.0 IPA itself reads back as `['group.com.ipaside.escapeos']`.

## What EscapeOS does at runtime

iPASide's job is to put a real App Group on the signature. EscapeOS does not assume the identifier is always `group.com.ipaside.escapeos`.

`EscapeOSSignedAppGroups` reads `com.apple.security.application-groups` from the current process. If that list is empty, EscapeOS also parses `embedded.mobileprovision`. It prefers `group.com.ipaside.escapeos` when that identifier is entitled and its container URL resolves. Otherwise it uses the first entitled group whose container URL resolves.

That is why the same IPA works after an iPASide sign and after eSign with a custom certificate: the certificate's groups are the ones in the signature, and EscapeOS uses one of those.

## What this is not

There is no EscapeOS-only signing profile in iPASide. An earlier draft registered `group.com.ipaside.escapeos` only when the bundle id was `com.ipaside.escapeos`. That was removed. The general read-and-register path covers EscapeOS and any other IPA with the same kind of entitlement.

Passing `-e` with only the group list is intentionally not done. That flag replaces the profile entitlements, including `application-identifier` and `get-task-allow`.

This change ships in iPASide 1.2.15. An older installer does not keep App Groups from the IPA.
