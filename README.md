# DataCast

Share a folder from your phone with any device on the same Wi-Fi. Visitors open the phone's address in a browser, pick a device from the list, enter its 4-digit PIN, and browse, view or download files. No app is needed on the visiting device.

## Features

- Share a whole folder, or just a few picked files.
- Works on Android and iOS. Several phones running DataCast on the same network find each other over mDNS (`_datacast._tcp`), and the browser lists them all so you can switch between them.
- Each phone has its own 4-digit PIN. The phone you are already signed in to shows as Current, so you can go back to its files without typing the PIN again.
- In the browser: folder browsing, image and video thumbnails, in-page previews, video streaming with seeking, single-file downloads and whole-folder ZIP downloads (can be turned off in Settings).
- Hardened for shared networks: PIN lockouts (per device and across all devices), LAN-only clients, DNS rebinding and CSRF checks, sandboxed file previews, and symlink and zip slip protection. See `docs/SECURITY.md`.

## Layout

| Path | What |
|---|---|
| `lib/server/` | HTTP server (shelf): API, PIN auth and lockout, request checks, range requests, ZIP streaming |
| `lib/services/` | `SharingController` (app state for the UI), mDNS discovery (bonsoir), file sources (Android SAF, iOS bookmarks, picked files), settings, native bridge |
| `lib/models/` | Plain data classes |
| `lib/ui/` | Flutter screens |
| `assets/web/` | Browser UI served by the phone |
| `android/app/src/main/kotlin/` | Folder picker and Storage Access Framework reads, foreground service, keeps the Flutter engine alive in the background |
| `ios/Runner/NativeBridge.swift` | Files picker with security-scoped bookmarks, QuickLook thumbnails, short background grace while sharing |
| `docs/API.md` | HTTP API contract |
| `docs/SECURITY.md` | Threat model and what is covered |

## Run

Requires Flutter (stable). For Android, Android Studio with an Android SDK. For iOS, Xcode (iOS 15 or later).

```sh
flutter pub get
flutter test          # server and security tests, no device needed
flutter run           # on a connected Android phone or iPhone
```

Then tap Choose to pick a folder and Start sharing. Open the URL shown on another device on the same Wi-Fi.

## Notes

- Android: sharing continues with the app closed, through a foreground service with a Stop button in the notification. It uses the `connectedDevice` service type, which has no daily time limit.
- iOS: the server runs only while the app is open on screen, with about 30 seconds of grace after it goes to the background. iOS asks for Local Network permission the first time you share.
- There is no HTTPS, so use a trusted Wi-Fi network or the phone's own hotspot.
- Play Store release: signing, store listing, privacy policy and Play Console answers are in `docs/play-store/` (start with `RELEASE.md`).
