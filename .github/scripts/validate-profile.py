"""Validate distribution profile requirements before spending time compiling."""

from __future__ import annotations

import argparse
import datetime
import fnmatch
import plistlib
from pathlib import Path
from typing import Any


def validate_profile(
    profile: dict[str, Any],
    team_id: str,
    bundle_id: str,
    native_push: bool,
    now: datetime.datetime | None = None,
    required_keychain_group: str | None = None,
) -> dict[str, Any]:
    """Return export options only for a matching, unexpired App Store profile."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if profile.get("TeamIdentifier") != [team_id]:
        raise ValueError("The provisioning profile does not match APPLE_TEAM_ID.")
    entitlements = profile.get("Entitlements")
    if (
        not isinstance(entitlements, dict)
        or entitlements.get("application-identifier") != f"{team_id}.{bundle_id}"
    ):
        raise ValueError("The provisioning profile does not match APP_BUNDLE_ID.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise TypeError("The provisioning profile has no valid expiration date.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= now:
        raise ValueError("The distribution provisioning profile has expired.")
    if (
        "ProvisionedDevices" in profile
        or profile.get("ProvisionsAllDevices")
        or entitlements.get("get-task-allow")
    ):
        raise ValueError(
            "An App Store distribution profile is required, not development, ad hoc, or enterprise."
        )
    if native_push and entitlements.get("aps-environment") != "production":
        raise ValueError(
            "ENABLE_NATIVE_PUSH requires a refreshed App Store profile with the production aps-environment entitlement."
        )
    if required_keychain_group is not None:
        groups = entitlements.get("keychain-access-groups")
        if not isinstance(groups, list) or not any(
            isinstance(group, str)
            and group.startswith(team_id + ".")
            and fnmatch.fnmatchcase(required_keychain_group, group)
            for group in groups
        ):
            raise ValueError(
                "The provisioning profile does not allow the notification-image Keychain group."
            )
    name = profile.get("Name")
    if not isinstance(name, str) or not name:
        raise ValueError("The provisioning profile has no valid name.")
    return {
        "method": "app-store-connect",
        "destination": "export",
        "signingStyle": "manual",
        "teamID": team_id,
        "signingCertificate": "Apple Distribution",
        "provisioningProfiles": {bundle_id: name},
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
    }


def validate_image_profiles(
    app: dict[str, Any],
    extension: dict[str, Any],
    team_id: str,
    bundle_id: str,
    now: datetime.datetime | None = None,
) -> dict[str, Any]:
    """Require a push-enabled app and a matching, least-privilege image extension."""
    for profile in (app, extension):
        if profile.get("ApplicationIdentifierPrefix") != [team_id]:
            raise ValueError(
                "App and extension must use the expected signing prefix for shared notification storage."
            )
    group = f"{team_id}.{bundle_id}.notificationImages"
    options = validate_profile(app, team_id, bundle_id, True, now, group)
    extension_options = validate_profile(
        extension, team_id, bundle_id + ".NotificationService", False, now, group
    )
    app_certificates = app.get("DeveloperCertificates")
    extension_certificates = extension.get("DeveloperCertificates")
    if (
        not isinstance(app_certificates, list)
        or not isinstance(extension_certificates, list)
        or not any(
            isinstance(certificate, bytes) and certificate in extension_certificates
            for certificate in app_certificates
        )
    ):
        raise ValueError(
            "App and extension profiles must allow the same distribution certificate."
        )
    options["provisioningProfiles"].update(extension_options["provisioningProfiles"])
    return options


def main() -> None:
    """Read only the temporary decoded profile and optional export-options output."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--extension-profile", type=Path, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--native-push", choices=("true", "false"), default="false")
    parser.add_argument("--export-options", type=Path)
    args = parser.parse_args()
    try:
        profile = plistlib.loads(args.profile.read_bytes())
        if not isinstance(profile, dict):
            raise TypeError(
                "The provisioning profile is not a property-list dictionary."
            )
        extension = plistlib.loads(args.extension_profile.read_bytes())
        if not isinstance(extension, dict):
            raise TypeError("The extension profile is not a property-list dictionary.")
        if args.native_push != "true":
            raise ValueError(
                "The next TestFlight build requires approved native push with notification images, not text-only push."
            )
        options = validate_image_profiles(
            profile, extension, args.team_id, args.bundle_id
        )
        if args.export_options is not None:
            args.export_options.write_bytes(plistlib.dumps(options))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Profile validation failed: {error}") from error
    print("App Store provisioning profile requirements passed.")


if __name__ == "__main__":
    main()
