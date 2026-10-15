# Licensing

umbilical is GPL-3.0-or-later. A paid license applies to the builds Karim
ships. Building this source tree does not require a key, and the app says so
when the check is off.

## Terms

- Price: $9.99, paid once.
- Updates: lifetime.
- One key can be active on 3 Macs at a time. Polar enforces that limit. The
  app only explains it.

The grace period after the last successful check is 14 days. The constant is
`LicensePolicy.offlineGrace`.

## Unofficial builds

Debug builds skip the license check. The window says "Unofficial build.
License checks are off."

A Release build with no organization id does the same, and adds that this
build has no Polar organization id. That is the source-build path. There is
no separate flag to hide it.

A Release build whose organization id is not a UUID, and is not the
unsubstituted `$(POLAR_ORGANIZATION_ID)` placeholder, does not call Polar.
New downloads and resumes wait until the build configuration is fixed.

## What an unlicensed Mac can still do

When the key is missing, the saved check does not match this Mac, Polar has
refused the key, or the grace period has ended, the app stays open.

Still allowed:

- A download that is already running keeps going. The app does not pause it,
  cancel it, or stop the engine because the license lapsed. The list keeps
  refreshing.
- Pause, remove, and cancel.
- Settings, choosing the download folder, and entering a license key.
- Quitting. Quit still stops active downloads, licensed or not.

Not allowed:

- Starting a download from the add sheet, including a video download.
- Confirming a Safari handoff.
- Resuming a paused download.

During the grace period, and on an unofficial build, those actions stay
available.

## Activate and deactivate

Open Settings, License. Enter the key and choose Activate.

The request sends the key, the organization id, and a random label of the
form `umbilical-` plus 8 hex characters. It does not send a hardware id, a
hostname, or an IP address.

Activating the same key again validates the current activation. It does not
take a second Mac slot. Activating a different key deactivates this Mac
first. If Polar does not accept that deactivation, the new key is not sent.

Deactivate This Mac frees the slot. The key and activation id are removed
from this Mac. The random label stays, so the next activation on this Mac
uses the same label.

If Polar says the key is already active on 3 Macs, deactivate it on another
Mac, or in the Polar customer portal, then try again.

## What is stored

The Keychain service is `me.peapod.umbilical.license`. It has three items:

- `device-label`: the random Polar label.
- `credential`: the key, the Polar activation id, the device id, and a block
  reason when Polar has refused the key.
- `validation`: the key, the Polar activation id, the device id, and the
  times used for the grace period.

Each item uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and is not
synchronizable.

The device id is the SHA-256 of `IOPlatformUUID`. The raw platform UUID is
not stored and is not sent to Polar.

A validation record is accepted only when its device id matches this Mac and
its key and activation id match the saved credential. A record copied from
another Mac is unvalidated. A copied credential is deleted and is not sent
to Polar. A key mismatch drops the validation record, keeps the credential,
and does not call Polar. If the device id cannot be read, the saved items
stay where they are and are not treated as valid.

## Network

The app talks only to `https://api.polar.sh`, and only to these public
customer-portal routes:

- `POST /v1/customer-portal/license-keys/activate`
- `POST /v1/customer-portal/license-keys/validate`
- `POST /v1/customer-portal/license-keys/deactivate`

The JSON body carries `organization_id` and the license key. Activate also
sends `label`. Validate and deactivate also send `activation_id`. There is
no `Authorization` header. No organization access token is in the app, this
repo, or CI. Redirects are refused. The app does not send telemetry.

A check runs at launch, then about once a day. After a network failure the
next try waits 15 minutes. Only a granted key that has not expired counts as
a success. Revoked, disabled, expired, unknown, and refused keys clear the
grace period even if the Mac is offline afterward. A network failure keeps
the last successful check.

## Clock

The app remembers the last time it saw a valid check. If the Mac clock moves
earlier than that time by more than 5 minutes, or sits before the last
successful check, the grace period does not apply. A successful reply does
not move that mark backward.

If Polar's clock is ahead of the Mac, the app stores Polar's time and waits
until the Mac clock catches up.

This does not catch every rollback. If the app has not run since the last
check, setting the clock to a moment just after that check can still look
valid. The mark limits casual clock changes. It is not a secure clock.

## Build configuration

`Config/Licensing.xcconfig` optionally includes
`Config/Licensing.local.xcconfig`, which is gitignored. Copy
`Config/Licensing.local.xcconfig.example` and set `POLAR_ORGANIZATION_ID`
there. When that file is absent, the id is unset and a Release build is
unofficial. The id is the organization UUID from the Polar dashboard. It is
not an access token.

The app target writes that setting into `Info.plist` as
`PolarOrganizationID`. Do not commit the local file. Do not put an access
token in either file, in CI, or in the app.

The Mac release script writes `Config/Licensing.local.xcconfig` from
`POLAR_ORGANIZATION_ID` in the environment, or from that local file if the
environment value is empty, before it builds. The organization id is not a
GitHub secret. The script fails if the value is empty. Pull requests and
the unsigned dry run do not set it, so those builds stay unofficial.

## Polar dashboard

Someone still has to create the product before a Release build with the
organization id can activate a real key:

- Price $9.99, one time.
- A license-key benefit with an activation limit of 3.
- No expiry, so Polar leaves `expires_at` empty.
- Copy the organization id into `Config/Licensing.local.xcconfig` on the
  build machine.

The app does not create products and does not mint keys.
