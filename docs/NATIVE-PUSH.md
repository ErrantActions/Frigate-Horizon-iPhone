# Native Apple push setup

Native notifications use Apple's Push Notification service (APNs), not Safari
web push. The app talks directly to your Horizon server; that server sends
alerts to Apple. This feature is **off by default** on both sides.

## Current status

The existing APNs backend is deployed with production provider credentials,
`server_id=home-nvr`, and topic `com.errantactions.frigatehorizon`. Its main App
Store profile has production push rights. No devices were automatically
subscribed, and existing global/camera notification rules remain disabled.
The backend deployment receipt records 75 application/API/auth/browser/native
tests on Linux Python 3.11 and 29 APNs core tests on Linux Python 3.13.18; this
is not full application qualification on Python 3.13.

The next TestFlight build **must support opt-in images**. Local source now adds
a Notification Service Extension (NSE), authenticated image downloading,
dedicated shared-Keychain state, and dual-profile signing guards. Thirty-four
offline Python guard tests passed; the new Swift code/tests, extension signing,
and real-phone image delivery have not been verified by a native build.

The approved extension App ID and App Store profile are now created, using the
existing distribution certificate. Both live profiles passed the dual-profile
validator, and only `NOTIFICATION_SERVICE_PROFILE_BASE64` was added to GitHub.
The main profile, certificate, upload credentials, and server provider key were
not replaced. A secure local extension-profile copy was verified against Apple.
Actual archive signing remains unverified until the native build runs.

The owner now approves uploading the image-capable app before the backend image
service is ready. This run uses `allow_pending_image_backend=true`, not a false
backend-ready assertion. The signed NSE and production push profiles remain
mandatory. Images stay off/unavailable until the server advertises support and
the user explicitly opts in; reopen the app after the backend update to refresh
server capabilities. One TestFlight build/upload is approved; it does not
authorize backend deployment, a retry, a public App Store release, or a real push.

## 1. Prepare and validate the backend

The companion implementation lives in the Horizon server repository. The
deployed APNs service is currently text-only according to its release handoff;
do not confuse provider health with image readiness. Review and publish image
changes separately with owner approval, preserving unrelated server work.

Before deploying on a supported Linux/Python environment:

1. Run the APNs and existing browser-notification/API/config regression suites.
2. Verify migration `045_add_native_push_devices.py` against a database copy.
   It adds the separate user `native_push_devices` JSON field and leaves
   browser notification subscriptions alone. Back up the real database before
   any approved migration/deployment.
3. Generate API documentation using `generate_api_auth_spec.py`, then run its
   `--check` mode. Regenerate configuration translations using
   `generate_config_translations.py`. Review generated differences; never
   hand-edit generated files to bypass the check.
4. Verify the default-disabled configuration preserves browser push behavior.

The native endpoints, relative to the existing API base, are:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/notifications/apns` | Nonsecret provider metadata |
| GET | `/notifications/apns/devices` | Your installation metadata, without device tokens |
| POST | `/notifications/apns/register` | Register/renew this installation and camera choices |
| DELETE | `/notifications/apns/register/{installation_id}` | Remove your installation |
| POST | `/notifications/apns/test` | Send a test only to your registered installation |
| GET | `/notifications/apns/thumbnail/{installation_id}/{kind}/{identifier}?height=360` | Required protected image service; verify deployment before enabling images |

Native authentication and an actual user account are required. Registration
cannot choose another username, topic, provider URL, or credentials.

### Required image-service contract

- Capabilities advertise `image_notifications: true` only when image support
  is actually available. Eligible alerts include `aps["mutable-content"]=1`.
- Preserve `aps`, `server_id`, `kind`, and `identifier` (optional only for test).
  Never add image bytes, server/media/destination URLs, credentials, cookies,
  or private keys to APNs.
- The protected image endpoint accepts event/review/camera references, not
  arbitrary paths or URLs. It returns image bytes, a matching JPEG/PNG/WebP
  `Content-Type`, resolved camera ID in `X-Frigate-Camera`, and
  `Cache-Control: private, no-store`. No redirects or public thumbnails.
- Before returning media, verify current database-backed account/role/session
  validity, registered installation ownership, resolved camera permission, and
  the installation's current camera selection. A stale JWT role or a fresh
  `/profile` response alone is insufficient.
- Deny revoked/deleted/unregistered/cross-account installations. An empty
  camera selection permits no camera images. Camera references represent the
  latest preview, not necessarily the incident timestamp.
- A no-reference test remains text-only. Preserve existing browser push and
  disabled notification rules; app camera selection is an additional filter,
  not an override.

The client fails closed if this service/capability is unavailable. It never
falls back to legacy media URLs. Set `APNS_IMAGES_BACKEND_READY=true` only
after separately approved, verified deployment.

## 2. Preserve the separate APNs provider key

The current NVR already has a production-only, Horizon-topic-specific provider
key. Do not recreate, replace, revoke, or copy it to GitHub/the app. The following
setup guidance applies only to a separately approved new-server setup.

In the correct Apple Developer team, create a key with APNs permission suitable
for this app and its required environments. Record its key ID and the team ID.
Download the `.p8` once and store it outside source control.

**This is not the App Store Connect upload key.** Keep it out of GitHub source,
the app bundle, chat, logs, and build artifacts. Do not revoke unrelated keys.
Mount it read-only into the NVR and restrict access to the service account.

## 3. Enable the server deliberately

Example server configuration, after credentials and the key mount are ready:

```yaml
notifications:
  enabled: true
apns:
  enabled: true
  server_id: home-nvr
  topic: com.errantactions.frigatehorizon
  team_id: "{FRIGATE_APNS_TEAM_ID}"
  key_id: "{FRIGATE_APNS_KEY_ID}"
  private_key_file: "/config/secrets/apns/AuthKey_EXAMPLE.p8"
  include_details: false
```

Set the `FRIGATE_` environment values to the public Apple identifiers, not the
private key contents. Enable native server authentication; enable only owner-approved
camera notification rules. `server_id` must be stable and unique per NVR.
Do not reuse it for unrelated servers.

Restart Horizon after an approved provider/credential configuration change.
The notification worker creates its APNs transport at startup. Saving raw
configuration without restarting is not proof the running worker changed.
Allow outbound trusted TLS/HTTP2 to Apple's production and sandbox APNs hosts.

Generic lock-screen text is the default. Camera/event routing identifiers still
go to Apple. `include_details: true` additionally exposes titles/descriptions
to Apple and lock-screen viewers; enable it only intentionally. Media, server
URLs, session cookies, passwords, and provider keys are not in the push payload.
Device tokens are server-side personal data; protect database backups.

## 4. Prepare the Apple App ID and signing profile

1. Reuse the main App ID `com.errantactions.frigatehorizon`, team `QM3794NUZS`,
   its enabled Push Notifications capability, and refreshed App Store profile.
   The existing `PROVISIONING_PROFILE_BASE64` was already replaced. Do not
   overwrite it with an older local profile lacking production push rights.
2. Obtain approval before creating the extension App ID
   `com.errantactions.frigatehorizon.NotificationService` and App Store profile.
   Reuse the same distribution certificate; no new APNs key is needed.
3. Both profiles must allow the dedicated Keychain group
   `$(AppIdentifierPrefix)com.errantactions.frigatehorizon.notificationImages`.
   The app retains its original default group first; the NSE gets only the
   dedicated group. No filesystem App Group is required.
4. Upload the extension profile securely as the separate `app-store` secret
   `NOTIFICATION_SERVICE_PROFILE_BASE64`. Do not re-upload or replace the
   existing certificate/upload credentials. Never paste secret values in chat.
5. After approval, set `ENABLE_NATIVE_PUSH=true` and, only after backend image
   verification, `APNS_IMAGES_BACKEND_READY=true`. The early guard requires both
   profiles, production APS on the app, matching team/bundle/prefix, compatible
   Keychain groups, dates, App Store type, and the same distribution certificate.
6. If the owner explicitly approves uploading the image-capable app ahead of
   backend deployment, dispatch with `allow_pending_image_backend=true` while
   leaving `APNS_IMAGES_BACKEND_READY` false/unset. This prints a warning and
   does not bypass either profile or runtime image authorization. The default
   remains to require verified backend image support.
7. Confirm the archive embeds `HorizonNotificationService.appex`, signed under
   its own profile, with matching version/build numbers. Export options map the
   app and extension IDs separately; a global main-profile override is invalid.

Disabled builds use no APS entitlement. Enabled Debug builds request
`development` (Apple sandbox); Release builds request `production`.
TestFlight uses production APNs. Simulator results are not real delivery proof.
The current server provider key is production-only. No silent-push/background-fetch
mode was added. The NSE itself does not request the APS entitlement.

For local unsigned compilation, export `ENABLE_NATIVE_PUSH=true` before running
the existing local iOS check. A successful unsigned build does not verify signing
rights, APNs registration, or delivery.

Ask the owner before **every native build or retry**, including free public
runner jobs. Also ask before Apple capability/resource changes, build-variable
changes, backend deployment, and real pushes. Prefer the local Mac
preflight and one approved TestFlight run rather than duplicate cloud jobs.
Deployment does not run simulator/UI tests; the owner tests the phone UI.

## 5. Enable and accept on a real phone

1. Install the approved push-enabled build and sign into the intended NVR.
2. Open **Settings > Native notifications**. Check build support, server
   provider, and iOS permission. Permission is requested by an explicit enable
   action, not silently on startup.
3. Choose all currently allowed cameras or an explicit selection. An empty
   selection means no camera alerts; a manual test can still reach the device.
4. Enable and wait for successful server registration. Verify token-free device
   metadata. Ask the owner before sending any real push, including a test.
   Apple acceptance means APNs accepted the request, not guaranteed display.
5. Test foreground/background/terminated delivery, Focus and notification
   settings, cellular/Wi-Fi, and taps into review/event/camera destinations.
6. Confirm current camera rules, suspension, cooldowns, role changes, and
   selected-camera filtering. Delivery rechecks database permissions rather
   than trusting a role cached when an alert was queued.
7. Test disable/re-enable, logout, token renewal, account/server changes, and a
   failed unregister. Ensure a fresh Apple registration follows re-enabling.
8. Open a config/password/bookmark/export editor and confirm notification
   navigation is deferred until the editor closes.
9. Separately opt into Lock Screen image previews for this account/device.
   Coordinate an authorized event/review/camera reference with the backend
   owner; a no-reference test will not exercise the image path. Confirm visible
   receipt separately from APNs acceptance.
10. Verify image opt-out, account/server changes, role/camera revocation,
    unregister/logout, offline/auth failure, and extension deadline fallback.

Destinations accept known route kinds and identifiers, never arbitrary URLs.
They must match the current server and load data using current authenticated
APIs and camera access. Stale or deleted media must show an explicit error.

## Image privacy and fallback

Images default off and require an explicit Lock Screen privacy warning. Only an
opted-in account's scoped session snapshot is saved in the dedicated device-only
Keychain group, accessible after first unlock. Logout/account changes revoke it
before forgetting/activating a session, including the explicit server-cleanup
bypass. Revocation failure is surfaced rather than claiming successful logout.
Delivered notifications are cleared on image opt-out/account changes, but
already accepted/copied notifications cannot be guaranteed recalled.

The NSE uses authenticated HTTPS to the saved NVR, rejects every redirect,
rechecks session generation, and falls back to original text on failure or its
15-second budget. Downloads are bounded to 2 MiB and 2,000,000 source pixels,
then downsampled to at most 1024 pixels per dimension and re-encoded as JPEG.
Successful attachment files remain available for Apple's handoff; failed files
are removed, and old extension-owned cache directories are cleaned later.

## Cleanup and troubleshooting

Normal logout stops local notifications and unregisters on the server before
forgetting the session. If cleanup fails, logout is blocked with an error.
The explicit **Disconnect without server push cleanup** action allows leaving
anyway, but retains cleanup debt. Sign back into the original account/server
to finish it before enabling push for a different account/server. Apple may
already have accepted notifications; unregistering cannot recall those.

- **Build support not enabled:** use an intentionally enabled, correctly signed build.
- **Provider unavailable / 404:** deploy the validated companion backend first.
- **Topic mismatch:** server topic, app bundle ID, App ID, and profile must agree.
- **Apple registration timeout/failure:** inspect entitlement, connectivity, and
  permission. No device token is displayed or saved in app preferences.
- **Apple rejection:** check production versus sandbox, token/topic, key scope,
  team/key IDs, server clock, and mounted P-256 key. Do not log secrets or tokens.
- **Accepted, no banner:** inspect phone notification settings/Focus/connectivity.
  APNs is best-effort; do not report acceptance as confirmed delivery.
- **No camera alerts:** verify notification rules, suspension/cooldown, selected
  cameras, permissions, and the restarted provider worker.

APNs 410 cleanup is guarded by token/environment/installation and invalidation
time so delayed rejection cannot delete a newer registration. Browser
subscriptions remain independent of native registrations.
