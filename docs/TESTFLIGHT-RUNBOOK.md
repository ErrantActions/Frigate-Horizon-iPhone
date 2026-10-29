# TestFlight publishing runbook for agents

Reusable workflow: Windows workstation, native iOS project, GitHub-hosted macOS
builds, and manual distribution signing. No local Mac is required for this path.

**TestFlight is not a public App Store release.** TestFlight uses Apple
Distribution certificates and App Store Connect distribution provisioning
profiles. Those names do not mean the agent should submit or publish the app
publicly.

## Agent handoff prompt

Copy this prompt and provide this document to the next agent:

> Help me publish this native iOS app to TestFlight using GitHub Actions.
> Follow the attached runbook, inspect the repository's actual workflows and
> signing helper, and resume from the last verified checkpoint. Confirm the
> repository, app name, bundle ID, Apple team, and intended testers. Do not
> recreate existing app records, keys, certificates, or profiles without checking
> whether they can be reused. Keep passwords and private keys out of chat,
> source control, tool output, and artifacts. Let me handle sign-in, MFA, legal
> agreements, and local password prompts. Verify the signed upload, Apple
> processing, and tester installation separately. Do not submit a public App
> Store release. Ask me before each paid macOS workflow run or rerun; an earlier
> approval does not authorize another attempt.

## 1. Confirm prerequisites and authorization

Collect only nonsecret configuration:

| Item | Confirm |
| --- | --- |
| Apple membership | Active paid Apple Developer Program membership |
| App identity | Display name, explicit bundle ID, primary language, internal SKU |
| Apple team | Correct team selected in both Apple portals; record its team ID |
| GitHub destination | Repository the owner is authorized to use |
| Build access | Hosted macOS runners enabled, or an approved self-hosted Mac |
| Testers | Owner/internal testers first, or external beta testers |
| Approval | Permission to create signing resources and upload a beta |

Use the browser for Apple sign-in. The owner enters credentials and MFA directly.
The owner reviews and accepts Apple agreements or API-access terms personally.

If enterprise policy disables hosted runners, stop and request an approved build
route. Apple authentication does not fix a GitHub runner restriction. Do not
move code to another account or organization without explicit owner approval.

Before creating resources, inspect existing app records and signing metadata.
Never revoke unrelated certificates or keys to free capacity.

### Public-repository compute, approval, and metering

This fresh public repository was created on **October 28, 2026**, without
previous Git history, Actions logs or signing material.
[Standard GitHub-hosted runner compute is free for public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
GitHub lists both current labels, `xcode-27` and `macos-26`, as
[standard public runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories).
Larger runners remain billable even for public repositories. Storage and
Apple Developer fees are separate; historical private-run charges remain.
Recheck visibility and runner classification before relying on free compute.

Workflows remain manual with confirmation required. The iOS API input retains
its historical name `confirm_paid_run`, but its UI now says manual validation.
Do not treat public visibility as permission to start a build or upload.

On October 29, 2026, the owner requested **always push**: relevant app fixes
and TestFlight retries on standard public runners have standing approval.
Do not repeatedly ask for each such attempt. Keep the workflow manual and
its protected environment intact, verify each result, and avoid redundant runs.
Paid/private/larger-runner jobs and billing changes still require explicit
approval. No monthly dollar budget is configured here; do not dispatch a paid
workflow just to verify spending controls.

The owner also authorizes ongoing feature development and pushes for the native
app and main Frigate Horizon app. Coordinate server work with the active backend
task and its approved deployment/rollback procedure; verify the authorized fork
before pushing and preserve unrelated work. This is not permission to silently
enable camera alerts, discard recordings, broaden credentials, or publish a
public App Store release.

Horizon no longer runs macOS builds on push or pull request. The manual iOS
workflow requires `confirm_paid_run=true`, defaults to one Duo job, and adds
compatibility validation only with `include_compatibility=true`. Artifacts are
opt-in and retained for one day.

For a release candidate, use the TestFlight workflow. At the owner's request,
deployment does not run simulator/UI tests or capture previews. It retains core
contract tests, signing/build guards, and real Release device compilation before
export/upload. UI acceptance happens on the owner's phone.
The separate manual iOS workflow retains simulator/native UI tests and optional
synthetic previews; run it only when requested, not automatically before a deploy.

Validation jobs have 15-minute timeouts and TestFlight has a 20-minute timeout.
Each completed reporting step adds elapsed/rounded runtime to the GitHub job
summary; these figures are **not** authoritative billed minutes or dollar spend.
Checkout failure, forced cancellation, or timeout may prevent reporting.

The owner controls account billing and spending limits in
[GitHub Billing](https://github.com/settings/billing). Never change payment
settings or increase spending limits to unblock a build without explicit approval.

Before requesting a paid run, use `bash tools/check-ios.sh` on a suitable local
macOS/Xcode host. This reuses CI setup/tests and also compiles an unsigned Release
device archive. Verify its saved Xcode/SDK, commit/worktree, and purpose-string
checks. A compatibility-only run is not proof that Duo-specific code compiles.
No local Mac is configured merely by adding this command; Windows cannot perform
the full iOS check, and signing/Apple processing still need separate verification.

## 2. Verify the project and unsigned CI

Inspect the app's actual project definition, build scripts, and workflows.
For this repository:

- [Project definition](../project.yml)
- [Unsigned iOS workflow](../.github/workflows/ios.yml)
- [TestFlight workflow](../.github/workflows/testflight.yml)
- [SDK/project preparation](../.github/scripts/prepare-ios.sh)
- [Simulator tests](../.github/scripts/test-ios.sh)
- [Archive, export, and upload](../.github/scripts/testflight.sh)
- [Early profile guard](../.github/scripts/check-profile.sh)
- [Shared profile validation](../.github/scripts/validate-profile.py)

Verify:

1. The native app compiles and its relevant tests pass.
2. The runner has the required Xcode, SDK, and simulator. Device-specific
   features must not silently compile out in the claimed device build.
3. The app has an owner-approved icon. For the conventional asset catalog used
   here, use an opaque 1024x1024 PNG, without pre-rounded corners. Preserve
   existing branding rather than inventing a replacement.
4. The bundle ID, marketing version, and build number are wired into the
   generated project and signed archive. Later uploads need an accepted,
   increasing build number for the relevant version.
5. Distribution is manual; a normal push must not upload to Apple. Review
   environment protections separately rather than assuming they are enabled.

An unsigned simulator `.app` is not an installable iPhone IPA and does not prove
that distribution signing works.

### Native push and required opt-in images

Push is disabled by default. The owner requires opt-in images before the next
TestFlight build. See [Native Apple push setup](NATIVE-PUSH.md); do not dispatch
the old text-only configuration or equate source changes with backend readiness.

The main App ID already has Push Notifications and a refreshed production APS
profile. Preserve its existing `PROVISIONING_PROFILE_BASE64` secret. The existing
production-only server APNs provider key is not the upload key and must stay on
the server.

Obtain approval for the new
`com.errantactions.frigatehorizon.NotificationService` App ID/profile, reusing
the existing distribution certificate. The extension requires its own
`NOTIFICATION_SERVICE_PROFILE_BASE64` secret and the dedicated shared Keychain
group, not the main session group. Both targets must be signed and exported with
their own profiles. The NSE does not need APS or a separate APNs provider key.

Only after explicit approval and verified deployed image support, set
`ENABLE_NATIVE_PUSH=true` and `APNS_IMAGES_BACKEND_READY=true`. Backend support
requires the advertised image capability, mutable-content alerts, and the
protected installation-scoped image endpoint with fresh account/camera checks.
Alternatively, explicit owner approval for shipping the image-capable app ahead
of the backend permits the per-run input `allow_pending_image_backend=true`.
Keep backend readiness false/unset; this does not waive NSE/profile signing,
runtime capability checks, or explicit Lock Screen image opt-in. Reopen the app
after backend deployment to refresh its capabilities.

The early guard rejects wrong team/app, expired, development/ad hoc/enterprise,
and push/Keychain-incompatible profiles before compilation, including mismatched
app/extension certificate or prefix. Final signing reuses that
validator. These checks reduce wasted runner time. Standard public-runner
compute is free; any billable runner still requires fresh approval even if
preflight fails.

No new Apple resources, variables, backend deployment, or real Apple push is
authorized by source changes alone. The standing app-build approval above does
not cover backend deployment, real pushes, public/external releases, new Apple
resources, credential permissions, or legal declarations. Validate Xcode/device
behavior before calling the feature usable.

For a different app, replace repository-specific scheme, project, bundle ID,
team, SDK, signing-directory, and workflow values before reusing these commands.
The links below point to Horizon's implementation, not a universal template.

### Node.js warnings in Actions

Inspect the warning and the referenced action's `action.yml`, especially
`runs.using`. Updating the runner's installed Node.js or adding `setup-node`
does not change another action's embedded runtime.

In this setup, `actions/upload-artifact@v5` still targeted Node.js 20. Updating
to verified Node.js 24 releases, `checkout@v7.0.1` and
`upload-artifact@v7.0.2`, removed the Node.js 20 and `punycode` warnings.
For future apps, verify current supported releases and migration requirements;
do not assume every `@v5` action uses the same Node.js runtime.

Keep GitHub Actions dependency updates enabled, with review rather than blind
auto-merging. This repository uses [Dependabot](../.github/dependabot.yml).

## 3. Register the App ID and App Store Connect record

In [Apple Developer](https://developer.apple.com/account/resources/identifiers/list):

1. Add an identifier of type **App IDs**, then **App**.
2. Enter the approved description and **Explicit** bundle ID.
3. Enable only capabilities the app actually needs.
4. Review, register, and verify that the identifier appears in the list.

In [App Store Connect](https://appstoreconnect.apple.com/apps):

1. Choose **New App** and the **iOS** platform.
2. Enter the approved name and primary language.
3. Select the matching registered bundle ID.
4. Enter a unique internal SKU and the intended user-access setting.
5. Create the record and verify its name, bundle ID, and Apple app ID.

The icon placeholder can remain until Apple processes the first build.
Do not upload an unrelated image merely to replace that placeholder.

## 4. Generate the private key and CSR locally on Windows

Use a trusted OpenSSL installation, such as Git for Windows, and an interactive
terminal visible to the owner. This repository provides
[apple-signing.ps1](../tools/apple-signing.ps1).

For another app, review and reuse/adapt the helper explicitly. Supply a separate
signing directory and the correct repository/bundle ID rather than accepting
Horizon-specific defaults.

```powershell
$SigningDirectory = Join-Path $env:LOCALAPPDATA 'YourApp\Signing'

powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action CreateCSR -SigningDirectory $SigningDirectory
```

If Windows blocks local scripts, inspect `Get-ExecutionPolicy -List`. Ask the
owner before changing policy. Where permitted, run the reviewed helper with
`-ExecutionPolicy RemoteSigned` for that PowerShell process only. Do not change
machine/user-wide policy or override organization-enforced restrictions.

The owner enters the contact email and signing password locally, not in chat.
Store the password securely; the helper needs it again for certificate export.

The helper:

- Restricts the signing directory to the current Windows user and SYSTEM.
- Generates an encrypted RSA private key and public CSR.
- Refuses to overwrite existing keys.
- Keeps the files outside the repository.

Upload **only the public CSR** to Apple. The private key never goes to the Apple
certificate-request form. Base64 is encoding, not encryption.

## 5. Issue the Apple Distribution certificate

In [Certificates](https://developer.apple.com/account/resources/certificates/list):

1. Add a certificate and choose **Apple Distribution**.
2. Upload the generated `distribution.csr`.
3. Continue to issue the certificate.
4. Download the public `.cer` into the local signing directory.
5. Export the certificate with its matching private key into an encrypted P12:

```powershell
powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action ExportCertificate -SigningDirectory $SigningDirectory `
  -CertificatePath (Join-Path $SigningDirectory 'apple-distribution.cer')
```

The owner enters the original signing password in the terminal. The helper
checks that the certificate's public key matches the private key before export.

A `.cer` alone is not enough for CI signing: the P12 must include the matching
private key. Do not use a cloud-managed certificate for this manual-export path
unless its private key is actually available through a supported method.

Keep an owner-controlled encrypted backup. Do not print or open private-key,
P12, or password contents using agent tools.

## 6. Generate the App Store Connect provisioning profile

In [Profiles](https://developer.apple.com/account/resources/profiles/list):

1. Add a distribution profile of type **App Store Connect**, not Development or
   Ad Hoc.
2. Select the exact App ID registered in step 3.
3. Select the distribution certificate from step 5.
4. Give it a descriptive name, generate it, and verify app/team/expiration.
5. Download the `.mobileprovision` into the local signing directory.

No tester device UDIDs are required for TestFlight. Do not register devices as
an unnecessary workaround.

If browser automation cannot save a download, ask the owner to download it and
provide its local path. Do not replace missing files with guessed contents or
claim a download succeeded without checking.

## 7. Create the App Store Connect API key

In **App Store Connect > Users and Access > Integrations > App Store Connect API**:

1. If API access is not enabled, the Account Holder must request it and review
   the applicable terms.
2. For this workflow, choose **Team Keys** and generate a named CI key.
3. Select the least-privileged role that permits build uploads for the intended
   workflow. Consult Apple's current role permissions; do not default to Admin.
4. The owner downloads the `.p8` once, directly into secure local storage.
5. Record the **Key ID** and **Issuer ID** for configuration.

This uploader expects a **team API key with issuer ID**. An individual key is
not interchangeable with that configuration without changing the uploader.
Apple documents that team keys can apply across apps; explain that scope to the
owner before creating one.

Do not ask the owner to paste `.p8` contents into chat or inspect them with
browser/tool output. The local helper reads the file and uploads it directly.
Never revoke an existing key without owner approval and impact assessment.

## 8. Configure protected GitHub signing secrets

Install the official GitHub CLI from a trusted source. If installing a release
archive, verify its published checksum before executing it.
If the executable is not on `PATH`, use its full installed path in commands
instead of reinstalling or exposing authentication tokens.

Authorize the correct GitHub account in an interactive terminal:

```powershell
gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow
gh auth status --hostname github.com
```

Never run `gh auth token` into agent logs. Authentication does not imply the
account has permission to administer the target repository's environments.

Create/use an **app-store** GitHub environment. Review its branch restrictions,
reviewers, and existing protections; never remove protections to make a run pass.
Use approved repository/environment settings if a plan does not support a
particular protection.

| Environment variable | Purpose |
| --- | --- |
| `APP_BUNDLE_ID` | Registered explicit bundle identifier |
| `APPLE_TEAM_ID` | Matching Apple Developer team ID |
| `ENABLE_NATIVE_PUSH` | Must be `true` for the next image-enabled release, after approval |
| `APNS_IMAGES_BACKEND_READY` | Must be `true` only after approved, verified image-backend deployment |

| Environment secret | Purpose |
| --- | --- |
| `DISTRIBUTION_CERTIFICATE_BASE64` | Base64-encoded P12 with private key |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | P12 password |
| `PROVISIONING_PROFILE_BASE64` | Base64-encoded distribution profile |
| `NOTIFICATION_SERVICE_PROFILE_BASE64` | Separate NSE App Store profile, using the same distribution certificate |
| `APP_STORE_CONNECT_KEY_ID` | Team API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Original `.p8` text, including line breaks |

Use the helper to read secrets locally and send them over stdin, not command-line
arguments, clipboard output, plaintext password files, or chat:

```powershell
powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action UploadSecrets -SigningDirectory $SigningDirectory `
  -Repository 'OWNER/REPOSITORY' -BundleId 'com.example.yourapp' `
  -TeamId 'YOURTEAMID' `
  -ProfilePath (Join-Path $SigningDirectory 'YourApp.mobileprovision') `
  -ApiKeyPath (Join-Path $SigningDirectory 'AuthKey_KEYID.p8')
```

Enter passwords and identifiers only in the local prompts. Verify secret
**names**, not values:

```powershell
gh secret list --repo OWNER/REPOSITORY --env app-store
gh variable list --repo OWNER/REPOSITORY --env app-store
```

For the existing configured repository, add only the approved extension profile
secret. Do not run a full secret replacement with the stale local main profile:

```powershell
$profile = Get-Item -LiteralPath 'C:\secure\HorizonNotificationService.mobileprovision'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($profile.FullName)) |
  gh secret set NOTIFICATION_SERVICE_PROFILE_BASE64 `
    --repo ErrantActions/frigate-horizon-iphone --env app-store
```

## 9. Run and verify the signed upload

Under the standing public-runner app-build approval, open **Actions > TestFlight >
Run workflow** on the approved
branch with the upload checkbox checked. Equivalent CLI for this repository's
workflow interface:

```powershell
gh workflow run testflight.yml --repo OWNER/REPOSITORY --ref main -f confirm_upload=true
gh run list --repo OWNER/REPOSITORY --workflow testflight.yml --limit 5
gh run watch RUN_ID --repo OWNER/REPOSITORY --exit-status
```

Confirm the workflow actually:

1. Ran core/build/signing checks and compiled the Release app on the intended SDK.
2. Validated both profiles, expiry, IDs, team, production app APS, shared group,
   and common certificate; embedded and signed the NSE with its own profile.
3. Imported the certificate/private key into a temporary keychain.
4. Archived for a **physical iOS device** destination, not Simulator.
5. Exported an App Store Connect IPA and successfully uploaded it.
6. Cleaned up its temporary keychain, profile copy, certificate files, and API
   key file, including on failure.

Keep signing secrets scoped to the signing/upload step. Do not expose them to
pull-request jobs, package-install steps, or build artifacts.

A green simulator build is not a signed upload. A successful upload is not yet a
processed, installable TestFlight build. Report each milestone accurately.

### Missing privacy purpose strings after a successful upload

Apple can accept the binary transfer and then reject the build during processing.
Check the owner's processing/rejection email if the portal still shows
**No Builds**; do not assume it is simply a queue delay.

Horizon received **ITMS-90683** for missing `NSCameraUsageDescription`. Its
bundled WebRTC binary includes capture APIs even though the app only receives
remote camera video/audio. We added camera and microphone purpose strings to
the app's actual Info.plist and a native regression test that reads the built
application bundle, not just the source XML.

Purpose strings must accurately describe the app. Do not invent capture or
talkback features to satisfy validation. Declaring a purpose string does not
grant permission or start capture. For another app, assess the linked SDKs and
real behavior, provide appropriate user-facing explanations, then upload a new
build with an increased build number and verify processing again.

### Verified uploader and the Transporter failure

The initial signed run successfully archived and exported the IPA, then failed:

```text
iTMSTransporter is now part of Transporter.
Please install Transporter from the Mac App Store.
```

The hosted Xcode runner did not include that separate app. Installing Transporter
from an interactive Mac App Store session is not required for this workflow.
We switched to Apple's supported Xcode-provided uploader:

```sh
xcrun --find altool
xcrun altool --upload-app -f "$ipa" -t ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
```

The script makes the private `.p8` available as
`$HOME/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` during upload, restricts
its file permissions, and deletes that temporary copy on exit. Check uploader
availability before the expensive signing/archive work.

After this fix, the signed workflow reported:

```text
** ARCHIVE SUCCEEDED **
** EXPORT SUCCEEDED **
UPLOAD SUCCEEDED with no errors
```

Do not regenerate certificates or rotate API keys for a missing-uploader error.
Keep the failing and successful run links so the next agent can distinguish
signing success, delivery failure, and subsequent successful delivery.

## 10. Process the build and install through TestFlight

1. Open the app's **TestFlight** tab in App Store Connect.
2. Confirm the uploaded version/build appears, then wait for processing.
3. Resolve processing errors or missing compliance information. The owner must
   confirm export-compliance answers based on the app's actual encryption; do
   not blindly set an exemption flag to suppress questions.
4. Provide beta information and create an internal testing group.
5. Add the build and eligible App Store Connect users, including the owner.
6. Install Apple's TestFlight app on the iPhone, accept the invitation, and
   install the beta.
7. Verify launch, icon, login, core features, permissions, and device-specific
   behavior on the physical phone.

Apple processing is asynchronous. A successful delivery can precede the build
appearing in TestFlight by several minutes or longer. Record the upload time,
check the processing notification/status, and investigate reported errors. Do
not repeatedly upload the same build just because the portal still says
**No Builds**. There is no guaranteed processing deadline in this runbook.

For owner-only testing, create an internal group with manual build distribution,
add only the owner, and assign the processed build. The owner needs the
TestFlight app on their phone and must accept the invitation. Do not mark the
phone test complete until the owner confirms the app actually launches.

For external testers, complete the beta-review information and any required
TestFlight App Review. Do not invite outside testers or enable a public link
without approval. Do not grant App Store Connect access merely to avoid review.

TestFlight builds expire after 90 days. Later betas normally reuse the app record
and valid signing resources, increase the build number, and repeat steps 9-10.
Obtain a fresh paid-run approval for each attempt. Do not submit a public App
Store release unless separately requested.

## Troubleshooting and handoff rules

| Symptom | Correct next step |
| --- | --- |
| Hosted runners disabled | Request enterprise approval or an approved runner |
| GitHub API/browser shows 404 | Verify private-repository access and active account |
| GitHub MCP reports header mismatch | Use authenticated official CLI or browser; do not expose credentials |
| Apple login or agreements block progress | Ask the owner to complete them directly |
| Private-key mismatch | Use the certificate issued for the original CSR; do not regenerate keys blindly |
| Existing signing files | Reuse after verification or choose a separate directory; do not overwrite |
| Signing identity/profile missing | Check certificate private key, profile selection, team, expiry, and keychain |
| Archive/export succeeded, Transporter missing | Use the verified Xcode `altool` uploader; do not recreate signing resources |
| API upload rejected | Verify team-key type, issuer/key IDs, permissions, and active app record |
| Duplicate build number | Increment the configured build number before uploading |
| Node.js deprecation warning | Update the action's runtime-compatible release, not just runner Node.js |
| App Store Connect icon placeholder | Verify the bundled icon and processed build first |
| Green workflow, no installable beta | Check actual upload, processing, compliance, and group assignment |
| ITMS-90683 / missing purpose string | Inspect the rejection email and linked SDKs; add truthful camera/microphone usage strings to the built app, test, and upload a new build |

At every handoff, record verified results, outstanding owner actions, workflow
run links, and nonsecret resource IDs. Never include secret contents or claim
that unverified steps are complete.

## Fresh public repository checkpoint

Repository: `ErrantActions/frigate-horizon-iphone`.
The app's existing bundle ID remains `com.errantactions.frigatehorizon`.
Previous private run links, account-specific publishing records and billing
details are intentionally not imported into these public instructions.

- Fresh source-only history uses the public GitHub noreply identity.
- The previous repository remains private and is not a parent or fork.
- Actions stay manual, pinned, read-only and free of persisted checkout credentials.
- The protected signing environment requires owner approval and permits only `main`.
- Signing secret values are not migrated. Re-upload them securely from existing
  local signing material before requesting TestFlight; unsigned tests need none.
- GitHub workflow run numbers restart. TestFlight uses an offset of 1000 by
  default; verify the next number exceeds existing Apple uploads before approval.
- Push remains disabled until its separate backend and signing setup are ready.
- No new Apple app registration or credential rotation is required merely
  because the GitHub repository changed.
- Latest verified upload: version 0.1.0, build 1014, source `7b03ab2`.
  [Release workflow](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40814036340)
  passed 88 core and 17 build/signing guard tests, compiled the redesigned app
  for Release, and successfully archived, exported and uploaded to Apple.
  Review now uses a horizontal timeline, fixed center marker, compact transport,
  corner zoom controls, and a wrapping camera-preview grid without sideways scrolling.
  HTTPS playback reconciles actual displayed frames with renderer readiness so
  missed notifications cannot indefinitely leave its waiting label on screen.
  Administrator event details include separately saved sub-label/description
  editing with pre-save conflict checks and explicit queued-update confirmation.
  Live includes a manually launched, muted Camera Tour for tent/stand use, with
  readiness-based intervals, pause/previous/next and foreground-only playback.
- No simulator/UI tests or screenshot generation ran during deployment. UI
  acceptance is performed by the owner on the TestFlight phone.
- Verify build 1014's Apple processing, compliance state and internal group
  assignment separately; upload success alone is not tester availability.
  Do not answer legal declarations without the owner's confirmation.
- Physical phone/Duo appearance and live-server acceptance remain unverified;
  passing CI and Apple processing are not proof those device checks passed.

### Pending image-notification release

- The approved pending-backend attempt was build 1015, source `9a8dc2f`,
  [run 40824746991](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40824746991).
  It passed 111 Swift core tests, 29 CI guards, and both profile checks on
  Xcode 27.1, then failed Release compilation before export/upload.
  `CGImageDestinationAddImage` was missing its destination argument; the source
  fix is prepared. Fresh owner approval is required for another native build.
- A separately approved build 1016, source `ac61631`,
  [run 40826319468](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40826319468),
  passed guards/core/profile checks and successfully compiled and signed the
  notification extension. Main-app compilation failed because a catch-bound
  `error` shadowed the published error property during image-session refresh.
  The assignment is corrected to `self.error`. No archive export or upload
  occurred, and another attempt requires fresh owner approval.
- The owner's subsequent **always push** instruction supersedes those historical
  per-attempt approval requirements for standard public-runner app/TestFlight
  fixes and retries. Build 1017 starts from the corrected source `48e4fe7`;
  backend changes, public/external releases and legal declarations remain separate.
- Build 1017, source `48e4fe7`,
  [run 40827387074](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40827387074),
  passed 111 Swift core and 29 CI guard tests, full Release app/NSE compilation,
  signing, archive/export and upload. Apple reports `VALID`,
  `usesNonExemptEncryption=false` and `IN_BETA_TESTING`; the automatic owner group
  includes the build. No legal value was changed by this agent.
- The operator feature wave is build 1018, source `0efe830`,
  [run 40829834017](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40829834017).
  It adds local per-account camera favorites, density/filter choices, matching
  Camera Tour selection, accessibility layout and foreground/manual notification
  support refresh. All 121 core and 30 CI guard tests passed (38 offline Python
  tests locally, including uncommitted experimental-tool tests); full Release
  app/NSE compile/sign/archive/export/upload passed without UI tests.
  Apple reports `VALID`, `usesNonExemptEncryption=false`, `IN_BETA_TESTING`, and
  automatic owner-group inclusion. Phone UI and actual push/image acceptance
  remain owner checks, not inferred from CI.
- Approved NSE signing setup is now complete: App ID
  `com.errantactions.frigatehorizon.NotificationService` and its App Store
  profile were created using the existing distribution certificate. Both live
  profiles passed the shared validator, and only the new extension-profile
  secret was added. Existing main-profile/certificate/upload secrets are unchanged.
- The owner now approves one image-capable upload while the backend is pending.
  Enable the approved native push build flag and dispatch with
  `allow_pending_image_backend=true`; do not mark the backend ready prematurely.
  The backend agent is implementing the protected service separately.
- Core and native app/NSE compilation/signing/archive/export/upload now passed
  through build 1018. Phone delivery and real-server interaction remain unverified.
- Local camera-tour refinements add immersive controls, custom timing,
  authenticated motion following, and next-camera decoded-frame preloading.
  Their core contracts and native UI compiled and uploaded in 1017/1018;
  physical-device behavior remains owner acceptance.
- A subsequent Live-grid cleanup removes the separate tile footer and enabled
  badge, keeping camera names as compact video overlays. It is not part of the
  build 1015 source; it shipped successfully in builds 1017 and 1018.
- The operator wave carries forward build 1017's existing cleared
  `usesNonExemptEncryption=false` classification as a real Boolean
  `ITSAppUsesNonExemptEncryption=false` in both app/NSE plists. The pinned
  dependencies and encryption behavior are unchanged (WebRTC remains 156.0.0).
  Reassess this declaration if cryptography/dependencies change. There is no
  generic plist switch for France distribution.
- The approved extension App ID/profile and extension-profile secret were added.
  Only the native push build flag is authorized for this pending-backend upload;
  no backend deployment, alert-rule enablement, or real push is authorized.

### Automatic internal tester distribution

Use **Owner Testing Auto**, the internal automatic-distribution group created
on October 29, 2026. Its ID is `2e555dfe-174b-42b5-8b03-83519d7f2fd9`.
Apple API verification confirmed `hasAccessToAllBuilds=true` and exactly the
same single owner tester as the original group. The Settings page confirms
**Automatic for Xcode Builds**.

The original manual **Owner Testing** group is preserved. **Family** is a
separate external group and was not changed or given additional builds/testers.
Future eligible uploads reach the automatic internal group after processing
and export compliance are satisfied; this does not bypass Apple's external
testing review or authorize another native build.

## Official references

Security hardening on October 28 also pins Actions to immutable commits,
disables persisted checkout credentials, restricts signing-file permissions,
and prevents the signing helper from reconfiguring an existing environment.
Previous signing logs and run records are not part of this public repository.

- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
- [App Store Connect API access and keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Apple-supported build upload tools](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple role permissions](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions)
- [GitHub CLI authentication](https://cli.github.com/manual/gh_auth_login)
- [GitHub environment secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)
