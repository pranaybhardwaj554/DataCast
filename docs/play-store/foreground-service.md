# Foreground service declaration

Play Console → App content → Foreground service permissions.

**Type:** Connected device (`FOREGROUND_SERVICE_CONNECTED_DEVICE`)

**Feature description (paste):**

> DataCast lets the user share a folder or selected files from their phone with their own other devices (laptops, tablets, other phones) on the same local Wi-Fi network. When the user taps "Start sharing", the app runs a small web server on the local network, and the user opens the shown address on another device to browse and download the files. The foreground service keeps that local network connection and server running while the user switches to other apps or turns off the screen, which is necessary because the other device is actively connected to the phone and downloading files from it. Sharing starts only when the user taps Start, a persistent notification shows the address and PIN with a Stop button, and the service stops as soon as the user taps Stop.

**Why it can't be deferred or interrupted (paste):**

> The connected device downloads files directly from the phone over the local network in real time. If the system stopped the service, open pages and in-progress downloads on the other device would fail immediately. The work cannot be scheduled with WorkManager because it serves requests from another device the moment they arrive.

**Video:** a 30 to 60 second screen recording on the phone: open DataCast, pick a folder, tap Start sharing, show the notification, then switch to another app and (on a laptop, filmed or screen-recorded) open the URL and download a file, then tap Stop in the notification. Upload it to YouTube as Unlisted and paste the link.

## Why connectedDevice and not dataSync

`dataSync` would also describe file transfer, but Android 15+ caps it at 6 hours per 24 hours and then stops the service, and Google has said it will be deprecated. `connectedDevice` covers "interactions with external devices that require a network connection", has no time cap, and its runtime prerequisite (`CHANGE_WIFI_MULTICAST_STATE`, a normal permission granted at install) is already used for mDNS discovery.

If Play review rejects connectedDevice, the fallback is `specialUse` with a `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` of "local network file server"; that needs the same description and video.
