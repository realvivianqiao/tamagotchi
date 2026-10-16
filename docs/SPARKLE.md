# CoPet updates (Sparkle)

Friends install **once** (v0.4+ with Sparkle). After that, **Check for updates…** / daily auto-check pulls signed builds from the site.

## One-time: private key

Already generated for this Mac:

- **Public** (in `Info.plist` as `SUPublicEDKey`): ships inside every app
- **Private** (`secrets/sparkle_eddsa_private.key`): **gitignored** — back this up (1Password / encrypted drive). Losing it means every friend must reinstall manually.

To move to another Mac:

```bash
# on the new Mac, after ./scripts/fetch-sparkle.sh
mkdir -p secrets
# copy sparkle_eddsa_private.key into secrets/
```

## Each release

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in `Info.plist`
2. `UPDATE_NOTES='What changed' ./build.sh`
3. Commit + push `public/CoPet.zip`, `public/appcast.xml`, `public/version.json`
4. Wait for Render deploy

`version.json` remains so anyone still on the old custom updater (0.3.x) can climb to Sparkle once.

## Habits

- **Release on purpose** — not every experiment. Weekly-ish is fine.
- **Keep the server backward-compatible** for a version or two; old clients should get a clear update prompt, not a silent break.
- **Dev vs shipping** (later): a `com.vivianqiao.copet.dev` build pointed at a test server keeps experiments off friends’ bonds.
- **Developer ID ($99)** becomes worth it when you need stable macOS permissions across updates; ad-hoc + Sparkle EdDSA is fine until then.

## Feed

- Appcast: `https://tamagotchi-udtz.onrender.com/appcast.xml`
- Archive: `https://tamagotchi-udtz.onrender.com/CoPet.zip`
