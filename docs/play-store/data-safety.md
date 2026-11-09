# Data safety form answers

Play Console → App content → Data safety.

## Data collection and security

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |

That's the whole form when the answer is No. Play then shows "No data collected" and "No data shared with third parties" on the listing.

## Why "No" is correct

Play defines *collection* as data transmitted off the device to the developer or a third party, and *sharing* as transfer to a third party. DataCast:

- Has no backend, account, analytics, crash reporting, ads or third-party SDKs that send data. Its dependencies (shelf, bonsoir, mime, qr_flutter, shared_preferences) are all local.
- Serves files only over the user's local network, only after the user starts sharing, only to devices that enter the PIN shown on the phone. Play's guidance treats such user-initiated transfers, where the user expects the data to go to the destination they chose, as not "sharing".
- Stores settings (device name, PIN, port, chosen folder) on the phone only.

Recheck this form if you ever add crash reporting (for example Firebase Crashlytics), analytics, ads, or any cloud feature: those make the answer Yes.

## Related

- Account deletion: not applicable (no accounts).
- Encryption in transit: not asked when no data is collected. For honesty in the privacy policy we say the local connection is plain HTTP on the local network, protected by the PIN.
