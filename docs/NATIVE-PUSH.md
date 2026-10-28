# Native Apple push setup

Native notifications use Apple's Push Notification service (APNs), not Safari
web push. The app talks directly to your Horizon server; that server sends
alerts to Apple. This feature is **off by default** on both sides.

## Current status

Backend provider, device registry, migration, API endpoints, native settings,
camera preferences, routing, and logout cleanup are implemented locally.
There have been no production changes or real Apple pushes.

- Offline backend suite: 21 tests passed on Windows with Python 3.11.9 and
  the pinned Pydantic 2.13 series. Production Python 3.13+ remains unverified.
- Signing-profile validator: six local tests passed.
- Four mocked build-preparation tests passed, including disabled/enabled
  entitlements and rejection of invalid flags before running build tools.
- Seven native push model/routing tests were added, but need Swift/Xcode execution.
- Full Linux API integration, existing browser-push regressions, generated API
  and config translations, native compilation, and phone acceptance are pending.
  Windows application imports stop at the Unix-only `resource` module.

Do not deploy or mark notification parity complete based on these checks alone.

## 1. Prepare and validate the backend

The companion implementation currently lives in the local Horizon checkout,
not in the iPhone repository. Review and publish it separately with owner
approval. Preserve unrelated work in that checkout.

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

Native authentication and an actual user account are required. Registration
cannot choose another username, topic, provider URL, or credentials.

## 2. Create a separate APNs provider key

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
private key contents. Enable native server authentication and the desired
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

1. Enable **Push Notifications** on the existing explicit App ID matching
   `com.errantactions.frigatehorizon`.
2. Regenerate its **App Store Connect** distribution profile with the existing
   intended distribution certificate and download it.
3. Replace the GitHub `app-store` environment's `PROVISIONING_PROFILE_BASE64`
   securely, using the existing signing helper. Never paste its contents in chat.
4. Set `ENABLE_NATIVE_PUSH=true` in that environment only when ready.
   The workflow's early profile check requires production `aps-environment`,
   matching app/team, validity dates, and App Store distribution.

Default builds use no push entitlements. Enabled Debug builds request
`development` (Apple sandbox); Release builds request `production`.
TestFlight uses production APNs. Simulator results are not real delivery proof.
No silent-push/background-fetch mode was added.

For local unsigned compilation, export `ENABLE_NATIVE_PUSH=true` before running
the existing local iOS check. A successful unsigned build does not verify signing
rights, APNs registration, or delivery.

Ask the owner before **every paid build or retry**. Prefer the local Mac
preflight and one approved TestFlight run rather than duplicate cloud jobs.

## 5. Enable and accept on a real phone

1. Install the approved push-enabled build and sign into the intended NVR.
2. Open **Settings > Native notifications**. Check build support, server
   provider, and iOS permission. Permission is requested by an explicit enable
   action, not silently on startup.
3. Choose all currently allowed cameras or an explicit selection. An empty
   selection means no camera alerts; a manual test can still reach the device.
4. Enable and wait for successful server registration, then send a test.
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

Destinations accept known route kinds and identifiers, never arbitrary URLs.
They must match the current server and load data using current authenticated
APIs and camera access. Stale or deleted media must show an explicit error.

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
