# Codex Context

## Project

`LAN Scanner` is a native macOS SwiftUI app for scanning Magnus' local LAN. It detects the active private IPv4 network, scans the `/24`, reads ARP data where available, resolves names, detects common service ports, and highlights likely Raspberry Pi / home automation devices.

The app is intentionally local-first and small. It is not a hosted service.

## Repository

- Local path: `/Users/magnus/Documents/GitHub/lan-scanner`
- Swift package product: `LANScanner`
- Minimum platform: macOS 14
- App bundle output: `dist/LAN Scanner.app`
- DMG output: `dist/lan-scanner.dmg`

## Build

Useful commands:

```bash
swift build
Scripts/build-app.sh
Scripts/build-app.sh debug
Scripts/build-dmg.sh
```

`Scripts/build-app.sh` builds the Swift package, assembles `dist/LAN Scanner.app`, removes extended attributes, ad-hoc-signs the app, and verifies it with `codesign --verify --deep --strict`.

`Scripts/build-dmg.sh` builds the release app, creates a writable APFS DMG, copies the app into it, adds an `/Applications` symlink, clears extended attributes inside the mounted volume, ad-hoc-signs/verifies the app inside the volume, converts the DMG to compressed read-only `UDZO`, and verifies the DMG.

## Distribution Notes

2026-06-30: Downloading `lan-scanner.dmg` from `https://server.egelberg.se/lan-scanner.dmg` works, and the app can be made `codesign`-valid with ad-hoc signing. This is not enough for a frictionless double-click install from Safari on another Mac.

For a normal friend-facing web download, Apple Gatekeeper requires Developer ID signing and notarization. Without that, macOS may show warnings such as:

- "Apple could not verify that LAN Scanner is free from malware"
- "LAN Scanner is damaged and can't be opened" when the signature or extended attributes are wrong

Do not present `xattr -dr com.apple.quarantine` as an acceptable non-technical user solution unless Magnus explicitly asks for a workaround. It works technically, but it is not the simple installation experience he wants.

When checked on 2026-06-30, `security find-identity -v -p codesigning` returned `0 valid identities found`, so this Mac could not produce a real Developer ID-notarized release.

## Visual Design

### 2026-07-18

- Den automatiska scanningen körs nu 60 sekunder efter att föregående scan avslutats, i stället för efter 120 sekunder. Den kombinerade Scan-kontrollen fylls under väntetiden som en sann nedräkningsprogress; när scanningen startar växlar samma ring till faktisk adressprogress och pilen roterar. Hover och accessibility visar återstående sekunder när appen väntar.

- Scan-pillens text och separata spinner har ersatts av en kompakt 36 × 36 px Scan-kontroll, inspirerad av Vitels kombinerade progress-/uppdateringsknapp. Den fasta cirkeln är knappens ram, den inre progresslinjen visar verkligt antal färdigtestade adresser av 254 och pilen roterar endast medan scanningen pågår. När kontrollen är ledig startar ett klick en ny scan; hjälptext och accessibility-värde visar funktion respektive procent.

`LAN Scanner` and `/Users/magnus/Documents/GitHub/broker-explorer` are sister
tools. Keep their `hard`, `grass`, and `clay` themes visually synchronized:
same RGB palette, same 8px panel radius, same panel border treatment, and the
same tennis-surface theme naming (`US Open`, `Wimbledon`, `Roland Garros`).

## Gotchas

- `dmgbuild` and simple `hdiutil create -srcfolder` flows caused Finder metadata / extended attributes on the `.app` inside the DMG, which broke strict code-sign verification with errors like `resource fork, Finder information, or similar detritus not allowed`.
- The current `build-dmg.sh` flow exists to avoid that by signing the app after it has been copied into the mounted writable DMG.
- If the DMG or build process changes, verify the app after mounting the final DMG:

```bash
hdiutil attach -nobrowse -readonly dist/lan-scanner.dmg
codesign --verify --deep --strict --verbose=4 "/Volumes/LAN Scanner Installer/LAN Scanner.app"
spctl -a -vvv -t exec "/Volumes/LAN Scanner Installer/LAN Scanner.app"
```

`codesign_status=0` means the bundle is structurally signed correctly. `spctl` rejection still means the app is not Developer ID-notarized.

## Related Infrastructure

`server.egelberg.se` is served by Apache on `pi-kato` from `/var/www/html`. The public DMG path used during testing was:

```text
https://server.egelberg.se/lan-scanner.dmg
```

That hosting fact also lives in the global context at `/Users/magnus/Documents/GitHub/codex-chat/CONTEXT.md`.
