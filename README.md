# Mochi

A tiny Mac desktop pet. Download, invite someone, feed/pet/play — they see it live.

**Site + download:** https://tamagotchi-udtz.onrender.com

## How it works
1. Download Mochi from the site
2. Open the app — you have a pet
3. 🐶 → **Invite partner…** (copies a message with a code)
4. They download → **Claim invite…** → paste code
5. Bonded. Actions sync both ways.

## Where data lives
- **Supabase** (cloud source of truth): name, species, friend list, and bond codes are stored in `mochi_players` + `mochi_bonds`. See `supabase/schema.sql`.
- **On each Mac**: a local cache (UserDefaults) + a stable `deviceId`, so the app still works offline and then syncs.
- **Render**: realtime WebSocket relay. Set `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` on the web service.

## Dev
```bash
./build.sh && open build/Mochi.app
npm start
```
