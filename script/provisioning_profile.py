"""Narrow Developer ID KVS profile checks. Plist decoding is NOT authentication.

syspolicy_check distribution supplies the documented system distribution checks,
including provisioning checks. Exact CMS/DER authentication remains unproven.
"""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

BUNDLE_ID = "org.opencove.OpenCove"
MAX_PROFILE_BYTES = 1024 * 1024
AUTOMATION = "com.apple.security.automation.apple-events"
TEAM = "com.apple.developer.team-identifier"
APP_ID = "com.apple.application-identifier"
KVS = "com.apple.developer.ubiquity-kvstore-identifier"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def resolved_kvs(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Z0-9]{10}\." + re.escape(BUNDLE_ID), value),
            "KVS identifier must be the authorized resolved ten-character prefix plus org.opencove.OpenCove; no wildcard or build variable.")
    return value


def read_profile(path):
    # Walk with directory descriptors: reject symlink components and do not
    # follow a replaced path between the ownership check and the bounded read.
    path = Path(path).expanduser()
    require(path.is_absolute() and ".." not in path.parts,
            "Provisioning profile needs an absolute path without parent traversal.")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(),
                    "Provisioning profile must be an existing regular file owned by the current user, without symlinks.")
            require(0 < info.st_size <= MAX_PROFILE_BYTES, "Provisioning profile must be between 1 byte and 1 MiB.")
            data = stream.read(MAX_PROFILE_BYTES + 1)
            after = os.fstat(stream.fileno())
            require(len(data) == info.st_size and (info.st_size, info.st_mtime_ns, info.st_ctime_ns) ==
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns), "Provisioning profile changed while reading.")
            return data
    finally:
        os.close(directory)


def inspect_profile(data, kvs_identifier):
    """Conservative diagnostic checks, never an Apple-issuance trust decision."""
    resolved_kvs(kvs_identifier)
    require(0 < len(data) <= MAX_PROFILE_BYTES, "Provisioning profile must be between 1 byte and 1 MiB.")
    with tempfile.TemporaryDirectory(prefix="opencove-profile-inspect-") as temporary:
        path = Path(temporary) / "profile.provisionprofile"
        path.write_bytes(data)
        try:
            result = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(path)],
                                    check=True, capture_output=True, timeout=30)
        except (subprocess.SubprocessError, OSError):
            raise ValueError("Could not decode the provisioning profile; no profile has been authenticated.") from None
    require(len(result.stdout) <= 8 * MAX_PROFILE_BYTES, "Oversized decoded provisioning profile.")
    profile = plistlib.loads(result.stdout)
    require(isinstance(profile, dict), "Provisioning profile payload must be a dictionary.")
    require(profile.get("ProvisionsAllDevices") is True and "ProvisionedDevices" not in profile,
            "A Developer ID distribution profile with ProvisionsAllDevices is required.")
    created, expires = profile.get("CreationDate"), profile.get("ExpirationDate")
    require(isinstance(created, datetime.datetime) and isinstance(expires, datetime.datetime), "Profile validity dates are missing.")
    created, expires = (date.replace(tzinfo=datetime.timezone.utc) if date.tzinfo is None else date.astimezone(datetime.timezone.utc)
                        for date in (created, expires))
    require(created <= datetime.datetime.now(datetime.timezone.utc) < expires, "Provisioning profile is not currently valid.")
    teams = profile.get("TeamIdentifier")
    require(isinstance(teams, list) and len(teams) == 1 and isinstance(teams[0], str) and
            re.fullmatch(r"[A-Z0-9]{10}", teams[0]), "Profile must identify one signing team.")
    permitted = profile.get("Entitlements")
    require(isinstance(permitted, dict) and permitted.get(TEAM) == teams[0], "Profile entitlement team differs from its team.")
    require(all(permitted.get(key, False) is False for key in ("get-task-allow", "com.apple.security.get-task-allow")),
            "Development/debug provisioning profiles are not accepted.")
    app_id = permitted.get(APP_ID)
    require(isinstance(app_id, str) and re.fullmatch(r"[A-Z0-9]{10}\." + re.escape(BUNDLE_ID), app_id),
            "Profile must authorize the explicit macOS org.opencove.OpenCove App ID.")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    require(isinstance(prefixes, list) and app_id.split(".", 1)[0] in prefixes,
            "Profile App ID prefix is inconsistent.")
    allowed_kvs = permitted.get(KVS)
    require(isinstance(allowed_kvs, str) and (allowed_kvs == kvs_identifier or
            (re.fullmatch(r"[A-Z0-9]{10}\.(?:[A-Za-z0-9-]+\.)*\*", allowed_kvs) and kvs_identifier.startswith(allowed_kvs[:-1]))),
            "Profile does not authorize the supplied resolved KVS identifier.")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and certificates and all(isinstance(cert, bytes) and cert for cert in certificates),
            "Profile signing certificates are missing.")
    profile_uuid = profile.get("UUID")
    require(isinstance(profile_uuid, str) and re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", profile_uuid),
            "Profile UUID is missing or malformed.")
    return {
        "data": data,
        "entitlements": {AUTOMATION: True, TEAM: teams[0], APP_ID: app_id, KVS: kvs_identifier},
        "certificateSHA256": {hashlib.sha256(cert).hexdigest() for cert in certificates},
        "metadata": {"sha256": hashlib.sha256(data).hexdigest(), "uuid": profile_uuid,
                     "creationDate": created.isoformat(), "expirationDate": expires.isoformat(),
                     "teamIdentifier": teams[0], "applicationIdentifier": app_id, "kvsIdentifier": kvs_identifier},
    }


def require_certificate(profile, certificate):
    """The same actual-DER authorization predicate before signing and per slice."""
    require(isinstance(certificate, bytes) and certificate and
            hashlib.sha256(certificate).hexdigest() in profile["certificateSHA256"],
            "Signing certificate is not authorized by the provisioning profile.")


def distribution_command():
    # Apple syspolicy_check(1), distribution: the execution checks include
    # provisioning profiles. Do not replace this with CMS decoding, generic
    # X.509 trust, certificate names, guessed Apple OIDs, or codesign alone.
    command = Path("/usr/bin/syspolicy_check")
    require(command.is_file() and os.access(command, os.X_OK),
            "KVS packaging requires the system syspolicy_check distribution gate.")
    return command


def check_distribution(app):
    subprocess.run([str(distribution_command()), "distribution", str(app)], check=True)
