"""Validate distribution profile requirements before spending time compiling."""

from __future__ import annotations

import argparse
import datetime
import plistlib
from pathlib import Path
from typing import Any


def validate_profile(
    profile: dict[str, Any],
    team_id: str,
    bundle_id: str,
    native_push: bool,
    now: datetime.datetime | None = None,
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


def main() -> None:
    """Read only the temporary decoded profile and optional export-options output."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
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
        options = validate_profile(
            profile, args.team_id, args.bundle_id, args.native_push == "true"
        )
        if args.export_options is not None:
            args.export_options.write_bytes(plistlib.dumps(options))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Profile validation failed: {error}") from error
    print("App Store provisioning profile requirements passed.")


if __name__ == "__main__":
    main()
