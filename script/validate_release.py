#!/usr/bin/env python3
"""Validate OpenCove's public source, bundle, or local release artifacts. No launch."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/SergeSerb2/OpenCove"
ARCHITECTURES = {"arm64": {"arm64"}, "x86_64": {"x86_64"}, "universal2": {"arm64", "x86_64"}}
ROOT_FILES = {"README.md", "LICENSE", "Package.swift", ".gitignore", "version.json",
              "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "CHANGELOG.md"}
SCRIPT_FILES = {"build_and_run.sh", "make_icon.swift", "OpenCoveMediaAdapter.swift", "OpenCoveMediaAdapter.js",
                "MediaFixture.swift", "opencovectl", "smoke.py", "verify_control.py",
                "package_release.py", "validate_release.py", "signing_info.swift", "control_e2e.py", "runtime_e2e.py"}
DOC_FILES = {"building.md", "releasing.md", "privacy.md", "compatibility.md", "architecture.md",
             "calendar.md", "travel-alerts.md", "hardware-huds.md", "notification-mirroring.md",
             "quality.md", "updates.md", "Sparkle-LICENSE.txt", "update-hosting.md", "audio-monitoring.md",
             "download-page-handoff.md"}
DEPLOY_FILES = {"infra/updates/worker.mjs", "infra/updates/wrangler.jsonc", "infra/updates/.gitignore"}
REQUIRED = ROOT_FILES | {"script/" + name for name in SCRIPT_FILES - {"control_e2e.py"}} | {
    "docs/" + name for name in ("building.md", "releasing.md", "privacy.md", "compatibility.md", "quality.md")
} | {"assets/icon.svg", "Sources/OpenCove/App/OpenCoveApp.swift", "docs/updates.md", "docs/Sparkle-LICENSE.txt"}
SPARKLE = {
    "identity": "sparkle", "version": "2.10.0",
    "repository": "https://github.com/sparkle-project/Sparkle",
    "revision": "eef1a539a373c1f1a320624b1130fc5de7b2e100",
    "url": "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
    "sha256": "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959",
    "licenseSHA256": "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe",
}
SECRET = re.compile(rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{30,}")
USAGE_KEYS = {"NSAppleEventsUsageDescription", "NSCalendarsFullAccessUsageDescription",
              "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription",
              "NSBluetoothAlwaysUsageDescription", "NSFocusStatusUsageDescription",
              "NSAudioCaptureUsageDescription", "NSScreenCaptureUsageDescription"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(arguments, **kwargs):
    return subprocess.run([str(arg) for arg in arguments], check=True, **kwargs)


def output(arguments):
    return run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def signing_keychain():
    value = os.environ.get("OPENCOVE_SIGN_KEYCHAIN")
    if value is None:
        return None
    require(value and not any(c in value for c in "\r\n\0") and Path(value).is_absolute(),
            "OPENCOVE_SIGN_KEYCHAIN must name an absolute existing owned keychain file.")
    path = Path(value)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(),
            "OPENCOVE_SIGN_KEYCHAIN must be an existing regular file owned by the current user, not a symlink.")
    return path


def signing_keychain_arguments():
    keychain = signing_keychain()
    return ["--keychain", keychain] if keychain else []


def dependency(root=ROOT):
    package = (root / "Package.swift").read_text()
    require(re.search(r'\.binaryTarget\(\s*name: "Sparkle",\s*url: "' + re.escape(SPARKLE["url"]) +
                      r'",\s*checksum: "' + SPARKLE["sha256"] + r'"\s*\)', package) is not None,
            "Package.swift must use the pinned official Sparkle binary target and checksum.")
    require(not (root / "Package.resolved").exists(), "This binary-only package has no Package.resolved. Review and record new dependencies before building.")
    require(digest((root / "docs/Sparkle-LICENSE.txt").read_bytes()) == SPARKLE["licenseSHA256"], "Sparkle license differs from the pinned upstream release.")
    return dict(SPARKLE)


def update_feed(value, isolated=False):
    require(isinstance(value, str) and not any(c.isspace() for c in value), "Update feed must be a URL without whitespace.")
    url = urlsplit(value)
    require(url.hostname and not url.username and not url.password and not url.query and not url.fragment and url.path.endswith(".xml"),
            "Update feed needs a host and .xml path, with no credentials, query, or fragment.")
    require(url.port is None or 0 < url.port < 65536, "Invalid update feed port.")
    loopback = url.hostname.lower() in {"localhost", "127.0.0.1", "::1"}
    if isolated:
        require(loopback and url.scheme in {"http", "https"}, "Isolated updater verification requires a loopback HTTP(S) feed.")
    else:
        require(url.scheme == "https" and not loopback and "." in url.hostname and
                not url.hostname.endswith((".example", ".invalid", ".test", ".localhost")) and
                url.hostname not in {"example.com", "example.org", "example.net"}, "Release updates require a real public HTTPS appcast URL.")


def update_key(value):
    require(isinstance(value, str), "Supply the real Sparkle public Ed25519 key with OPENCOVE_UPDATE_PUBLIC_ED_KEY.")
    try:
        data = base64.b64decode(value, validate=True)
    except ValueError:
        raise ValueError("Sparkle public key must be canonical base64 for exactly 32 bytes.") from None
    require(len(data) == 32 and any(data) and base64.b64encode(data).decode() == value,
            "Sparkle public key must be canonical base64 for exactly 32 bytes; an all-zero key is invalid.")


def update_info(info, variant):
    mode = info.get("OpenCoveUpdaterMode")
    if mode == "disabled":
        require(variant == "development" and not any(k in info for k in ("SUFeedURL", "SUPublicEDKey", "SUDefaultsDomain")), "Disabled updater bundles must be development bundles without feed or trust keys.")
        return
    isolated = mode == "isolated-test"
    require((isolated and variant == "development") or (mode == "release" and variant == "release"), "Updater mode does not match the bundle variant.")
    require(isolated or info.get("OpenCoveBuildConfiguration") == "release", "Release updater requires an optimized build.")
    update_feed(info.get("SUFeedURL"), isolated)
    update_key(info.get("SUPublicEDKey"))
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "Update archives must be verified before extraction.")
    require("SUEnableAutomaticChecks" not in info and "SUAutomaticallyUpdate" not in info and "SUAllowsAutomaticUpdates" not in info,
            "Keep Sparkle's consent and automatic download defaults; do not forge opt-in.")
    if isolated:
        require(re.fullmatch(r"org\.opencove\.OpenCove\.updater-test\.[0-9a-f]{32}", info.get("SUDefaultsDomain", "")) is not None,
                "Isolated updater bundles need a fresh private Sparkle defaults domain.")
    else:
        require("SUDefaultsDomain" not in info and "NSAppTransportSecurity" not in info, "Release updates must use the normal defaults domain and default transport security.")


def framework_paths(framework):
    base = framework / "Versions/B"
    return [base / "XPCServices/Installer.xpc", base / "XPCServices/Downloader.xpc",
            base / "Autoupdate", base / "Updater.app", framework]


def contained_bundle_links(app):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for path in app.rglob("*"):
        if path.is_symlink():
            require(path.is_relative_to(framework) and not os.path.isabs(os.readlink(path)) and
                    path.resolve(strict=True).is_relative_to(framework.resolve()), "Unexpected or escaping bundle symlink.")
        require(path.name not in {".DS_Store", ".local", ".git", "__pycache__"}, "Private/generated bundle content.")


def linkage(binary):
    libraries = []
    # Universal output includes one heading per architecture. Only indented
    # install names are dependencies, never the caller-controlled heading path.
    for line in output(["otool", "-L", binary]).splitlines():
        if not line.startswith("\t"):
            continue
        name = line.strip().split(" (", 1)[0]
        require(name.startswith(("/System/Library/", "/usr/lib/", "@loader_path/", "@executable_path/")) or
                name == "@rpath/Sparkle.framework/Versions/B/Sparkle" or
                re.fullmatch(r"@rpath/libswift[A-Za-z0-9_]+\.dylib", name), "Unexpected non-system Mach-O dependency.")
        libraries.append(name)
    return libraries


def sparkle_bundle(app, arch, source_root):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    require(framework.is_dir() and not framework.is_symlink() and
            {p.name for p in framework.parent.iterdir()} == {"Sparkle.framework"}, "Expected only the embedded Sparkle framework.")
    info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    require(info.get("CFBundleShortVersionString") == SPARKLE["version"] and info.get("CFBundleIdentifier") == "org.sparkle-project.Sparkle", "Wrong Sparkle framework identity/version.")
    resources = app / "Contents/Resources"
    require((resources / "Sparkle-LICENSE.txt").read_bytes() == (source_root / "docs/Sparkle-LICENSE.txt").read_bytes(), "Missing Sparkle and embedded third-party licenses.")
    require(json.loads((resources / "SPARKLE_DEPENDENCY.json").read_text()) == dependency(source_root), "Sparkle SDK provenance differs from the pinned dependency.")
    for code in framework_paths(framework):
        require(code.exists() and not code.is_symlink(), "Missing Sparkle nested code: " + code.name)
        if code.suffix in {".app", ".xpc"}:
            nested = plistlib.loads((code / "Contents/Info.plist").read_bytes())
            binary = code / "Contents/MacOS" / nested["CFBundleExecutable"]
        elif code.suffix == ".framework":
            binary = code / "Versions/B/Sparkle"
        else:
            binary = code
        require(binary.is_file() and os.access(binary, os.X_OK), "Sparkle executable is missing or lost permissions.")
        require(ARCHITECTURES[arch] <= set(output(["lipo", "-archs", binary]).split()), "Sparkle helper is missing a requested architecture.")
        linkage(binary)
    binary = app / "Contents/MacOS/OpenCove"
    require("@rpath/Sparkle.framework/Versions/B/Sparkle" in linkage(binary), "App does not link the real Sparkle framework.")
    require("path @executable_path/../Frameworks (offset" in output(["otool", "-l", binary]), "App is missing its bundled-framework rpath.")
    runpaths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", output(["otool", "-l", binary]))
    require(set(runpaths) <= {"@executable_path/../Frameworks", "@loader_path", "/usr/lib/swift"}, "App retains an external build-machine runpath.")


def version(path=None):
    value = json.loads((path or ROOT / "version.json").read_text())
    require(isinstance(value, dict) and set(value) == {"version", "build", "prerelease"}, "version.json needs exactly version, build, and prerelease.")
    require(all(isinstance(v, str) for v in value.values()), "Version fields must be strings.")
    parts = value["version"].split(".")
    require(len(parts) == 3 and all(re.fullmatch(r"0|[1-9][0-9]*", p) for p in parts), "version must be canonical MAJOR.MINOR.PATCH.")
    require(all(int(p) <= limit for p, limit in zip(parts, [9999, 99, 99])), "Version components exceed Apple's bundle field limits.")
    require(re.fullmatch(r"[1-9][0-9]{0,3}", value["build"]) is not None, "build must be a canonical integer from 1 to 9999, not an epoch.")
    require(value["prerelease"] == "" or re.fullmatch(r"(?:alpha|beta|rc)\.[1-9][0-9]{0,3}", value["prerelease"]) is not None,
            "prerelease must be empty or alpha.N, beta.N, or rc.N (1-9999).")
    return value


def label(value):
    return value["version"] + ("-" + value["prerelease"] if value["prerelease"] else "")


def public_path(name):
    path = PurePosixPath(name)
    if (str(path) != name or path.is_absolute() or any(c in name for c in "\\\r\n\0") or
            any(p in {"..", ".", "__pycache__", ".DS_Store"} for p in path.parts)):
        return False
    return (name in ROOT_FILES or name in DEPLOY_FILES or name == "assets/icon.svg" or
            (name.startswith("Sources/OpenCove/") and path.suffix == ".swift") or
            (name.startswith("script/") and name[7:] in SCRIPT_FILES) or
            (name.startswith("docs/") and name[5:] in DOC_FILES) or
            (name.startswith(".github/") and path.suffix in {".md", ".yml", ".yaml"}))


def source_inventory():
    # SwiftPM selects these before Package.swift. Never execute an unrecorded
    # version-specific manifest, even for an intentional dirty local build.
    require(not any(p.name.startswith("Package@") and p.name.endswith(".swift") for p in ROOT.iterdir()),
            "Version-specific Package@*.swift manifests are not public build inputs.")
    names = {name for name in ROOT_FILES if (ROOT / name).exists()}
    for folder in ("Sources", "script", "docs", ".github", "assets", "infra"):
        start = ROOT / folder
        require(not start.is_symlink(), "Source directory must not be a symlink: " + folder)
        for directory, subdirectories, files in os.walk(start, followlinks=False):
            for child in subdirectories:
                path = Path(directory) / child
                if folder == "Sources":
                    require(not path.is_symlink(), "Source directory must not be a symlink: " + str(path.relative_to(ROOT)))
            for child in files:
                name = str((Path(directory) / child).relative_to(ROOT))
                require(folder != "Sources" or public_path(name), "Unexpected compiler input: " + name)
                if public_path(name):
                    names.add(name)
    return names


def verified_source_bytes(root, entry):
    """Read the actual regular file through non-link directory handles.

    Validate the same bytes and executable mode that a snapshot/archive copies,
    rather than trusting an earlier inventory or a later path-based stat call.
    """
    name = entry["path"]
    require(public_path(name) and type(entry["executable"]) is bool and
            isinstance(entry["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is not None,
            "Invalid source manifest entry: " + str(name))
    descriptors = []
    try:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(directory)
        parts = PurePosixPath(name).parts
        for part in parts[:-1]:
            directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            descriptors.append(directory)
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode), "Source must be a regular file: " + name)
            data = stream.read()
            after = os.fstat(stream.fileno())
        require((before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "Source changed while reading: " + name)
        require(digest(data) == entry["sha256"] and not SECRET.search(data), "Source digest/credential check failed: " + name)
        require(bool(after.st_mode & 0o111) == entry["executable"], "Source executable mode changed: " + name)
        return data
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def source_manifest(allow_dirty=False):
    sdk = dependency()
    actual = source_inventory()
    if not (ROOT / ".git").exists():
        # Source ZIPs deliberately omit Git. Trust only a complete manifest whose
        # allowlisted regular files, digests, and modes match this extracted tree.
        manifest = json.loads((ROOT / "SOURCE_MANIFEST.json").read_text())
        entries = manifest["files"]
        require(manifest["repository"] == REPOSITORY and re.fullmatch(r"[0-9a-f]{40}", manifest["commit"]) is not None,
                "Invalid exported source identity.")
        require(manifest.get("dependencies") == [sdk], "Exported source does not record the pinned Sparkle dependency.")
        require(type(manifest["dirty"]) is bool and (allow_dirty or not manifest["dirty"]), "Exported source records uncommitted changes.")
        require(digest(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()) == manifest["treeSHA256"], "Exported source manifest digest mismatch.")
        names = [entry["path"] for entry in entries]
        require(len(names) == len(set(names)) and REQUIRED <= set(names), "Exported source manifest is incomplete or repeats a path.")
        require(actual == set(names), "Exported public source contains missing or unrecorded files.")
        for entry in entries:
            verified_source_bytes(ROOT, entry)
        return manifest
    tracked = set(output(["git", "-C", ROOT, "ls-files", "-z"]).split("\0")) - {""}
    require(all(public_path(name) for name in tracked), "Tracked files exceed the public source allowlist. Remove private or unexpected files before release.")
    status = output(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"])
    require(allow_dirty or not status, "Release requires a clean committed checkout. Local inspection can use source --allow-dirty.")
    names = set(tracked)
    if allow_dirty:
        names |= actual
    require(REQUIRED <= names, "Public source is incomplete: " + ", ".join(sorted(REQUIRED - names)))
    entries = []
    for name in sorted(names):
        path = ROOT / name
        require(path.is_file() and not path.is_symlink() and not any(p.is_symlink() for p in path.parents if p != ROOT.parent), "Source must contain regular files: " + name)
        data = path.read_bytes()
        require(not SECRET.search(data), "Potential credential in public source: " + name)
        entry = {"path": name, "sha256": digest(data), "executable": bool(path.stat().st_mode & 0o111)}
        verified_source_bytes(ROOT, entry)
        entries.append(entry)
    tree = digest(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode())
    return {"repository": REPOSITORY, "commit": output(["git", "-C", ROOT, "rev-parse", "HEAD"]),
            "dirty": bool(status), "treeSHA256": tree, "files": entries, "dependencies": [sdk]}


def bundle(app, arch, variant, signing, notarized=False, expected_version=None, source_root=None):
    source_root = source_root or ROOT
    require(arch in ARCHITECTURES, "Unsupported architecture.")
    require(signing in {"adhoc", "developer-id"}, "Unsupported signing mode.")
    keychain = signing_keychain()
    require(signing == "developer-id" or keychain is None, "Ad-hoc verification rejects an ambient OPENCOVE_SIGN_KEYCHAIN.")
    require(not notarized or signing == "developer-id", "Notarization requires Developer ID signing.")
    require(app.is_dir() and not app.is_symlink(), "App bundle is missing or is a symlink.")
    contained_bundle_links(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    update_info(info, variant)
    value = expected_version or version(source_root / "version.json")
    expected_id = "org.opencove.OpenCove" + (".dev" if variant == "development" else "")
    require(info.get("CFBundleIdentifier") == expected_id, "Unexpected bundle identifier.")
    require(info.get("CFBundleExecutable") == "OpenCove" and info.get("CFBundlePackageType") == "APPL", "Invalid executable or bundle type.")
    require(info.get("CFBundleShortVersionString") == value["version"] and info.get("CFBundleVersion") == value["build"], "Bundle version differs from version.json.")
    require(info.get("OpenCoveVersionLabel") == label(value), "Bundle prerelease label differs from version.json.")
    require(info.get("LSMinimumSystemVersion") == "15.0" and info.get("LSUIElement") is True, "Unexpected deployment target or app mode.")
    require(all(isinstance(info.get(k), str) and info[k].strip() for k in USAGE_KEYS), "Missing privacy usage description.")
    scheme = "opencove-dev" if variant == "development" else "opencove"
    require(info.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes") == [scheme], "Unexpected URL scheme.")
    binary = app / "Contents/MacOS/OpenCove"
    require(os.access(binary, os.X_OK), "App executable has lost its executable bit.")
    require(set(output(["lipo", "-archs", binary]).split()) == ARCHITECTURES[arch], "Mach-O architecture does not match the artifact name.")
    resources = app / "Contents/Resources"
    require((resources / "LICENSE").read_bytes() == (source_root / "LICENSE").read_bytes(), "Missing or modified MIT license.")
    require((resources / "OpenCoveMediaAdapter.swift").read_bytes() == (source_root / "script/OpenCoveMediaAdapter.swift").read_bytes(), "Missing or stale media adapter source.")
    require((resources / "OpenCoveMediaAdapter.js").read_bytes() == (source_root / "script/OpenCoveMediaAdapter.js").read_bytes(), "Missing or stale JavaScript media adapter.")
    require((resources / "OpenCove.icns").stat().st_size > 0, "App icon is missing.")
    require(REPOSITORY in (resources / "SOURCE_NOTICE.txt").read_text(), "Source/provenance notice is missing.")
    manifest = json.loads((resources / "SOURCE_MANIFEST.json").read_text())
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["commit"]) is not None and re.fullmatch(r"[0-9a-f]{64}", manifest["treeSHA256"]) is not None, "Invalid source manifest identity.")
    require(info.get("OpenCoveSourceRevision") == manifest["commit"] and info.get("OpenCoveSourceTreeSHA256") == manifest["treeSHA256"], "Bundle source identities disagree.")
    require(manifest.get("dependencies") == [dependency(source_root)], "Bundle source manifest is missing Sparkle's dependency identity.")
    sparkle_bundle(app, arch, source_root)
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    # Human-readable codesign diagnostics contain caller-controlled paths. Only
    # Security framework values and an Apple certificate requirement are gates.
    # Always execute the validator's own helper. Artifact source ZIPs are data,
    # never executable validation tools supplied by an archive being inspected.
    slices = json.loads(output(["xcrun", "swift", ROOT / "script/signing_info.swift", app.resolve(),
                                *sorted(ARCHITECTURES[arch])]))
    require(isinstance(slices, list) and len(slices) == len(ARCHITECTURES[arch]), "Missing structured signing information.")
    for item in slices:
        if signing == "adhoc":
            require(item["adHoc"] is True and item["teamIdentifier"] is None, "Expected an ad-hoc signature.")
        else:
            require(item["developerIDApplication"] is True and item["adHoc"] is False,
                    "Expected an Apple-issued Developer ID Application certificate.")
            require(item["runtime"] is True and isinstance(item["secureTimestamp"], str),
                    "Expected hardened runtime and a secure signing timestamp.")
            require(isinstance(item["teamIdentifier"], str) and re.fullmatch(r"[A-Z0-9]{10}", item["teamIdentifier"]) is not None,
                    "Developer ID team is missing.")
            require(item["automationEntitlementOnly"] is True, "Unexpected hardened runtime entitlements.")
    if signing == "developer-id":
        require(len({item["teamIdentifier"] for item in slices}) == 1, "Architecture signing teams differ.")
    team = slices[0]["teamIdentifier"]
    for code in framework_paths(app / "Contents/Frameworks/Sparkle.framework"):
        nested = json.loads(output(["xcrun", "swift", ROOT / "script/signing_info.swift", code.resolve(),
                                    *sorted(ARCHITECTURES[arch])]))
        require(len(nested) == len(slices), "Missing nested signing information.")
        for item in nested:
            require(item["safeSparkleEntitlements"] is True, "Unexpected Sparkle helper entitlements.")
            if signing == "developer-id":
                require(item["developerIDApplication"] is True and item["teamIdentifier"] == team and
                        item["runtime"] is True and isinstance(item["secureTimestamp"], str),
                        "Sparkle nested code requires the same Developer ID team, hardened runtime, and timestamp.")
            else:
                require(item["adHoc"] is True and item["teamIdentifier"] is None, "Sparkle nested code must be signed ad-hoc for local bundles.")
    if notarized:
        run(["xcrun", "stapler", "validate", app])
        run(["spctl", "--assess", "--type", "execute", "--verbose=2", app])
    return info


def extract_clean(archive, destination, bundle_links=False):
    with zipfile.ZipFile(archive) as zipped:
        names = set()
        for item in zipped.infolist():
            path = PurePosixPath(item.filename)
            require(str(path) + ("/" if item.is_dir() else "") == item.filename and
                    not any(c in item.filename for c in "\r\n\0"), "Noncanonical ZIP path.")
            require(item.filename not in names, "Duplicate ZIP entry.")
            names.add(item.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in item.filename, "Unsafe ZIP path.")
            mode = item.external_attr >> 16
            require(stat.S_IFMT(mode) in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK}, "Unsupported ZIP entry type.")
            if stat.S_ISLNK(mode):
                require(bundle_links and path.is_relative_to(PurePosixPath("OpenCove.app/Contents/Frameworks/Sparkle.framework")) and item.file_size < 4096,
                        "ZIP links are allowed only inside the bundled Sparkle framework.")
            require(item.file_size <= 512 * 1024 * 1024, "Oversized ZIP entry.")
        require(sum(i.file_size for i in zipped.infolist()) <= 1024 * 1024 * 1024, "Oversized ZIP contents.")
        # Extract regular data first and links last. Refuse entries below links,
        # absolute targets, and targets escaping the embedded framework.
        links = {i.filename for i in zipped.infolist() if stat.S_ISLNK(i.external_attr >> 16)}
        require(not any(str(p) in links for name in names for p in PurePosixPath(name).parents), "ZIP entry traverses a symlink.")
        destination.mkdir(parents=True, exist_ok=True)
        for item in zipped.infolist():
            path = destination / item.filename
            if item.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            elif item.filename not in links:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(zipped.read(item))
                path.chmod(0o755 if item.external_attr >> 16 & 0o111 else 0o644)
        framework = destination / "OpenCove.app/Contents/Frameworks/Sparkle.framework"
        for name in sorted(links):
            path = destination / name
            target = zipped.read(name).decode("utf-8")
            require(target and not os.path.isabs(target) and "\\" not in target and "\0" not in target and
                    (path.parent / target).resolve().is_relative_to(framework.resolve()), "Unsafe ZIP symlink target.")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(target)
        if bundle_links:
            contained_bundle_links(destination / "OpenCove.app")


def artifacts(directory):
    metadata_files = list(directory.glob("*-release.json"))
    require(len(metadata_files) == 1, "Expected one release metadata file.")
    metadata = json.loads(metadata_files[0].read_text())
    require(metadata["version"] == version(), "Artifacts differ from the current version config.")
    arch, signing = metadata["architecture"], metadata["signing"]
    require(arch in ARCHITECTURES and signing in {"adhoc", "developer-id"}, "Invalid artifact architecture or signing mode.")
    require(type(metadata["notarized"]) is bool, "Invalid notarization status.")
    base = f"OpenCove-{label(metadata['version'])}-{arch}-{signing}"
    source_base = f"OpenCove-{label(metadata['version'])}-source"
    names = {base + ".zip", source_base + ".zip", base + "-release.json", "SHA256SUMS"}
    require({p.name for p in directory.iterdir()} == names and all(p.is_file() and not p.is_symlink() for p in directory.iterdir()), "Release directory contains missing or unexpected files.")
    lines = (directory / "SHA256SUMS").read_text().splitlines()
    expected_names = names - {"SHA256SUMS"}
    require(len(lines) == len(expected_names), "Unexpected checksum entries.")
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        require(match is not None and match[2] in expected_names, "Invalid checksum entry.")
        expected_names.remove(match[2])
        require(digest((directory / match[2]).read_bytes()) == match[1], "Artifact checksum mismatch.")
    with tempfile.TemporaryDirectory(prefix="opencove-artifact-check-") as temporary:
        scratch = Path(temporary)
        extract_clean(directory / (base + ".zip"), scratch / "binary", bundle_links=True)
        require({p.name for p in (scratch / "binary").iterdir()} == {"OpenCove.app"}, "Unexpected app ZIP contents.")
        app = scratch / "binary/OpenCove.app"
        extract_clean(directory / (source_base + ".zip"), scratch / "source")
        source = scratch / "source" / source_base
        require({p.name for p in (scratch / "source").iterdir()} == {source_base}, "Unexpected source ZIP root.")
        manifest = json.loads((source / "SOURCE_MANIFEST.json").read_text())
        require(manifest.get("dependencies") == [dependency(source)], "Source ZIP dependency identity is missing or stale.")
        info = bundle(app, arch, "release", signing, metadata["notarized"], metadata["version"], source_root=source)
        require(metadata.get("updater") == {k: v for k, v in info.items() if k in {
            "OpenCoveUpdaterMode", "SUFeedURL", "SUPublicEDKey", "SUVerifyUpdateBeforeExtraction"}}, "Release metadata and bundle updater policy differ.")
        require(manifest == json.loads((app / "Contents/Resources/SOURCE_MANIFEST.json").read_text()) == metadata["source"], "App/source/release manifests differ.")
        entries = manifest["files"]
        require(not manifest["dirty"] and manifest["repository"] == REPOSITORY, "Source archive is not a clean OpenCove snapshot.")
        require(digest(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()) == manifest["treeSHA256"], "Source tree digest mismatch.")
        paths = [entry["path"] for entry in entries]
        require(len(paths) == len(set(paths)) and REQUIRED <= set(paths), "Invalid source manifest file list.")
        require({str(p.relative_to(source)) for p in source.rglob("*") if p.is_file()} == set(paths) | {"SOURCE_MANIFEST.json"}, "Source archive contains unexpected files.")
        for entry in entries:
            require(public_path(entry["path"]), "Private/unexpected source archive path.")
            path = source / entry["path"]
            data = path.read_bytes()
            require(not SECRET.search(data) and digest(data) == entry["sha256"], "Source archive content differs from its manifest.")
            require(bool(path.stat().st_mode & 0o111) == entry["executable"], "Source executable mode differs from its manifest.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    v = commands.add_parser("version")
    v.add_argument("--version-file", type=Path)
    source = commands.add_parser("source")
    source.add_argument("--allow-dirty", action="store_true", help="Inspect intentional local edits; never used for release packaging")
    app = commands.add_parser("bundle")
    app.add_argument("app", type=Path)
    app.add_argument("--arch", choices=ARCHITECTURES, required=True)
    app.add_argument("--variant", choices=["development", "release"], default="release")
    app.add_argument("--signing", choices=["adhoc", "developer-id"], default="adhoc")
    app.add_argument("--notarized", action="store_true")
    archive = commands.add_parser("artifacts")
    archive.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "version":
        print(json.dumps(version(args.version_file), sort_keys=True))
    elif args.command == "source":
        manifest = source_manifest(args.allow_dirty)
        print(f"Public source: {len(manifest['files'])} files; dirty={manifest['dirty']}; SHA-256 {manifest['treeSHA256']}")
    elif args.command == "bundle":
        bundle(args.app, args.arch, args.variant, args.signing, args.notarized)
        print("Bundle structure, source notices, architecture, version, and signature verified.")
    else:
        artifacts(args.directory)
        print("Release ZIPs, extracted bundle, source manifest, and checksums verified.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, IndexError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"OpenCove validation: {error}", file=sys.stderr)
        sys.exit(1)
