# CoPet

A tiny Mac desktop pet. Download, invite someone, feed/pet/play — they see it live.

**Site + download:** https://tamagotchi-udtz.onrender.com

## How it works
1. Download CoPet from the site
2. Open the app — you have a pet
3. Menu → **Invite friend…** (copies a code)
4. They download → **Claim invite…** → paste code
5. Bonded. Actions sync both ways.

## Gatekeeper
The zip is **ad-hoc signed** (not Apple Developer ID). Friends may see “Apple could not verify CoPet” — **System Settings → Privacy & Security → Open Anyway**, or right-click → Open. Work laptops may still need IT. Wider sharing needs a paid Apple developer account + notarization.

## Auto-updates (Sparkle)
v0.4+ uses [Sparkle](https://sparkle-project.org) with EdDSA-signed `appcast.xml`. Friends download once; then updates install in-app. See [docs/SPARKLE.md](docs/SPARKLE.md). **Back up `secrets/sparkle_eddsa_private.key` — never commit it.**

## Where data lives
- **Supabase** (source of truth across Render sleeps/redeploys): `mochi_players` + `mochi_bonds`. See `supabase/schema.sql`.
- **On each Mac**: UserDefaults cache + stable `deviceId` (one device = one pad).
- **Render**: realtime WebSocket only — set `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` so bonds survive idle sleep.

## Dev
```bash
./build.sh && open build/CoPet.app
npm start
```
