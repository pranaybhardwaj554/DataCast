# DataCast security notes

DataCast runs an HTTP server on a phone and lets anyone on the same Wi-Fi browse a shared folder after entering a 4-digit PIN. This file lists the attacks that apps of this kind are known to suffer, what DataCast does about each, and what is still open. The regression tests live in `test/security_test.dart`.

## Who we defend against

1. **Someone else on the same Wi-Fi** (café, office, hotel). They can reach port 8080 directly, run scripts, use many IP addresses, and watch unencrypted traffic.
2. **A web page the visitor opens in another tab.** It can make the visitor's browser send requests into the LAN (CSRF, DNS rebinding).
3. **A hostile file inside the shared folder** (a downloaded `.html`, `.svg`, or a file with a crafted name) that tries to attack the visitor.
4. **Someone on the phone's mobile network** when the phone has Wi-Fi and mobile data at once.

Real-world precedents: ES File Explorer's open port 59777 let anyone on the LAN read files (CVE-2019-6447); Webile 1.0.1 and many "Wi-Fi file transfer" apps had directory traversal (CVE-2022-50890); DNS rebinding against local servers is a standing issue (it was recently fixed across MCP SDKs by validating `Host`).

## What is covered

| Attack | Status | How |
|---|---|---|
| Path traversal (`../`, `%2e%2e`, `\`, NUL) | Already safe | `normalizeSharePath` rejects `.`/`..` segments, backslashes and NUL after URL decoding. |
| **Symlink escape** (`/link-to-root/etc/passwd`) | **Fixed** | Listings hid links, but a link in the middle of a path was followed by the OS. `IoFileSource` (desktop, iOS) now refuses any path whose components include a symlink. Android SAF has no symlinks. |
| PIN brute force from one IP | Already safe | 5 tries, then a lockout that doubles from 30 s. |
| **PIN brute force from many IPs** | **Fixed** | On a LAN it is trivial to switch IPs, so 10,000 PINs fell in minutes. Wrong PINs from all clients now share a budget of 20 per lockout, doubling each time. Signed-in visitors keep working. `PinAuth.onBruteForce` fires so the app can warn the owner. |
| Memory growth from many IPs failing | **Fixed** | Per-IP failure records are capped at 1,024. |
| Oversized `POST /api/auth` body | **Fixed** | Capped at 4 KB (`413`). |
| **DNS rebinding** | **Fixed** | Requests whose `Host` is a public DNS name are refused. Only IPs, `localhost`, `.local` and single-label names are served. |
| CSRF | Hardened | Cookie is `SameSite=Strict`; cross-origin `POST`s (by `Origin`) are now refused too. |
| **Stored XSS via shared `.html`/`.svg` files** | **Fixed** | `/api/raw` served user files inline on the app's origin, so an HTML file opened there could use the visitor's session to read everything. Files now get `Content-Security-Policy: sandbox` with no script, plus `Cross-Origin-Resource-Policy: same-origin`. |
| XSS via file names | Already safe | The web UI writes names with `textContent`/attributes, never `innerHTML`. The page now also has a strict CSP (`script-src 'self'`). |
| Header injection via file names | Already safe | `Content-Disposition` escapes quotes and non-ASCII and uses RFC 5987 `filename*`. |
| **Zip slip** (entry names with `../`, `\`, `C:`) | **Fixed** | Provider display names (SAF, iOS) are not guaranteed to be clean, so every ZIP entry segment is now sanitized. |
| **Server crash from huge `Range` numbers** | **Fixed** | `bytes=99999999999999999999-` threw and returned 500; now `416`. |
| **Exposure over mobile data / carrier NAT** | **Fixed** | The server binds all interfaces; it now refuses clients outside private, link-local and loopback ranges. 100.64/10 is refused on purpose. |
| Leaking the folder name before the PIN | **Fixed** | `/api/info` returns `folderName: null` until signed in. |
| Session fixation | Already safe | Tokens are 192-bit random values issued by the server only after the PIN. |
| Clickjacking | Already safe | `X-Frame-Options: SAMEORIGIN`, CSP `frame-ancestors 'self'`. |
| Thumbnail DoS | Already safe | 3 decoders, 3 s queue, 8 s per decode. |

## Known limits (not fixed, by design or for later)

- **No HTTPS.** Traffic, the PIN and the token are visible to anyone sniffing an open Wi-Fi network. A self-signed certificate would make every browser show a scary warning. Advice to users: use a trusted or WPA2/WPA3 network, or the phone's own hotspot.
- **4-digit PIN.** With the global limit above, guessing takes days of continuous attempts, but a 6-digit option would be stronger.
- **mDNS spoofing.** Any LAN device can advertise itself with any device name. The device list shows IPs; the web UI could also show the IP on the PIN screen.
- **mDNS reveals the device name** (often a person's name) to the whole network while sharing.
- **The PIN is shown on screen**, so shoulder-surfing is possible.
- **App wiring:** `PinAuth.onBruteForce` is not yet connected to a notification or "new PIN" prompt in the app.
