# DataCast HTTP API

Every device running DataCast serves this API on its own address (default port 8080, next free port if busy). The browser UI in `assets/web/` is served at `/`; unknown extension-less paths fall back to `index.html`.

In `files` mode (the user picked individual files instead of a folder), the root `/` is a flat virtual folder holding just those files, with ` (2)`-style suffixes on duplicate names, and `folderName` reads like `3 files`.

All paths are relative to the shared folder: `/` is the root, `/Photos/a.jpg` a file. Paths containing `..` or `.` segments are rejected with `400`.

## Public

| Method | Path | Response |
|---|---|---|
| GET | `/api/info` | `{name, deviceId, platform, requiresPin, authenticated, sharing, folderName, allowZip, mode, thumbs, apiVersion}`. `mode` is `folder` or `files`. `folderName` is `null` until the caller is signed in. |
| GET | `/api/devices` | `[{deviceId, name, ip, port, platform, url, self}]`. This device first (`self: true`), then devices found over mDNS (`_datacast._tcp`). To open another device, navigate to its `url`; each device has its own PIN. |
| POST | `/api/auth` | Body `{"pin":"1234"}` (JSON or form). `200 {token}` and sets cookie `dc_token` (HttpOnly, SameSite=Strict). Wrong PIN: `401 {error, attemptsLeft}`. After 5 wrong PINs from one IP, or 20 from all clients together: `429 {error, retryAfterSec}`; each lockout starts at 30 s and doubles each time. Bodies over 4 KB: `413`. |
| POST | `/api/logout` | Clears the cookie. |

## Needs a token (cookie `dc_token` or `Authorization: Bearer <token>`)

Without a valid token: `401 {error}`. When nothing is shared: `503 {error}`.

| Method | Path | Response |
|---|---|---|
| GET | `/api/files?path=/sub` | `{path, name, entries:[{name, path, isDir, size, modified, mime}]}`. Folders first, then by name. |
| GET/HEAD | `/api/download?path=` | File as `attachment`. Supports `Range`. |
| GET/HEAD | `/api/raw?path=` | File `inline` for previews and video. Supports a single `Range` (`206`, `416`). |
| GET | `/api/thumb?path=&size=256` | JPEG thumbnail, longest side 128, 256 or 512 (default 256), EXIF orientation applied. Images and, on Android 10+, videos. `ETag` + `Cache-Control: private, max-age=86400`; `304` on `If-None-Match`. `415` when the file can't be thumbnailed. At most 3 are generated at once. |
| GET | `/api/zip?path=` | Folder as an uncompressed ZIP stream (ZIP64 for files over 4 GB). `403` when `allowZip` is off. |

Tokens expire after 12 hours idle. Changing the PIN, or stopping sharing, signs everyone out.

## Request checks (all endpoints)

These come before everything above and answer `403 {error}`:

- The client's address must be loopback, link-local or private (10/8, 172.16/12, 192.168/16, IPv6 ULA). Carrier NAT (100.64/10) and public addresses are refused, so the phone is not reachable over mobile data.
- The `Host` header must be an IP address, `localhost`, a `.local` name or a single-label name. Other host names are refused (DNS rebinding).
- A `POST` with an `Origin` header must come from the same origin. A missing `Origin` is allowed.

Every response carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: SAMEORIGIN` and a `Content-Security-Policy`. Files from `/api/raw` and `/api/download` get a `sandbox` CSP with no script (PDFs excepted) and `Cross-Origin-Resource-Policy: same-origin`. See `docs/SECURITY.md`.
