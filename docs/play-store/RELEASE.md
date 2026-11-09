# Releasing DataCast on Google Play

Everything here is for the Android app (`com.pranaybhardwaj.datacast`). The app ID is permanent once the first build is uploaded.

## 1. Create the upload key (once)

Run this on your Mac, outside the repo. It asks for a password and some name fields (only the name is needed; the rest can be blank).

```sh
keytool -genkey -v \
  -keystore ~/keys/datacast-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

(`mkdir -p ~/keys` first if the folder doesn't exist. `keytool` ships with Android Studio's JDK: if it isn't on your PATH, use `"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"`.)

Back up `datacast-upload.jks` and its password in a password manager. With Play App Signing (step 4), Google holds the real app-signing key, so a lost upload key can be reset through Play support, but it takes days.

## 2. Point the build at the key

Create `android/key.properties` (git-ignored, never commit it):

```properties
storePassword=the password you chose
keyPassword=the password you chose
keyAlias=upload
storeFile=/Users/pranaybhardwaj/keys/datacast-upload.jks
```

`android/app/build.gradle.kts` reads this file. Without it, release builds fall back to the debug key, which Play rejects.

## 3. Build the bundle

```sh
flutter clean
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`.

Before each new upload, bump `version:` in `pubspec.yaml`. The number after `+` is the versionCode and must go up every upload (for example `1.0.0+1`, then `1.0.1+2`).

Check the target SDK: Play requires new apps and updates to target the latest required API level (API 36 from August 2026). Flutter sets `targetSdk` from its own defaults; confirm with
`grep -r targetSdk build/app/intermediates/merged_manifests/release/ 2>/dev/null` after a build, or in Play Console's bundle explorer after upload.

## 4. Play Console setup

1. Create the app: name **DataCast**, type App, Free.
2. Accept **Play App Signing** when you upload the first bundle (default).
3. Fill in **App content** using the files in this folder:
   - Privacy policy URL: host `privacy-policy.html` publicly (see below) and paste the URL.
   - Data safety: `data-safety.md`.
   - Foreground service permissions: `foreground-service.md`. You'll need a short screen recording.
   - App access: "All functionality is available without special access" (there is no login; the PIN is generated on the phone).
   - Ads: No ads.
   - Content rating: run the IARC questionnaire. DataCast has no user-generated content shared with strangers, no chat, no location sharing; answer No to all; expected rating is Everyone / PEGI 3.
   - Target audience: 18+ (or 13+). Don't pick under-13 ages, or the Families policy applies.
   - Government / financial / health app: No.
4. **Store listing**: text in `store-listing.md`; graphics in `store/` (icon 512x512, feature graphic 1024x500). You also need at least 2 phone screenshots from the real app (take them on your phone during the test).
5. **Testing**: new personal developer accounts must run a closed test with at least 12 testers opted in for 14 days in a row before Production access unlocks. Organization accounts skip this. Start the closed test early.

## Hosting the privacy policy

Play needs a public https URL that is not a PDF. Easiest options:

- GitHub Pages: put `privacy-policy.html` in a public repo (or a `docs/` folder with Pages turned on) and use `https://<user>.github.io/<repo>/privacy-policy.html`.
- Google Sites: paste the text into a new page and publish.

## Permissions (reviewed)

| Permission | Why DataCast needs it | Play declaration |
|---|---|---|
| INTERNET | Runs the local HTTP server that other devices connect to | None |
| ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE | Finds the phone's Wi-Fi address to show the URL and QR code | None |
| CHANGE_WIFI_MULTICAST_STATE | mDNS so other DataCast devices and browsers can find this phone; also the runtime prerequisite for the connectedDevice service type | None |
| WAKE_LOCK | Keeps the CPU and Wi-Fi awake while files are being served with the screen off | None |
| FOREGROUND_SERVICE, FOREGROUND_SERVICE_CONNECTED_DEVICE | Keeps sharing running with the app in the background, with a visible notification and Stop button | Foreground service declaration |
| POST_NOTIFICATIONS | Shows the sharing notification (Android 13+ asks the user) | None |

No storage, media, location or contacts permissions. Files are read through the Storage Access Framework picker, so the user grants access to exactly the folder or files they pick.
