# Mochi

A tiny Mac desktop pet. Download, invite someone, feed/pet/play — they see it live.

**Site + download:** https://tamagotchi-udtz.onrender.com

## How it works
1. Download Mochi from the site
2. Open the app — you have a pet
3. 🐶 → **Invite partner…** (copies a message with a code)
4. They download → **Claim invite…** → paste code
5. Bonded. Actions sync both ways.

## Dev
```bash
./build.sh && open build/Mochi.app
cd server && npm start
```
