# Mochi (v1 online)

Desktop golden retriever. Solo offline, or **bond with a partner** so they become the pet on your screen — feed / play / pet / nap sync both ways.

## Share across the internet

Host the tiny room server once on any Node host (Render, Railway, Fly, a VPS, etc.). Both of you point the app at that public URL.

### Example: Render (free)

1. Push this repo (or just the `server/` folder) somewhere GitHub can see.
2. [Render](https://dashboard.render.com) → **New** → **Web Service** → connect the repo.
3. Root directory: `server` · Build: `npm install` · Start: `node index.js`
4. After deploy you get something like `https://mochi-xxxx.onrender.com`
5. In the app (both devices): **Online → Set server URL…** →  
   `wss://mochi-xxxx.onrender.com`  
   (same host, `https` → `wss`)

Then bond as usual (create / join with the code). Works from any network.

> Free Render apps sleep when idle — first connect after a nap can take ~30s.

### Local / same Wi‑Fi

```bash
cd server && npm install && npm start
```

App default is `ws://127.0.0.1:3847`. Partner on LAN: `ws://YOUR_LAN_IP:3847`.

## Run the pet

```bash
./build.sh && open build/Mochi.app
```

## Bond

1. Both: **Online → Set my name…**
2. Both: **Online → Set server URL…** (public `wss://…` if remote)
3. One: **Online → Create bond** (code copied)
4. Other: **Online → Join partner…** paste code
5. Pet renames to the partner; Feed / Play / Pet / Nap sync both ways.
