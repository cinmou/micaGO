# Remote Access with Cloudflare Tunnel

This guide shows how to reach your Mac from **outside your home network** using
your **own domain** and **Cloudflare Tunnel**.

> ℹ️ **Cloudflare Tunnel is external and optional.** micaGO does **not** bundle,
> install, or manage Cloudflare. You set up and run the tunnel yourself with
> your own Cloudflare account and domain. If you prefer a different reverse
> proxy or tunnel, the same idea applies — micaGO just needs a public HTTPS URL
> that forwards to the local server.

## Why a tunnel?

Your Mac's server normally listens only on your home network. A tunnel gives you
a stable public HTTPS address (e.g. `https://micago.example.com`) that securely
forwards traffic to the server running on your Mac — without opening ports on
your router.

## Recommended architecture

```
Android client
  -> https://micago.example.com            (your domain, HTTPS)
  -> Cloudflare Tunnel                 (Cloudflare's edge)
  -> cloudflared on your Mac           (the tunnel client you run)
  -> http://127.0.0.1:<PORT>           (the micaGO server on your Mac)
```

Your token still protects every request, end to end. The tunnel only moves
traffic; it does not replace authentication.

## Step 1 — Get a domain

Use a domain you own, or buy one (from Cloudflare Registrar or any registrar).
In the examples below, replace `micago.example.com` with your own hostname.

## Step 2 — Add the domain to Cloudflare

1. Create a free Cloudflare account.
2. Add your domain as a **site** in the Cloudflare dashboard.
3. Update your domain's nameservers to the ones Cloudflare gives you (if your
   domain is registered elsewhere). Wait until Cloudflare shows the domain as
   **Active**.

## Step 3 — Install cloudflared on macOS

The easiest way is Homebrew:

```bash
brew install cloudflared
```

(You can also download `cloudflared` from Cloudflare's website.)

## Step 4 — Log in

```bash
cloudflared tunnel login
```

A browser opens; pick the domain you added. This authorizes `cloudflared` and
stores a certificate under `~/.cloudflared/`.

## Step 5 — Create a named tunnel

```bash
cloudflared tunnel create micago-server
```

This prints a **tunnel ID** and writes a credentials file to
`~/.cloudflared/<tunnel-id>.json`. Note the tunnel ID; you'll reference it next.

## Step 6 — Route your hostname to the tunnel

```bash
cloudflared tunnel route dns micago-server micago.example.com
```

This creates the DNS record that points `micago.example.com` at your tunnel.

## Step 7 — Write the config file

Create `~/.cloudflared/config.yml`. Replace `<you>`, `<tunnel-id>`, and
`<PORT>` with your values (the default micaGO port is `3000`, but use whatever
the Mac app shows):

```yaml
tunnel: micago-server
credentials-file: /Users/<you>/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: micago.example.com
    service: http://127.0.0.1:<PORT>
  - service: http_status:404
```

The first `ingress` rule forwards your hostname to the local micaGO server. The
final `http_status:404` rule is required as a catch‑all.

## Step 8 — Run the tunnel

```bash
cloudflared tunnel run micago-server
```

Leave this running while you test. You should see it connect to Cloudflare's
edge.

### Optional: install as a background service

If you want the tunnel to start automatically and keep running, you can install
it as a service. **This is optional** — running it manually (Step 8) is fine for
testing:

```bash
cloudflared service install
```

## Step 9 — Enter the public URL in the micaGO Mac app

1. Open the Mac app → **Connections** → **Connection Endpoints** →
   **Public / remote**.
2. In the **Public URL** field, paste the bare origin:

   ```
   https://micago.example.com
   ```

   Enter the **origin only** — no trailing path, no `/api`, no `/ws`. The app
   warns you inline if the URL has a path or isn't `http(s)`.
3. Leave **Verify TLS certificate** on for a normal HTTPS domain, then click
   **Save**. The URL is written to the server config and **survives app
   restarts**.

## Step 10 — Validate the public URL

Click **Validate Public URL**. micaGO asks its own server to confirm that the
public URL loops back to **this** Mac and that the bearer token is accepted. The
result is shown in plain language (the token is never displayed):

- **Reachable and the token was accepted — Public is ready for pairing.** ✅
- *Couldn't reach the public URL…* → tunnel not running / wrong port.
- *Reached a server, but it rejected the token (401)…* → the URL points at a
  different server.
- *…no server answered behind it (502)…* → the tunnel is up but micaGO isn't
  running on the forwarded port.

### What success looks like

- The Public section shows **Status: Reachable** (and a **Cloudflare Tunnel**
  provider hint when detected).
- In **Client Setup**, the **Auto** endpoint now resolves to **Public**.
- Use **Show QR code** / **Copy setup JSON** to pair the Android client; it can
  then connect over mobile data using `https://micago.example.com`.

## Push notifications when you're away (remote)

A common goal is: *be on mobile data, away from home Wi‑Fi, and still get notified
of new iMessages.* Here's how the tunnel fits into that.

**The push itself does not go through the tunnel.** The flow is:

```
new iMessage ─► your Mac (server) ─► FCM (Google) ─► your phone   ← the "wake"
                                                          │
              phone fetches the actual message via delta sync ◄──┘
                         over https://micago.example.com  ← the tunnel
```

- The **wake** (FCM push) is delivered by Google directly to the phone — it works
  on mobile data with no tunnel. For it, the **Mac just needs outbound internet**
  to reach `fcm.googleapis.com` (the tunnel is not involved).
- But a push is only a wake signal — the **message content is pulled from your
  server** over WebSocket / delta sync. When the phone is **off your Wi‑Fi**, it
  can only reach the server through a **public URL**. That's what the Cloudflare
  Tunnel custom domain provides.

So, to get useful remote push:

1. Complete this guide so `https://micago.example.com` shows **Reachable** in
   **Connection Endpoints → Public**.
2. Pair (or re‑pair) the Android client while **Public** is reachable, so its
   saved profile includes the public URL. The client auto‑selects Public when it
   can't reach a LAN route (e.g. on mobile data).
3. Set up your own Firebase push — see
   [notifications-setup.md](notifications-setup.md). FCM and the public URL are
   independent pieces: FCM wakes the phone, the public URL lets it sync.
4. Test it: put the phone on **mobile data** (Wi‑Fi off), background the app, and
   send yourself an iMessage. You should get the notification, and tapping it
   should open the chat (the client delta‑syncs over the public URL).

**Optional — let the client learn the public URL automatically.** In the
Companion's **Notifications** settings you can enable **Firebase public‑URL sync**,
which publishes the current public URL to your own Firebase so clients can pick up
a changed tunnel hostname without re‑pairing. It's optional; pairing with Public
reachable already embeds the URL.

> Keep‑alive is **not** a substitute here: when the app is killed on mobile data,
> only the FCM wake (with a reachable public URL for the follow‑up sync) reliably
> notifies you. Keep‑alive helps a backgrounded app, subject to OEM battery
> limits.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Validate fails, but local works | Tunnel not forwarding to the right place | Check `service:` in `config.yml` points to `http://127.0.0.1:<PORT>` with the **correct port** shown in the Mac app. |
| Connection refused / 502 from the tunnel | Server bound to the wrong address, or not running | Make sure the micaGO server is running and listening on the port your `config.yml` forwards to. |
| `micago.example.com` does not resolve | Hostname not routed in Cloudflare | Re‑run `cloudflared tunnel route dns micago-server micago.example.com` and confirm the DNS record exists. |
| Everything 401 (Unauthorized) | Wrong or stale token | Re‑copy the token from the Mac app; make sure devices use the same token. |
| Validate fails right after starting | Tunnel not running | Run `cloudflared tunnel run micago-server` and try again. |
| Works locally, fails publicly with a path error | You pasted a URL **with a path** | Use the bare origin `https://micago.example.com`, not `https://micago.example.com/api` or `.../ws`. |
| WebSocket won't connect but REST works | Proxy not passing WebSocket upgrades, or wrong scheme | Cloudflare passes WebSockets by default; confirm the client uses `wss://micago.example.com/ws` (HTTPS → `wss`). Make sure the tunnel is running. |
| Random outside testers could reach it | Public URL + token is all that's needed | Keep the token secret; rotate it if exposed. Consider Cloudflare Access for an extra gate (optional, advanced). |

> ⚠️ Once your server is public, anyone with the URL **and** the token can reach
> it. Treat the token like a password and rotate it if you suspect a leak.
