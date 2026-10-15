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
- **On each Mac** (source of truth): your name, species, and friend list + invite codes are saved in the app’s UserDefaults. Quitting Mochi keeps your bonds.
- **On the server**: only a realtime relay + a best-effort invite directory. Live rooms are ephemeral. If Render redeploys and forgets, each app re-attaches with its saved code and the bond comes back — no re-invite needed for already-bonded friends.
- Optional: set `MOCHI_DATA_DIR` on Render (persistent disk) so the invite file survives redeploys too.

## Dev
```bash
./build.sh && open build/Mochi.app
npm start
```
