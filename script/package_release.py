#!/usr/bin/env python3
"""Build or package OpenCove locally. Never publishes, installs, or launches an app."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
import validate_release as check

ROOT = check.ROOT


def signing_configuration(mode, notarize=False, profile=None):
    identity = os.environ.get("OPENCOVE_SIGN_IDENTITY", "")
    profile = profile or os.environ.get("OPENCOVE_NOTARY_PROFILE", "")
    if mode == "adhoc":
        check.require(not identity and not profile and not notarize, "Ad-hoc mode rejects signing identities, notary profiles, and notarization. Select --signing developer-id explicitly.")
        return None, None
    check.require(re.fullmatch(r"Developer ID Application: [^\r\n]+ \([A-Z0-9]{10}\)", identity) is not None,
                  "Set OPENCOVE_SIGN_IDENTITY to the full Developer ID Application identity. Apple Development is not a distribution identity.")
    identities = check.output(["security", "find-identity", "-v", "-p", "codesigning"])
    check.require('"' + identity + '"' in identities, "The requested Developer ID Application identity and private key are not available.")
    check.require(not profile or notarize, "A notary profile requires --notarize; no implicit Apple upload is allowed.")
    check.require(not notarize or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile) is not None,
                  "--notarize requires a local keychain profile (OPENCOVE_NOTARY_PROFILE or --notary-profile).")
    return identity, profile


def toolchain():
    check.require(platform.system() == "Darwin", "Building requires macOS.")
    sdk = check.output(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    check.require(int(sdk.split(".")[0]) >= 26, "Building needs the macOS 26 SDK or later for the guarded glass APIs. Select Xcode 26 or later with DEVELOPER_DIR.")
    return {"xcode": check.output(["xcodebuild", "-version"]), "swift": check.output(["xcrun", "swift", "--version"]), "sdk": sdk}


def destination(path, replace=False):
    path = path.expanduser().absolute()
    check.require(path.name == "OpenCove.app" and not path.is_symlink(), "Bundle output must be a regular OpenCove.app path.")
    path = path.parent.resolve() / path.name
    check.require(not any(p.name == "Applications" for p in path.resolve().parents), "This script does not write into Applications.")
    check.require(not path.exists() or replace, "Bundle output exists; choose a fresh path or explicitly use --replace.")
    check.require(not path.exists() or path.is_dir(), "Bundle output is not a directory.")
    executable = str(path / "Contents/MacOS/OpenCove")
    running = subprocess.run(["pgrep", "-f", "^" + re.escape(executable) + r"( |$)"], capture_output=True, text=True)
    check.require(running.returncode in (0, 1), "Could not check whether the output app is running.")
    check.require(running.returncode == 1, "The output app is running. Quit it or choose an isolated output path before rebuilding.")
    return path


def build(app, arch, configuration, variant, signing, replace=False, scratch=None, manifest=None, tools=None):
    check.version()
    check.require(arch in check.ARCHITECTURES, "Unsupported architecture.")
    check.require(signing != "developer-id" or (variant == "release" and configuration == "release"), "Developer ID mode requires an optimized release bundle.")
    identity, _ = signing_configuration(signing)
    tools = tools or toolchain()
    manifest = manifest or check.source_manifest(allow_dirty=True)
    app = destination(app, replace)
    app.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".opencove-build-", dir=app.parent) as temporary:
        work = Path(temporary)
        # SwiftPM must not observe the caller's unrecorded manifests, linked
        # source directories, .swiftpm configuration, evidence, or build output.
        source = work / "source"
        source.mkdir()
        for entry in manifest["files"]:
            data = check.verified_source_bytes(ROOT, entry)
            path = source / entry["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if entry["executable"] else 0o644)
        value = check.version(source / "version.json")
        check.require(check.source_manifest(allow_dirty=True) == manifest,
                      "Source changed while copying the build snapshot. Retry from a stable checkout.")
        scratch = scratch.expanduser().resolve() if scratch else work / "swift-build"
        check.require(scratch != ROOT / ".build" and not scratch.is_relative_to(app) and
                      not scratch.is_relative_to(source), "Choose an isolated SwiftPM scratch path.")
        binaries = []
        for target in sorted(check.ARCHITECTURES[arch]):
            arguments = ["xcrun", "swift", "build", "--package-path", source, "--scratch-path", scratch / target,
                         "--arch", target, "--configuration", configuration, "--product", "OpenCove"]
            check.run(arguments, cwd=source, stdout=sys.stderr)
            directory = Path(check.output(arguments + ["--show-bin-path"]))
            binaries.append(directory / "OpenCove")
        staged = work / "OpenCove.app"
        executable = staged / "Contents/MacOS/OpenCove"
        resources = staged / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        if len(binaries) == 1:
            shutil.copyfile(binaries[0], executable)
        else:
            check.run(["lipo", "-create", *binaries, "-output", executable])
        executable.chmod(0o755)
        for relative, name in [("LICENSE", "LICENSE"), ("script/OpenCoveMediaAdapter.swift", "OpenCoveMediaAdapter.swift"), ("script/OpenCoveMediaAdapter.js", "OpenCoveMediaAdapter.js")]:
            shutil.copyfile(source / relative, resources / name)
        check.run(["xcrun", "swift", source / "script/make_icon.swift", work / "OpenCove.iconset"], cwd=source, stdout=sys.stderr)
        check.run(["iconutil", "-c", "icns", work / "OpenCove.iconset", "-o", resources / "OpenCove.icns"])
        (resources / "SOURCE_MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        (resources / "SOURCE_NOTICE.txt").write_text(
            "OpenCove is independent software, distributed under the enclosed MIT license.\n"
            "Source and original icon: " + check.REPOSITORY + "\n"
            "The bundled media adapters are independently authored MIT source.\n"
            "No Alcove implementation, assets, executable, or license service is included.\n"
            "Apple system frameworks are provided by macOS and are not redistributed.\n"
            "Optional weather data: Open-Meteo (https://open-meteo.com/), CC BY 4.0\n"
            "(https://creativecommons.org/licenses/by/4.0/); provider service terms also apply.\n"
            "SOURCE_MANIFEST.json records the source commit, dirty state, and file digests.\n"
            "Distribution status: " + signing + "; notarization, if requested, is checked separately.\n")
        info = {
            "CFBundleExecutable": "OpenCove", "CFBundleIdentifier": "org.opencove.OpenCove" + (".dev" if variant == "development" else ""),
            "CFBundleName": "OpenCove", "CFBundleDisplayName": "OpenCove", "CFBundleIconFile": "OpenCove",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": value["version"], "CFBundleVersion": value["build"],
            "OpenCoveVersionLabel": check.label(value), "OpenCoveSourceRevision": manifest["commit"],
            "OpenCoveSourceTreeSHA256": manifest["treeSHA256"], "OpenCoveBuildConfiguration": configuration,
            "LSMinimumSystemVersion": "15.0", "NSPrincipalClass": "NSApplication", "LSUIElement": True,
            "NSHighResolutionCapable": True, "NSHumanReadableCopyright": "Copyright © 2026 OpenCove contributors. MIT License.",
            "NSAppleEventsUsageDescription": "OpenCove can show and control playback in your music apps when you enable this option.",
            "NSCalendarsFullAccessUsageDescription": "OpenCove shows your upcoming calendar events in the notch.",
            "NSLocationUsageDescription": "OpenCove uses a one-time location for weather or calendar travel estimates only when you request it.",
            "NSLocationWhenInUseUsageDescription": "OpenCove uses a one-time location for weather or calendar travel estimates only when you request it.",
            "NSBluetoothAlwaysUsageDescription": "OpenCove can show connected audio devices and their battery status.",
            "NSFocusStatusUsageDescription": "OpenCove shows your shared Focus status in the notch when you allow it.",
            "NSAudioCaptureUsageDescription": "OpenCove can measure system audio for a live waveform when you enable audio capture. It does not record or upload audio.",
            "NSScreenCaptureUsageDescription": "OpenCove can display live system audio levels. The stream measures audio in memory without recording, saving, or uploading screen images or audio.",
            "CFBundleURLTypes": [{"CFBundleURLName": "org.opencove", "CFBundleURLSchemes": ["opencove-dev" if variant == "development" else "opencove"]}],
        }
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        command = ["codesign", "--force", "--sign", identity or "-"]
        if identity:
            entitlements = work / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
            command += ["--options", "runtime", "--timestamp", "--entitlements", entitlements]
        else:
            command += ["--timestamp=none"]
        check.run(command + [staged], stdout=sys.stderr)
        check.bundle(staged, arch, variant, signing, expected_version=value, source_root=source)
        check.require(check.source_manifest(allow_dirty=True) == manifest, "Source changed during the build. Discard this build and retry from a stable checkout.")
        if app.exists():
            # Refuse a running destination again immediately before replacement.
            destination(app, replace=True)
            backup = work / "previous.app"
            app.rename(backup)
            try:
                staged.rename(app)
            except OSError:
                backup.rename(app)
                raise
        else:
            staged.rename(app)
    return tools


def zip_files(destination_path, paths, epoch):
    # Stable ordering, permissions, and source timestamps. Signing timestamps and
    # toolchain output mean signed binaries are not claimed byte-reproducible.
    timestamp = datetime.datetime.fromtimestamp(max(315532800, min(epoch, 4354819198)), datetime.timezone.utc)
    with zipfile.ZipFile(destination_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data, executable in sorted(paths):
            entry = zipfile.ZipInfo(name, timestamp.timetuple()[:6])
            entry.create_system = 3
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)


def package(args):
    value = check.version()
    check.require(not args.notarize or args.signing == "developer-id", "Notarization requires --signing developer-id.")
    identity, profile = signing_configuration(args.signing, args.notarize, args.notary_profile)
    check.require((ROOT / ".git").exists(), "Release packaging requires a clean Git checkout. An extracted source archive supports local builds only.")
    manifest = check.source_manifest()
    tools = toolchain()
    arch = args.arch
    base = f"OpenCove-{check.label(value)}-{arch}-{args.signing}"
    source_base = f"OpenCove-{check.label(value)}-source"
    destination_dir = (args.output_dir or ROOT / "dist/releases" / base).expanduser().absolute()
    check.require(not destination_dir.exists() and not destination_dir.is_symlink(), "Release output already exists. Use a fresh directory.")
    destination_dir.parent.mkdir(parents=True, exist_ok=True)
    epoch = int(check.output(["git", "-C", ROOT, "show", "-s", "--format=%ct", "HEAD"]))
    with tempfile.TemporaryDirectory(prefix=".opencove-package-", dir=destination_dir.parent) as temporary:
        work = Path(temporary)
        artifacts = work / "artifacts"
        artifacts.mkdir()
        app = work / "OpenCove.app"
        # The profile is only for the explicit upload below, never the build.
        saved_profile = os.environ.pop("OPENCOVE_NOTARY_PROFILE", None)
        try:
            build(app, arch, "release", "release", args.signing, manifest=manifest, tools=tools)
        finally:
            if saved_profile is not None:
                os.environ["OPENCOVE_NOTARY_PROFILE"] = saved_profile
        if args.notarize:
            upload = work / "notary-submission.zip"
            check.run(["ditto", "-c", "-k", "--keepParent", app, upload])
            result = json.loads(check.output(["xcrun", "notarytool", "submit", upload, "--keychain-profile", profile, "--wait", "--output-format", "json"]))
            check.require(result.get("status") == "Accepted", "Apple did not accept the notarization submission. No release artifacts were retained.")
            check.run(["xcrun", "stapler", "staple", app])
            check.bundle(app, arch, "release", args.signing, notarized=True)
        zip_files(artifacts / (base + ".zip"), [(str(p.relative_to(work)), p.read_bytes(), bool(p.stat().st_mode & 0o111))
                  for p in app.rglob("*") if p.is_file()], epoch)
        source_archive(artifacts / (source_base + ".zip"), manifest, epoch)
        metadata = {"version": value, "architecture": arch, "signing": args.signing, "notarized": bool(args.notarize),
                    "identity": identity, "source": manifest, "toolchain": tools}
        (artifacts / (base + "-release.json")).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        (artifacts / "SHA256SUMS").write_text("".join(check.digest(p.read_bytes()) + "  " + p.name + "\n" for p in sorted(artifacts.iterdir())))
        check.require(check.source_manifest() == manifest, "Checkout changed during packaging. Retry from a stable checkout.")
        check.artifacts(artifacts)
        artifacts.rename(destination_dir)
    print(destination_dir)


def source_archive(path, manifest, epoch):
    source_base = f"OpenCove-{check.label(check.version())}-source"
    check.require(path.name == source_base + ".zip" and not path.exists() and not path.is_symlink(), "Source ZIP needs its canonical filename and a fresh output path.")
    path.parent.mkdir(parents=True, exist_ok=True)
    files = [(source_base + "/" + entry["path"], check.verified_source_bytes(ROOT, entry), entry["executable"]) for entry in manifest["files"]]
    files.append((source_base + "/SOURCE_MANIFEST.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(), False))
    zip_files(path, files, epoch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    app = commands.add_parser("build", help="Build an ad-hoc local bundle by default; never launches")
    app.add_argument("--configuration", choices=["debug", "release"], default="debug")
    app.add_argument("--variant", choices=["development", "release"], default="development")
    app.add_argument("--output", type=Path, required=True)
    app.add_argument("--scratch-path", type=Path)
    app.add_argument("--replace", action="store_true")
    release = commands.add_parser("package", help="Package a clean committed source tree; never publishes")
    release.add_argument("--output-dir", type=Path)
    release.add_argument("--notarize", action="store_true", help="Explicitly upload the Developer ID app to Apple using a local keychain profile")
    release.add_argument("--notary-profile")
    source = commands.add_parser("source-archive", help="Export allowlisted source; --allow-dirty marks a local preview, not a release")
    source.add_argument("--output", type=Path, required=True)
    source.add_argument("--allow-dirty", action="store_true")
    for command in (app, release):
        command.add_argument("--arch", choices=check.ARCHITECTURES, default=platform.machine())
        command.add_argument("--signing", choices=["adhoc", "developer-id"], default="adhoc")
    args = parser.parse_args()
    if args.command == "source-archive":
        manifest = check.source_manifest(args.allow_dirty)
        epoch = int(check.output(["git", "-C", ROOT, "show", "-s", "--format=%ct", "HEAD"])) if (ROOT / ".git").exists() else 315532800
        source_archive(args.output, manifest, epoch)
        check.require(check.source_manifest(args.allow_dirty) == manifest, "Source changed during export. Discard this archive.")
        print(args.output.absolute())
        return
    check.require(args.arch in check.ARCHITECTURES, "Choose --arch arm64, x86_64, or universal2.")
    if args.command == "build":
        build(args.output, args.arch, args.configuration, args.variant, args.signing, args.replace, args.scratch_path)
        print(args.output.absolute())
    else:
        package(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.CalledProcessError) as error:
        print(f"OpenCove packaging: {error}", file=sys.stderr)
        sys.exit(1)
