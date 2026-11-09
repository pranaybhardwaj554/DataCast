# DataCast

Share a folder from your phone with any device on the same Wi-Fi. Visitors open the phone's address in a browser, pick a device from the list, enter its 4-digit PIN, and browse, view or download files.

## Layout

| Path | What |
|---|---|
| `lib/server/` | HTTP server (shelf): API, PIN auth and lockout, range requests, ZIP streaming |
| `lib/services/` | `SharingController` (app state for the UI), mDNS discovery (bonsoir), file sources, settings, native bridge |
| `lib/models/` | Plain data classes |
| `lib/ui/` | Flutter screens |
| `assets/web/` | Browser UI served by the phone |
| `android/app/src/main/kotlin/` | Folder picker and Storage Access Framework reads, foreground service, keeps the Flutter engine alive in the background |
| `docs/API.md` | HTTP API contract |

## Run

Requires Flutter (stable) and Android Studio with an Android SDK.

```sh
flutter pub get
flutter test          # server tests, no device needed
flutter run           # on a connected Android phone
```

Then tap Choose to pick a folder and Start sharing. Open the URL shown on another device on the same Wi-Fi.

## Notes

- Android: sharing continues with the app closed, through a foreground service with a Stop button in the notification. It uses the `dataSync` service type, which Android 15 limits to 6 hours a day.
- iOS: not wired up yet. iOS only allows the server while the app is open on screen.
