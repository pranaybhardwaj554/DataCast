# DataCast HTTP API

Every device running DataCast serves this API on its own address (default port 8080, next free port if busy). The browser UI in `assets/web/` is served at `/`; unknown extension-less paths fall back to `index.html`.

All paths are relative to the shared folder: `/` is the root, `/Photos/a.jpg` a file. Paths containing `..` or `.` segments are rejected with `400`.

## Public

| Method | Path | Response |
|---|---|---|
| GET | `/api/info` | `{name, deviceId, platform, requiresPin, authenticated, sharing, folderName, allowZip, apiVersion}` |
| GET | `/api/devices` | `[{deviceId, name, ip, port, platform, url, self}]`. This device first (`self: true`), then devices found over mDNS (`_datacast._tcp`). To open another device, navigate to its `url`; each device has its own PIN. |
| POST | `/api/auth` | Body `{"pin":"1234"}` (JSON or form). `200 {token}` and sets cookie `dc_token` (HttpOnly, SameSite=Strict). Wrong PIN: `401 {error, attemptsLeft}`. After 5 wrong PINs from one IP: `429 {error, retryAfterSec}`; the lockout starts at 30 s and doubles each time. |
| POST | `/api/logout` | Clears the cookie. |

## Needs a token (cookie `dc_token` or `Authorization: Bearer <token>`)

Without a valid token: `401 {error}`. When nothing is shared: `503 {error}`.

| Method | Path | Response |
|---|---|---|
| GET | `/api/files?path=/sub` | `{path, name, entries:[{name, path, isDir, size, modified, mime}]}`. Folders first, then by name. |
| GET/HEAD | `/api/download?path=` | File as `attachment`. Supports `Range`. |
| GET/HEAD | `/api/raw?path=` | File `inline` for previews and video. Supports a single `Range` (`206`, `416`). |
| GET | `/api/zip?path=` | Folder as an uncompressed ZIP stream (ZIP64 for files over 4 GB). `403` when `allowZip` is off. |

Tokens expire after 12 hours idle. Changing the PIN, or stopping sharing, signs everyone out.
