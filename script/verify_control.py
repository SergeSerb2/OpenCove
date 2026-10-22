#!/usr/bin/env python3
"""Check the real local app identity; also supplies the CLI's private HTTP client."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import time
import urllib.error
import urllib.request


class ControlFailure(Exception):
    """A safe, user-facing control error. Never include a descriptor or its token."""


def absolute_directory(value):
    raw = os.fspath(value)
    expanded = os.path.expanduser(raw)
    if not raw or "\0" in raw or not os.path.isabs(expanded):
        raise ControlFailure("Use an absolute data directory path.")
    return Path(os.path.normpath(expanded))


def private_directory(directory, *, create=False):
    directory = absolute_directory(directory)
    if create:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(directory_fd)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ControlFailure("The data directory must be owned by you and accessible only to you. Leave existing data in place and set OPENCOVE_DATA_DIR to a new private directory, for example $(mktemp -d /tmp/opencove-dev.XXXXXX).")
        for parent in (directory.parent.resolve(), *directory.parent.resolve().parents):
            parent_info = parent.stat()
            if parent_info.st_uid not in (0, os.geteuid()) or (parent_info.st_mode & 0o022 and not parent_info.st_mode & stat.S_ISVTX):
                raise ControlFailure("The data directory has an unsafe writable ancestor. Choose a directory below your home or a fresh private temporary directory.")
    except BaseException:
        os.close(directory_fd)
        raise
    return directory, directory_fd


def private_descriptor(directory):
    directory, directory_fd = private_directory(directory)
    try:
        descriptor_fd = os.open("control.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory_fd)
        try:
            info = os.fstat(descriptor_fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1
                    or stat.S_IMODE(info.st_mode) & 0o077 or not 0 < info.st_size <= 4096):
                raise ControlFailure("The control descriptor must be a private, owned regular file of at most 4096 bytes.")
            with os.fdopen(descriptor_fd, "rb", closefd=False) as file:
                data = file.read(4097)
            if len(data) != info.st_size:
                raise ControlFailure("The control descriptor changed while reading. Retry.")
        finally:
            os.close(descriptor_fd)
    finally:
        os.close(directory_fd)
    try:
        value = json.loads(data)
        if (not isinstance(value, dict) or type(value.get("port")) is not int or not 1 <= value["port"] <= 65535
                or type(value.get("pid")) is not int or not 1 <= value["pid"] <= 2**31 - 1
                or not isinstance(value.get("token"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{64,256}", value["token"])):
            raise ValueError()
    except (ValueError, TypeError):
        raise ControlFailure("The control descriptor is invalid. Restart the explicitly enabled control server.") from None
    return directory, value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class ControlClient:
    def __init__(self, directory):
        self.directory, self.config = private_descriptor(directory)
        self.base = f"http://127.0.0.1:{self.config['port']}"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path="/state", value=None, *, authenticated=True, headers=None, expected=200, timeout=5):
        if path not in ("/", "/state", "/command") and not path.startswith("/render?surface="):
            raise ControlFailure("Unknown local control endpoint.")
        request_headers = {"Content-Type": "application/json"}
        if authenticated:
            request_headers["X-OpenCove-Token"] = self.config["token"]
        request_headers.update(headers or {})
        body = None if value is None else json.dumps(value, allow_nan=False).encode("utf-8")
        if body is not None and len(body) > 65536:
            raise ControlFailure("The JSON command exceeds 65536 bytes.")
        try:
            response = self.opener.open(urllib.request.Request(self.base + path, data=body, headers=request_headers), timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            code = response.code
            limit = 8 * 1024 * 1024 if path.startswith("/render?") else 2 * 1024 * 1024
            data = response.read(limit + 1)
            if len(data) > limit:
                raise ControlFailure("The local server response exceeds the size limit.")
            content_type = response.headers.get_content_type()
        if code != expected:
            detail = ""
            if content_type == "application/json":
                try:
                    message = json.loads(data).get("error")
                    if isinstance(message, str):
                        detail = ": " + message[:2000]
                except (ValueError, AttributeError):
                    pass
            raise ControlFailure(f"HTTP {code}{detail}")
        if expected != 200 or path == "/":
            return data
        if path.startswith("/render?"):
            if content_type != "image/png" or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ControlFailure("The local server did not return a PNG image.")
            return data
        if content_type != "application/json":
            raise ControlFailure("The local server did not return JSON.")
        try:
            state = json.loads(data)
        except ValueError:
            raise ControlFailure("The local server returned invalid JSON.") from None
        if (not isinstance(state, dict) or state.get("app") != "OpenCove"
                or type(state.get("pid")) is not int or state["pid"] != self.config["pid"]
                or not isinstance(state.get("dataDirectory"), str)
                or Path(state["dataDirectory"]).resolve() != self.directory.resolve()):
            raise ControlFailure("The responding app does not own this data directory and descriptor.")
        return state

    def command(self, action, *, expected=200, **values):
        return self.request("/command", {**values, "action": action}, expected=expected)


def bundle_identity(bundle):
    bundle = Path(bundle).expanduser().resolve(strict=True)
    with (bundle / "Contents/Info.plist").open("rb") as file:
        data = file.read(65537)
    if len(data) > 65536:
        raise ControlFailure("The expected bundle metadata is too large.")
    try:
        info = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException):
        raise ControlFailure("The expected bundle metadata is invalid.") from None
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") not in ("org.opencove.OpenCove", "org.opencove.OpenCove.dev")
            or not isinstance(info.get("OpenCoveSourceTreeSHA256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", info["OpenCoveSourceTreeSHA256"])
            or not (bundle / "Contents/MacOS/OpenCove").is_file()):
        raise ControlFailure("The expected bundle needs its executable and packaged source identity. Rebuild that bundle.")
    return bundle, info


def check_bundle(state, bundle, info, build):
    if (state.get("bundlePath") != str(bundle) or state.get("bundleIdentifier") != info["CFBundleIdentifier"]
            or state.get("sourceTreeSHA256") != info["OpenCoveSourceTreeSHA256"]
            or str(state.get("build")) != str(build) or str(info.get("CFBundleVersion")) != str(build)
            or state.get("version") != info.get("CFBundleShortVersionString")):
        raise ControlFailure("A different or stale app owns the control endpoint. Its bundle path/source identity does not match the expected app. Quit that specific owner or use a fresh data directory and port.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("data_dir", type=Path, nargs="?")
    parser.add_argument("build", nargs="?", help="Expected CFBundleVersion")
    parser.add_argument("bundle", type=Path, nargs="?", help="Exact app bundle that was launched")
    parser.add_argument("--timeout", type=float, default=12)
    parser.add_argument("--prepare-data-dir", type=Path, help="Create a new private data directory, or validate an existing one without changing its permissions")
    args = parser.parse_args()
    if args.prepare_data_dir is not None:
        if any(value is not None for value in (args.data_dir, args.build, args.bundle)):
            parser.error("--prepare-data-dir does not accept readiness arguments")
        try:
            directory, descriptor = private_directory(args.prepare_data_dir, create=True)
            os.close(descriptor)
            print(directory.parent.resolve() / directory.name)
            return 0
        except ControlFailure as error:
            print(f"OpenCove data directory: {error}", file=sys.stderr)
        except OSError:
            print("OpenCove data directory: could not create or safely open that path. Choose a new absolute directory path owned by you; symlinks and non-directories are not accepted.", file=sys.stderr)
        return 1
    if any(value is None for value in (args.data_dir, args.build, args.bundle)):
        parser.error("readiness requires DATA_DIR BUILD EXPECTED_APP_BUNDLE")
    if not 0 < args.timeout <= 60:
        parser.error("--timeout must be greater than zero and at most 60 seconds")
    try:
        bundle, info = bundle_identity(args.bundle)
        if str(info.get("CFBundleVersion")) != args.build:
            raise ControlFailure("The expected bundle build differs from the requested build.")
    except (OSError, ValueError, ControlFailure) as error:
        print(f"OpenCove readiness: {error}", file=sys.stderr)
        return 1
    deadline = time.monotonic() + args.timeout
    failure = "No private control descriptor became available."
    while time.monotonic() < deadline:
        try:
            client = ControlClient(args.data_dir)
            state = client.request(timeout=min(1, max(0.05, deadline - time.monotonic())))
            check_bundle(state, bundle, info, args.build)
            print("OpenCove app and authenticated controls match the expected bundle and source tree.")
            return 0
        except ControlFailure as error:
            failure = str(error)
        except (OSError, ValueError, urllib.error.URLError):
            failure = "The expected local app did not answer. Check its launch error."
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    print(f"OpenCove readiness failed: {failure}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
