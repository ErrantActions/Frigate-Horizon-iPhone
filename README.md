# Frigate Horizon for iPhone

A native SwiftUI client for an existing Frigate Horizon server. No WebView,
embedded web app, camera passwords, analytics, or Horizon cloud relay.

This is the fresh public repository:
[ErrantActions/frigate-horizon-iphone](https://github.com/ErrantActions/frigate-horizon-iphone).
It starts with one source-only commit using a GitHub noreply identity, not a
fork or import of previous history. The previous repository remains private.
Old Git objects, build logs, signing files and local editor settings were not copied.

## First native version

TestFlight build 1020 includes native live PiP, quick evidence,
supported PTZ/two-way talk, synchronized incident replay, actionable alerts,
recording-health alerts and saved camera workspaces. All native sources compile,
sign and upload, with 219 core tests passing. New server-dependent features stay
unavailable until the matching backend update is deployed and verified. That
rollout is currently blocked by approved relay connectivity; production remains
on the image-ready backend. No backend readiness or hardware success is inferred
from the app build.

- A unified Horizon interface with adaptive light/dark surfaces, branded headers,
  custom action docks, camera cards, status pills, and consistent library/admin
  screens. Duo workspaces add cinematic video framing and a touch-transparent
  reflected-video sheen across the entire lower plane, including its background
  and controls, with accessibility safeguards.
- Live camera grid using authenticated HTTPS WebSockets and Apple's native
  compressed-video/audio renderers, with optional WebRTC and Metal rendering, muted tiles,
  per-camera stream selection, audio, reconnect, and actual received resolution.
  Camera names overlay the video; tiles have no separate footer or enabled badge.
  Camera view options add compact, comfortable and one-column layouts plus a
  favorites-only filter. Touch and hold a video to favorite it; favorites appear
  first in configured order. Preferences are local to this device/account and
  never widen camera access. Camera Tour follows the displayed camera selection.
  Accessibility text sizes use one column for readable overlays.
  Named camera groups save their own order/layout; existing account favorites
  migrate without being overwritten. A group never widens server permissions.
- Explicit live Picture in Picture reuses decoded HTTPS/WebRTC video, owns only
  one session, restores the selected stream/mute state, and stops on account or
  camera-access changes. Background grids remain stopped.
- Quick evidence saves the last 30 seconds, two minutes or a selected recorded
  range using actual coverage, with persistent export progress and private
  download/share. Permanent protection requires confirmed backend success.
- Supported cameras expose leased PTZ/presets/zoom and explicit push-to-talk.
  Release/cancel/background/access changes stop controls; microphone holds have
  a 30-second limit and a separately revocable server media lease.
- Incident mode synchronizes two to four original recording angles on one
  host clock, with readiness barriers, drift correction, known gaps, one audible
  camera and a deliberate Duo tabletop layout/reflection.
- HTTPS readiness reconciles the displayed frame as well as renderer notifications,
  so playing video clears the waiting indicator even when a notification is missed.
  Reconnects reset that state and ignore callbacks from the previous stream.
- A manually launched immersive Camera Tour for tent/stand use cycles through
  enabled, permitted dashboard cameras with preset or custom 1-3600-second
  intervals after video becomes ready, or follows actual camera motion.
  The next stream is preloaded before a decoded-ready handoff, with at most two
  muted streams during warm-up. Controls auto-hide with accessibility safeguards.
  It pauses the background grid, offers pause/previous/next controls, and shows
  camera failures before advancing.
  Streams and timers stop in the background; auto-lock is restored on exit.
  This is an opt-in tour, not inferred tent-angle detection.
- Configured, main-derived 720p grid and 1080p detail renditions when available.
  No invented stream names, automatic substream substitution, or server changes.
- Review filters by day, camera, and server-provided alert/detection category;
  thumbnails, completed-event playback, and per-user reviewed state.
- Review opens a native horizontal scrub timeline with a fixed center
  playhead: drag the ruler beneath it, and playback moves the ruler rather than
  the marker. Explicit scale controls select 1/5/15/30 seconds or 1/5 minutes per
  tick without changing the selected instant. Zoom-out and zoom-in controls sit
  over its bottom-left and bottom-right corners; the compact transport row and
  wrapping camera-preview grid leave more room below the fold without a sideways
  carousel. Time labels, alert/detection bands,
  motion, and explicit recording gaps stay aligned to the same ruler.
  Camera previews use recorded snapshots at the selected time, never live frames.
  The tabletop workspace places video above the timeline and other cameras.
  The ruler keeps a fixed time range while open, and seeks/camera switches retain
  the current play/pause intent. Unknown recording coverage is not shown as a gap.
- Recording browser that separates actual recording gaps, with native HLS
  playback, scrubbing, AirPlay, and Picture in Picture.
- Native event search with camera/label/zone/date/media filters, offset pagination,
  server-enabled semantic/similarity search, event details, and snapshot/clip sharing.
- Administrator event editing for display sub-labels and descriptions, with
  field-specific pre-save conflict checks, explicit clearing, and confirmation
  of accepted updates. These endpoints do not provide atomic revision locking;
  queued label updates are not presented as saved before the server confirms them.
- Export creation with stream/timestamp/metadata selection, job progress, playback,
  download/share, and administrator-only rename/delete.
- Protected-evidence browsing with per-tier storage totals, explicit unknown sizes
  and archive availability, original playback/download, and confirmed unprotection.
- Shared recording bookmarks with point/range notes, creator/admin edit permissions,
  revision-aware edits/deletion, and direct opening in the native scrub workspace.
  Bookmarks are annotations, not permanent footage protection.
- Role-gated administration: system/storage/FPS monitoring, service logs with live
  follow and text filtering, user creation/roles/passwords/deletion, and a native
  raw configuration editor with server validation, external-change checks, and
  separately confirmed save/restart.
- Keychain session persistence, allowed-camera filtering, light/dark appearance,
  password changes, server health, and direct connection settings.
- Optional native Apple push settings, camera preferences, authenticated
  notification destinations, and server unregistration on logout. Disabled in
  default builds; requires the companion backend changes and Apple setup below.
  New supported-server actions provide Live, Review and per-installation camera
  snooze; quiet hours use explicit time zones and starting weekdays. Health
  delivery is separately opt-in and does not turn on camera activity rules.
  The health center never presents missing/stale required telemetry as healthy.

Full Safari parity remains in progress. Native push and the opt-in image extension
are enabled in TestFlight builds 1017/1018; the image backend is now verified
ready, while phone acceptance remains separate. Native controls are capability-gated;
advanced search/export cases and batching,
face/classification management, chat, setup/discovery,
advanced system reports, and several Horizon tools are still pending. The
new control, health, device-preference and export-protection features require the
matching secure backend contract; existing image service support is separate.

The native app, including compact horizontal review, whole-plane reflections,
event metadata editing and Camera Tour, passed Xcode 27.1 Release compilation,
219 core tests and 30 CI build/signing guard tests.
Archive, signing, export and upload succeeded for
[TestFlight build 1020](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40945180763).
Apple reports valid processing, cleared export compliance, and internal beta
testing; the build is included in Owner Testing Auto. Dashboard preferences,
tour selection and notification-support refresh passed native compilation and
the additional core contracts, including the complete feature suite.
Physical UI/phone-delivery and camera-control acceptance remain separate.
No simulator/UI tests or screenshots ran during this deployment, as requested;
the owner performs visual acceptance on the phone. Apple processing and export
compliance remain separate release gates. Real-server playback, physical Duo
appearance and push-enabled delivery still require device acceptance. Paid builds
remain manual and require fresh owner approval. Do not equate compiled UI with
complete Safari parity or physical-device acceptance.

## iPhone Duo and folding

On iOS 27.1+, built with the iOS 27.1+ SDK:

- Native tab/sidebar and split-view navigation resize for inner and outer displays.
- The expanded camera and expanded recording player use SwiftUI
  `ArrangementView` to keep video and controls clear of the active fold.
- Active `.division` reserved regions distinguish **tabletop** (horizontal fold)
  and **book** (vertical fold) layouts. Selection and media ownership remain
  outside the layout, so folding does not intentionally start a new stream.
- Only in tabletop mode, a faint, blurred, vertically mirrored reflection of the
  upper video overlays the entire lower plane: background, controls, timeline,
  and camera previews (HTTPS, WebRTC, review, and expanded recordings).
  It reuses decoded frames in memory, never another stream/player or saved snapshot;
  rendering runs off-main at at most 6 fps, with images no larger than 320 pixels
  per side. Camera/item changes and disappearance clear it. Reduce Motion,
  Reduce Transparency, and inactive scenes disable it and detach frame observers.
- System controls handle safe areas, camera occlusions, and vertical toolbar
  presentation. Layout uses the containing scene, never fixed device dimensions.

This is **system-detected fold posture**, not a reported hinge angle in degrees.
The verified public APIs expose active reserved-region geometry, not a numeric
hinge-angle sensor. We do not invent angle thresholds, infer folding from motion,
or use private APIs. Additional angle-specific behavior requires a documented
public API and physical-device verification.

On iOS 18+ or builds using an older SDK, regular adaptive layouts work, but
fold-region detection is unavailable. `DUO_SDK` is enabled by the preparation
script only for an iOS 27.1+ SDK; the Duo CI job fails rather than silently
shipping the compatibility fallback.

References:
[Apple Duo preparation guide](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
[ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview),
[reservedRegions](https://developer.apple.com/documentation/swiftui/geometryproxy/reservedregions(kind:options:layoutdirectionbehavior:)).

## Connect

Use your server's root URL, such as `https://frigate.example.com:8971` or
`https://example.com/frigate`, not a URL ending in `/api`. Sign in with an
existing Frigate username/password. Disable credential sign-in only when your
server intentionally allows unauthenticated access.

- Use HTTPS with a certificate trusted by iOS. Self-signed certificates are
  **not** bypassed. For local cleartext testing, local networking is allowed
  without disabling transport security globally; HTTPS is recommended.
- Passwords are discarded after login. Session cookies are stored only in this
  device's Keychain and memory, not in preferences, logs, or this repository.
- API redirects must remain on the configured origin. Native HLS uses the
  server's `/vod/.../master.m3u8`, with session cookies passed to AVFoundation.
- LAN permission is required for local servers. For remote live video, configure
  reachable go2rtc ICE candidates/TURN or use a VPN. Only explicitly configured
  ICE servers are used; the app adds no third-party STUN service.
- HTTPS live uses the same authenticated `/live/mse/api/ws` endpoint as the web
  app and decodes H.264/H.265 plus AAC locally, without a WebView, relay, or server
  changes. It avoids WebRTC's separate ICE media route through reverse proxies.
  WebRTC remains selectable in the camera view and requires reachable ICE/TURN.
  Both paths stop offscreen/background and report startup/stall errors explicitly.
- Open events remain ongoing. The scrub workspace plays only footage the server
  reports as recorded, without inventing event end times, confidence, or coverage.
- Camera and microphone purpose strings cover the bundled WebRTC library.
  This receive-only version does not capture from your iPhone camera or microphone.

This client was developed against the API contracts in the local Horizon fork.
Real-server playback and Duo device acceptance still need to be performed.

## Optional native push

Follow [Native Apple push setup](docs/NATIVE-PUSH.md). The existing backend and
main production push profile are deployed; the separate, production-only APNs
provider key stays on the server and is not the App Store Connect upload key.
Device registration does not enable disabled global/camera notification rules.

The next TestFlight release requires explicitly opted-in image previews.
Local source adds a Notification Service Extension, dedicated shared-Keychain
session, protected authenticated image retrieval, text fallback, and dual-profile
signing guards. Release app/NSE compilation and signing passed in build 1018;
phone/APNs/image delivery remains unverified.
Extension signing profiles are prepared and validated. An explicit per-run
`allow_pending_image_backend=true` approval permits uploading the image-capable
app ahead of backend readiness; previews remain unavailable until the server
advertises support and the user opts in. Do not
dispatch a text-only release or silently enable rules, change Apple resources,
or send a real push.

The deployed image service is now verified compatible with build 1018, and
`APNS_IMAGES_BACKEND_READY=true` is recorded for future builds. No rebuild is
needed: refresh notification support, register this installation and explicitly
opt into Lock Screen images. Server alert rules remain off until deliberately
enabled; a no-reference test remains text-only.

Notification settings refresh server support when opened/foregrounded and offer
an explicit refresh action and pull-to-refresh. Backend image enablement no longer
requires restarting the app. Image opt-out remains available during support checks.

Both app and extension plists carry the existing exempt-encryption classification
from Apple-cleared build 1017 to avoid repeated compliance prompts. Reassess that
declaration if encryption or bundled libraries change; no France-specific plist
switch or distribution-country change is made.

## GitHub builds

### Publication security

- Actions are pinned to immutable commit hashes, use read-only repository
  permissions, and do not persist checkout credentials.
- Apple signing secrets are scoped to the `app-store` environment. That
  environment requires explicit owner approval and permits only `main`.
  A TestFlight run therefore pauses for deployment approval before using secrets.
- The signing helper preserves an existing environment's protection rules.
  Signing files use restrictive permissions and are excluded from Git.
- Keep personal certificates, local editor configuration, logs, database files,
  generated Xcode output, and history backups out of public commits. Public
  bundle IDs and Apple team/key identifiers are not private signing keys.
- Secret scanning and push protection supplement local review; they do not
  guarantee that every credential format or private detail is detected.

This clean repository was created **public on October 28, 2026**. Standard GitHub-hosted
runner compute is free for public repositories, including our `xcode-27` and
`macos-26` labels. Larger runners remain billable; do not substitute `-large`
or `-xlarge` labels without approval. Storage charges and Apple Developer fees
are separate, and previous private-repository charges are not reversed.
See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [standard public runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories).

macOS builds are **manual only**, with owner approval required before every run.
Pushing code, opening a pull request, or updating documentation does not start
a macOS build. Run **Actions > iOS** and check **Approve this manual macOS
validation run**. By default, the workflow uses one Duo runner and:

1. Runs the Swift package's URL, media, stream-selection, coverage, and fold tests.
2. Uses XcodeGen to create the Xcode project.
3. Builds the real native app and runs its iOS tests on a simulator.
4. Reports elapsed runtime in the job summary. Simulator `.app` and `.xcresult`
   artifacts are optional, retained for one day, and are not installable IPAs.

### Build spending policy

- Ask the owner before **each** paid run or rerun, including automated agents.
  Approval for an earlier run is not approval for another attempt.
- TestFlight deploys compile the Release app, check core contracts and signing
  prerequisites, sign, and upload. They do **not** run simulator/UI tests or
  capture screenshots. The owner performs UI acceptance on the phone.
- Simulator/native UI tests and optional synthetic previews remain in the
  separate manual **iOS** workflow; run them only when specifically requested.
- Validation defaults to one Duo job. Enable **Also validate older iOS** only
  when the owner approves a second job for a compatibility question.
- Batch changes and run available local syntax/manifest checks before requesting
  a cloud run. Do not repeatedly spend macOS minutes on unexamined failures.
- Validation jobs time out after 15 minutes; the signed TestFlight job after
  20 minutes. These limits reduce runaway time, not total account spend.
- Runtime summaries are estimates, not actual billed minutes or dollar totals.
  Check [GitHub Billing](https://github.com/settings/billing) for actual charges
  and configure a supported Actions budget/spending limit there. Agents must
  never increase a spending limit or change payment settings without approval.

No monthly dollar budget has been set in this repository. No paid build is
triggered just by saving or pushing these controls.

JavaScript actions use Node.js 24-compatible releases. Dependabot checks for
GitHub Actions updates weekly and opens reviewable pull requests. Updating the
runner's installed Node.js alone does not update an action's embedded runtime.

The compatibility job runs on `macos-26`. The Duo job runs on GitHub's
[`xcode-27` preview image](https://github.com/actions/runner-images/issues/14404)
and requires Xcode/iOS SDK 27.1+ plus an installed Duo simulator. If the hosted
image does not yet include them, the job reports that explicitly. A newer runner
or an appropriately provisioned self-hosted Mac is needed; do not remove the
SDK gate and mistake a compatibility build for verified Duo support.

## TestFlight / App Store

For a reusable, agent-ready walkthrough and this setup's latest recorded
checkpoint, see the [TestFlight publishing runbook](docs/TESTFLIGHT-RUNBOOK.md).

An Apple Developer Program membership, App Store Connect app record, registered
bundle ID, distribution certificate/private key, and App Store provisioning
profile are required. No Apple signing credentials belong in chat or git.

Create a GitHub environment named **app-store**, ideally with required reviewers.
Configure its variables:

| Variable | Value |
| --- | --- |
| `APP_BUNDLE_ID` | Your registered bundle identifier |
| `APPLE_TEAM_ID` | Your Apple Developer team identifier |
| `ENABLE_NATIVE_PUSH` | `false` until approved push/image signing setup; required `true` for the next release |
| `APNS_IMAGES_BACKEND_READY` | `false` until approved, verified protected backend image support; required `true` for the next release |
| `BUILD_NUMBER_OFFSET` | Optional; defaults to `1000`, added to the TestFlight workflow run number |

This app's selected bundle identifier is `com.errantactions.frigatehorizon`.
The existing Apple app identity does not change with the GitHub repository.
New repository run numbers restart at one, so TestFlight numbers start at 1001
by default. Check App Store Connect before signing and raise the offset if needed.
Start a new workflow dispatch for a new upload; rerunning the same workflow
reuses its build number.

The protected `app-store` environment is recreated, but signing secrets are
**not copied** from the old repository. GitHub does not return their plaintext.
Unsigned iOS validation needs no Apple secrets. To enable TestFlight, upload the
six secrets below securely using the existing helper and local signing material.
Do not recreate Apple credentials unnecessarily or put their contents in chat.

### Starting from Windows

The local PowerShell helper uses Git for Windows' OpenSSL. Run it in an
interactive terminal, never paste signing passwords into chat:

```powershell
.\tools\apple-signing.ps1 -Action CreateCSR
```

It saves an encrypted private key and public CSR under
`$env:LOCALAPPDATA\FrigateHorizon\Signing`, restricted to your Windows account
and SYSTEM. Upload only `distribution.csr` when creating an **Apple Distribution**
certificate in the Apple Developer portal. Download the resulting `.cer`, then:

```powershell
.\tools\apple-signing.ps1 -Action ExportCertificate -CertificatePath "C:\path\distribution.cer"
```

Create an **App Store Connect** distribution provisioning profile for the app
and certificate. In App Store Connect, create a team API key with an upload-capable
role, download its `.p8` once, and keep it outside this repository.
Authenticate the official GitHub CLI using `gh auth login --web`. Then run:

```powershell
.\tools\apple-signing.ps1 -Action UploadSecrets -TeamId YOURTEAMID `
  -ProfilePath "C:\path\Horizon.mobileprovision" -ApiKeyPath "C:\path\AuthKey_KEYID.p8"
```

The helper prompts locally for the P12 password, key ID, and issuer ID. It creates
the `app-store` environment, configures its two variables, and sends the six
secrets directly to GitHub over stdin without printing their contents or saving
a plaintext password file. Existing environment protections remain in place.
Review its protection rules before running the upload workflow.

Configure these environment secrets using GitHub's settings:

| Secret | Value |
| --- | --- |
| `DISTRIBUTION_CERTIFICATE_BASE64` | Base64-encoded distribution `.p12`, including private key |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `PROVISIONING_PROFILE_BASE64` | Base64-encoded App Store distribution profile for this app |
| `NOTIFICATION_SERVICE_PROFILE_BASE64` | Separate App Store profile for the Notification Service Extension, using the existing distribution certificate |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Contents of the API key `.p8`, with an upload-capable role |

After explicit owner approval for that native run, open **Actions > TestFlight >
Run workflow** on `main` and check the confirmation. The workflow checks the
two profiles' app/team/expiry/distribution type, production app APS, shared Keychain
access and common certificate before compiling, checks core contracts,
imports signing material into a temporary keychain, archives, exports, uploads,
and removes its temporary signing material on exit. It never uploads on a push.

App Store processing, beta review, privacy responses, export-compliance answers,
screenshots, accessibility/device testing, and final store submission remain
owner tasks. Inspect the bundled WebRTC SDK's current privacy manifest and
licensing as part of release acceptance. Build numbers use the TestFlight
workflow run number plus the configured offset; increase the offset if an existing
App Store record is ahead. Values above 9999 fail before compilation.

## Build on a Mac

Requirements: Xcode 16+ for compatibility, Xcode 27.1+ for folding, Node.js, and
Homebrew.

### Compile locally before a cloud run

Once a suitable macOS build machine is available:

```sh
brew bundle --file Brewfile
bash tools/check-ios.sh
```

The local check requires the Duo SDK/simulator by default and reuses the same
project generation and simulator-test scripts as GitHub. It runs:

1. Core Swift tests.
2. The real app's simulator build and native tests, including video decoding.
3. An **unsigned Release device archive**, to catch device/Release compilation
   errors as well as Debug/simulator errors.
4. Purpose-string checks against the archived app's actual Info.plist.

No signing certificate, Apple login, GitHub runner, or TestFlight upload is used.
The first build may download Swift package dependencies; later runs reuse local
build products. Each run writes unique results under `build/local-check.*`, so
you can repeat checks without deleting previous test results. A successful run
prints `LOCAL IOS VALIDATION PASSED` and saves the commit, working-tree state,
Xcode/SDK versions, and result paths in `validation.txt`.

Use the same Xcode/SDK as the intended release build. Set `XCODE_PATH` if needed.
`REQUIRE_DUO=false bash tools/check-ios.sh` explicitly checks compatibility only;
it does **not** validate the Duo-only code. This Xcode-based check requires macOS;
Windows/WSL cross-compilation is the separate experimental path above.
Older/incompatible macOS or Xcode installations must not be
treated as proof that the current Duo release builds.

The intended cycle is **edit -> local check -> fix locally -> local check ->
one approved GitHub TestFlight run**. Passing locally reduces failed CI attempts
but cannot guarantee signing, Apple processing, real-server connectivity, or
physical-device correctness. Recheck after code, dependency, or SDK changes.

### Open the project interactively

```sh
brew bundle --file Brewfile
export APP_BUNDLE_ID=com.yourcompany.horizon
export APPLE_TEAM_ID=YOURTEAMID
export BUILD_NUMBER=1
export REQUIRE_DUO=true
bash .github/scripts/prepare-ios.sh
swift test
open FrigateHorizon.xcodeproj
```

In Xcode, choose your team and device for local automatic signing. Project files
are generated and ignored. `project.yml` is the project source of truth; regenerate
after changing it. The committed 1024x1024 app icon uses the existing Horizon
sun, reflections, and birds logo with its original blue and dark background.
Its vector source is [HorizonIcon.svg](App/Branding/HorizonIcon.svg). Builds use
the committed PNG directly and never regenerate or replace the artwork.

## Acceptance before release

- Authenticate, restart, restore the session, expire it, and disconnect.
- Confirm limited-role users see and play only allowed cameras.
- Check all real cameras, selected stream, audio, stream failure, and reconnect.
- Open/close/partially fold/rotate Duo during live video and recording playback.
  Verify tabletop/book transitions, fold clearance, selection continuity,
  vertical toolbars, large text, VoiceOver, and multiwindow resizing.
- Play alert/detection clips and recording ranges, including gaps and missing
  media. Check seeking, AirPlay, PiP, and background/foreground transitions.
- Check server proxy base paths, trusted TLS, LAN permissions, VPN, and remote ICE.
- Verify no video connections remain when leaving Live or backgrounding the app.

No signing, production server deployment, or App Store acceptance is implied by
a successful simulator build.
