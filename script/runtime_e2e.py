#!/usr/bin/env python3
"""Real packaged-app restart/recovery checks. No mocks, desktop input, or grants.

Requires an existing uniquely built development --app. Uses fresh private data
only. --media-fixture explicitly opts into playing/controlling our own silent
MediaPlayer fixture; the default never starts or controls a media player.
Evidence is private and excludes descriptors, tokens, and personal media data.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import selectors
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from verify_control import ControlClient, ControlFailure, bundle_identity, check_bundle

ROOT = Path(__file__).resolve().parent.parent
SAFE = {key: False for key in (
    "enablePrivateAPIs", "enableCalendar", "enableMedia", "allowAppleScript",
    "enableWeather", "showLiveWaveform", "enableHaptics", "enableNotifications",
    "mirrorSystemNotifications", "replaceSystemHUDs", "launchAtLogin",
    "showOnLockScreen", "showLockScreenPrivateContent")}
SAFE.update(completedOnboarding=False, enableFileTray=True, enableTimer=True)
FIXTURE_ID = "org.opencove.MediaFixture"


def require(value, message):
    if not value:
        raise ControlFailure(message)


def write_private(path, data):
    with path.open("xb") as file:
        os.chmod(path, 0o600)
        file.write(data)


def json_bytes(value):
    return json.dumps(value, separators=(",", ":"), allow_nan=False).encode()


def wait_for(read, predicate, message, timeout=12):
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise ControlFailure(message)
        time.sleep(0.15)


def stop(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)


class Runtime:
    def __init__(self, app, evidence):
        self.bundle, self.info = bundle_identity(app)
        require(self.info["CFBundleIdentifier"] == "org.opencove.OpenCove.dev",
                "Use a development bundle; release login-item state is out of scope.")
        self.evidence = evidence
        self.results = []
        self.owners = []
        self.launches = 0
        self.startup_retries = []

    def record(self, flow, **details):
        self.results.append(dict(flow=flow, passed=True, **details))
        self.flush()
        print("PASS " + flow, flush=True)

    def flush(self):
        value = {"bundlePath": str(self.bundle), "sourceTreeSHA256": self.info["OpenCoveSourceTreeSHA256"],
                 "callerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                 "launches": self.launches, "results": self.results, "actualSnapshotOwners": self.owners,
                 "startupRetries": self.startup_retries}
        (self.evidence / "results.json").write_bytes(json_bytes(value))
        (self.evidence / "results.json").chmod(0o600)

    def directory(self, name, *, preferences=None, raw=None):
        path = self.evidence / name
        path.mkdir(mode=0o700)
        write_private(path / "preferences.json", raw if raw is not None else json_bytes(
            SAFE if preferences is None else preferences))
        write_private(path / "activity-settings.json", b'{"nativeNotificationsEnabled":false}')
        return path

    @contextmanager
    def app(self, directory, *, launch_directory=None, initial_port=None):
        # No inherited fixture/data/server controls can select another owner.
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("OPENCOVE_", "ALCOVE_"))}
        environment["OPENCOVE_DATA_DIR"] = str(launch_directory or directory)
        for attempt in range(3):
            self.launches += 1
            if attempt == 0 and initial_port is not None:
                port = initial_port
            else:
                with socket.socket() as reservation:
                    reservation.bind(("127.0.0.1", 0))
                    port = reservation.getsockname()[1]
            log_path = directory / ("app-%02d.log" % self.launches)
            collision = None
            with log_path.open("xb") as log:
                child = subprocess.Popen([str(self.bundle / "Contents/MacOS/OpenCove"),
                                          "--control-port", str(port), "--no-onboarding"],
                                         env=environment, stdout=log, stderr=log, umask=0o077)
                try:
                    deadline = time.monotonic() + 15
                    while True:
                        with log_path.open("rb") as startup_log:
                            startup = startup_log.read(4096).decode("utf-8", errors="replace")
                        if ("OpenCove: Development controls are unavailable:" in startup and
                            ("POSIXErrorCode(rawValue: 48)" in startup or "Address already in use" in startup)
                            and not os.path.lexists(directory / "control.json")):
                            collision = {"pid": child.pid, "port": port, "log": log_path.name,
                                         "reason": "confirmed occupied control port"}
                            self.startup_retries.append(collision)
                            break
                        require(child.poll() is None, "Owned app exited before readiness; see its private app log.")
                        try:
                            client = ControlClient(directory)
                            state = client.request(timeout=1)
                            require(state["pid"] == child.pid, "Another process answered for the owned data directory.")
                            check_bundle(state, self.bundle, self.info, self.info["CFBundleVersion"])
                            self.owners.append({key: state[key] for key in (
                                "pid", "bundlePath", "sourceTreeSHA256", "bundleIdentifier", "build", "dataDirectory")})
                            self.flush()
                            break
                        except (ControlFailure, OSError, urllib.error.URLError):
                            if time.monotonic() >= deadline:
                                raise ControlFailure("Owned app readiness timed out; see its private app log.") from None
                            time.sleep(0.15)
                    if collision is not None:
                        require(attempt < 2, "Owned app exhausted its confirmed occupied-port startup retries.")
                        print("RETRY confirmed occupied control port; stopping owned failed app before relaunch", flush=True)
                        continue
                    yield client
                    return
                finally:
                    stop(child)
                    # Never touch a competing listener. Only this Popen owner
                    # and its private descriptor are retired before a new attempt.
                    (directory / "control.json").unlink(missing_ok=True)
                    if collision is not None:
                        collision["stoppedExitCode"] = child.poll()
                        self.flush()

    def startup_port_collision(self):
        directory = self.directory("startup-port-collision")
        before = len(self.startup_retries)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            occupied = listener.getsockname()[1]
            with self.app(directory, initial_port=occupied) as client:
                require(client.config["port"] != occupied, "A ready app reused the actual occupied listener port.")
                require(len(self.startup_retries) == before + 1 and
                    self.startup_retries[-1].get("stoppedExitCode") is not None,
                    "The owned failed app was not stopped before the successful retry.")
                require(listener.getsockname()[1] == occupied, "Retry changed the independent owned listener.")
        self.record("startup: real occupied listener triggers bounded retry after stopping only the owned failed app")

    def backup(self, directory, pattern, original):
        backups = list(directory.glob(pattern))
        require(len(backups) == 1, "Expected exactly one original recovery backup.")
        require(backups[0].read_bytes() == original, "Recovery backup changed original bytes.")
        require(stat.S_IMODE(backups[0].stat().st_mode) == 0o600, "Recovery backup is not mode 0600.")

    def outline(self):
        """Use real preferences, mounted native rendering and process restarts."""
        directory = self.directory("contrast-outline", preferences={**SAFE, "hideWhenIdle": False,
            "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": True})

        def panels(snapshot):
            return sorted((row for row in snapshot["nativeWindows"] if row["title"] == "OpenCove"
                and not row.get("contentHidden", True)), key=lambda row: row["displayID"])

        def geometry(snapshot):
            return [{key: row[key] for key in ("displayID", "x", "y", "width", "height")}
                    for row in panels(snapshot)]

        # Decode actual mounted PNGs with macOS AppKit, already required by the
        # app. This adds no image-library dependency or substitute renderer.
        pixel_reader = r'''
import AppKit
import Foundation
let paths = Array(CommandLine.arguments.dropFirst())
let images = try paths.map { path -> NSBitmapImageRep in
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let image = NSBitmapImageRep(data: data) else { exit(1) }
    return image
}
guard images.count == 3, let first = images.first,
    images.allSatisfy({ $0.pixelsWide == first.pixelsWide && $0.pixelsHigh == first.pixelsHigh }) else { exit(1) }
let width = first.pixelsWide, height = first.pixelsHigh
guard width >= 80, height >= 16, width * height <= 5_000_000 else { exit(2) }
func rgba(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Double] {
    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { exit(3) }
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}
func differs(_ a: [Double], _ b: [Double]) -> Bool { zip(a,b).contains { abs($0.0 - $0.1) > 3.0 / 255 } }
var changedBorder = 0, changedInterior = 0, restoredBorderMismatch = 0
let insetX = min(40, width / 4), insetY = min(6, height / 4)
for y in 0..<height { for x in 0..<width {
    let a = rgba(images[0],x,y), b = rgba(images[1],x,y), c = rgba(images[2],x,y)
    let interior = x >= insetX && x < width-insetX && y >= insetY && y < height-insetY
    if differs(a,b) { if interior { changedInterior += 1 } else { changedBorder += 1 } }
    if !interior && differs(a,c) { restoredBorderMismatch += 1 }
} }
let result: [String: Any] = ["width":width,"height":height,"changedBorder":changedBorder,
    "changedInterior":changedInterior,"restoredBorderMismatch":restoredBorderMismatch,
    "onBottomRGBA":rgba(images[1],width/2,height-1),
    "systemIncreaseContrast":NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
let data = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
print(String(decoding:data,as:UTF8.self))
'''

        def capture_cycle(client, prefix):
            baseline = geometry(client.request())
            require(bool(baseline), "Outline surface has no mounted panel.")
            for mode, enabled in (("off", False), ("on", True), ("restored", False)):
                client.command("preferences", values={"showContrastOutline": enabled})
                require(geometry(client.request()) == baseline, "Outline changed native panel geometry.")
                write_private(directory / (prefix + "-" + mode + ".png"), client.request("/render?surface=live-notch"))
            pixels = subprocess.run(["xcrun", "swift", "-e", pixel_reader,
                *[str(directory / (prefix + "-" + mode + ".png")) for mode in ("off", "on", "restored")]],
                capture_output=True, text=True, timeout=45)
            require(pixels.returncode == 0, "Actual outline PNG decoding failed: " + pixels.stderr[:1000])
            values = json.loads(pixels.stdout)
            require(values["changedInterior"] == 0 and values["restoredBorderMismatch"] == 0,
                    "Outline changed interior content or failed to restore the original border.")
            if values["systemIncreaseContrast"]:
                require(values["changedBorder"] == 0 and min(values["onBottomRGBA"][:3]) > 0.85,
                        "Increase Contrast did not retain an opaque outline with the preference off.")
            else:
                require(values["changedBorder"] >= values["width"] // 4
                    and min(values["onBottomRGBA"][:3]) > 0.25,
                    "Enabling the outline did not visibly change the mounted native border.")
            write_private(directory / (prefix + "-pixels.json"), json_bytes(values))
            return {"surface": prefix, "geometry": baseline, "pixels": values}

        observations = []
        with self.app(directory) as client:
            state = wait_for(client.request, lambda s: bool(panels(s)), "Outline panel is missing.")
            require(state["preferences"]["showContrastOutline"] is False,
                    "Legacy preferences enabled the optional outline.")
            client.command("timer.start", seconds=180)
            client.command("timer.pause")
            client.command("collapse")
            wait_for(client.request, lambda s: not s["expanded"] and bool(panels(s))
                and all(row["height"] <= 80 for row in panels(s)), "Compact outline surface did not settle.")
            observations.append(capture_cycle(client, "compact"))
            client.command("selectTab", tab="timer")
            wait_for(client.request, lambda s: s["expanded"] and bool(panels(s))
                and all(row["height"] > 150 for row in panels(s)), "Expanded outline did not settle.")
            observations.append(capture_cycle(client, "expanded"))
            client.command("preferences", values={"simulateNotch": True})
            time.sleep(0.2)
            observations.append(capture_cycle(client, "attached-expanded"))
            client.command("collapse")
            wait_for(client.request, lambda s: not s["expanded"] and bool(panels(s))
                and all(row["height"] <= 80 for row in panels(s)), "Attached compact outline did not settle.")
            observations.append(capture_cycle(client, "attached-compact"))
            client.command("preferences", values={"showContrastOutline": True})
            write_private(directory / "appearance.png", client.request("/render?surface=settings-appearance"))
            saved = (directory / "preferences.json").read_bytes()
            for invalid in (1, "true", None):
                client.command("preferences", values={"showContrastOutline": invalid}, expected=400)
                require((directory / "preferences.json").read_bytes() == saved,
                        "Malformed outline input changed saved preferences.")
                require(client.request()["preferences"]["showContrastOutline"] is True,
                        "Malformed outline input changed the live choice.")
            require(json.loads(saved)["showContrastOutline"] is True, "Outline choice was not persisted.")
        with self.app(directory) as client:
            state = client.request()
            require(state["preferences"]["showContrastOutline"] and state["preferences"]["simulateNotch"],
                    "Outline or shape choice did not survive actual process restart.")
            client.command("preferences", values={"showContrastOutline": False})
            require(not client.request()["preferences"]["showContrastOutline"], "Outline did not turn off after restart.")
            client.command("timer.cancel")
        original = json_bytes({**SAFE, "showContrastOutline": "damaged"})
        recovery = self.directory("outline-recovery", raw=original)
        with self.app(recovery) as client:
            state = client.request()
            require(state["preferences"]["showContrastOutline"] is False and state["errors"],
                    "Malformed saved outline choice was not visibly repaired to off.")
            require((recovery / "preferences.json").read_bytes() == original,
                    "Startup overwrote malformed outline preferences.")
            client.command("preferences", values={"showContrastOutline": True})
        self.backup(recovery, "preferences.recovery.*.json", original)
        with self.app(recovery) as client:
            require(client.request()["preferences"]["showContrastOutline"] is True,
                    "Recovered outline choice did not survive restart.")
        write_private(directory / "observations.json", json_bytes(observations))
        self.record("outline: legacy off, compact/expanded/attached pixel restoration, fixed geometry, strict input, recovery backup and restart")

    def shape(self):
        """Exercise the actual panel and renderer; never spoof NSScreen geometry."""
        initial = {**SAFE, "hideWhenIdle": False, "expandOnHover": False,
                   "hideInFullscreen": False, "reduceMotion": True, "animationSpeed": 0.25,
                   "notchWidth": 400, "notchHeight": 64}
        directory = self.directory("notch-shape", preferences=initial)
        samples = []

        def panels(state):
            return sorted((w for w in state["nativeWindows"] if w["title"] == "OpenCove"),
                          key=lambda w: w["displayID"])

        def matches(rows, target):
            return len(rows) == len(target) and bool(rows) and all(a["displayID"] == b["displayID"] and
                all(abs(a[k] - b[k]) <= 1 for k in ("x", "y", "width", "height")) for a, b in zip(rows, target))

        def read(client):
            state = client.request()
            require(state["physicalNotch"] == physical, "Simulation changed reported physical camera dimensions.")
            samples.append({"simulation": state["preferences"]["simulateNotch"], "expanded": state["expanded"],
                            "panels": panels(state)})
            return state

        def settled(client, predicate):
            return wait_for(lambda: read(client), lambda s: bool(panels(s)) and predicate(panels(s)),
                            "Actual notch shape did not settle.", timeout=3)

        with self.app(directory) as client:
            state = wait_for(client.request, lambda s: bool(panels(s)), "Native shape panel is missing.")
            physical = state["physicalNotch"]
            require(state["preferences"]["simulateNotch"] is False, "Legacy preferences did not default to automatic shape.")
            client.command("collapse")
            automatic = panels(settled(client, lambda rows: all(w["height"] <= 65 for w in rows)))
            client.command("preferences", values={"simulateNotch": True})
            if physical["width"] < 368 and min(d["width"] for d in state["displaySelection"]["available"]) > 640:
                state = settled(client, lambda rows: any(a["width"] > b["width"] + 20 for a, b in zip(rows, automatic)))
            else:
                state = read(client)
            simulated = panels(state)
            for row in simulated:
                display = next(d for d in state["displaySelection"]["available"] if d["id"] == row["displayID"])
                require(abs(row["y"] + row["height"] - display["y"] - display["height"]) <= 1,
                        "Simulated notch did not attach to the real screen edge.")
            write_private(directory / "simulated-compact.png", client.request("/render?surface=live-notch"))
            client.command("expand")
            expanded_simulated = panels(settled(client, lambda rows: all(w["height"] > 150 for w in rows)))
            write_private(directory / "simulated-expanded.png", client.request("/render?surface=live-notch"))
            write_private(directory / "appearance.png", client.request("/render?surface=settings-appearance"))
            client.command("preferences", values={"simulateNotch": False})
            expanded_automatic = panels(settled(client, lambda rows: not matches(rows, expanded_simulated))) if physical["height"] < 64 else panels(read(client))
            client.command("preferences", values={"simulateNotch": True, "reduceMotion": False})
            animated = not client.request()["systemReduceMotion"] and not matches(expanded_automatic, expanded_simulated)
            if animated:
                settled(client, lambda rows: not matches(rows, expanded_automatic) and not matches(rows, expanded_simulated))
            client.command("preferences", values={"reduceMotion": True})
            settled(client, lambda rows: matches(rows, expanded_simulated))
            for _ in range(3):
                time.sleep(0.2)
                require(matches(panels(read(client)), expanded_simulated), "A stale transition moved the settled simulated notch.")
            client.command("preferences", values={"notchWidth": 120, "notchHeight": 24})
            client.command("collapse")
            state = settled(client, lambda rows: all(w["height"] < 100 for w in rows))
            require(all(w["width"] >= physical["width"] and w["height"] >= physical["height"] for w in panels(state)),
                    "Small simulated dimensions overlapped the real camera housing.")
            client.command("preferences", values={"notchWidth": 400, "notchHeight": 64})
            settled(client, lambda rows: matches(rows, simulated))
            saved = (directory / "preferences.json").read_bytes()
            client.command("preferences", values={"simulateNotch": "invalid"}, expected=400)
            require((directory / "preferences.json").read_bytes() == saved, "Malformed simulation input changed saved preferences.")
            destination, held = directory / "preferences.json", directory / "held-preferences.json"
            destination.rename(held)
            destination.mkdir(mode=0o700)
            try:
                client.command("preferences", values={"simulateNotch": False}, expected=500)
                state = settled(client, lambda rows: matches(rows, automatic))
                require(state["preferences"]["simulateNotch"] is False and state["errors"] and held.read_bytes() == saved,
                        "Failed shape save hid its runtime choice/error or changed original bytes.")
            finally:
                destination.rmdir()
                held.rename(destination)
        with self.app(directory) as client:
            require(client.request()["preferences"]["simulateNotch"], "Saved simulated shape did not survive restart.")
            settled(client, lambda rows: matches(rows, simulated))
            client.command("preferences", values={"simulateNotch": False})
            settled(client, lambda rows: matches(rows, automatic))
        with self.app(directory) as client:
            require(not client.request()["preferences"]["simulateNotch"], "Automatic shape did not survive restart.")
            settled(client, lambda rows: matches(rows, automatic))
        write_private(directory / "native-shape-observations.json", json_bytes(samples))
        self.record("shape: actual camera-safe geometry, interrupted motion, native capture, save failure and restart",
                    observedAnimation=animated, actualCamera=physical, actualDisplays=len(simulated))

    def activity_selection(self):
        """Read-only native renders must preserve the user's real section choice."""
        preferences = {**SAFE, "enableMedia": True, "enableCalendar": True,
                       "expandedLayout": "calendar", "hideWhenIdle": False,
                       "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": True}
        directory = self.directory("activity-selection", preferences=preferences)
        calendar_policy = b'{"excludedCalendarIdentifiers":"damaged"}'
        write_private(directory / "calendar-settings.json", calendar_policy)
        source = directory / "owned-source.txt"
        write_private(source, b"OpenCove activity-selection verification\n")
        source_bytes = source.read_bytes()
        observations = []

        def selected(client, tab):
            state = wait_for(client.request, lambda s: s["visibleTab"] == tab and
                             (tab is None or s["tab"] == tab), "Visible and selected sections did not agree.")
            observations.append({key: state[key] for key in ("tab", "visibleTab", "enabledTabs", "expanded")})
            return state

        def capture(client, name, tab):
            write_private(directory / (name + ".png"), client.request("/render?surface=notch"))
            state = selected(client, tab)
            require(state["expanded"], "Read-only native capture collapsed the selected section.")
            return state

        with self.app(directory) as client:
            state = selected(client, "calendar")
            require(state["calendarAuthorization"] == "Saved calendar settings need review" and
                    not state["media"]["available"] and not state["preferences"]["enablePrivateAPIs"] and
                    not state["preferences"]["allowAppleScript"],
                    "Selection verification must keep calendar reads paused and player integrations off.")
            require(state["enabledTabs"] == ["media", "calendar", "files", "timer"],
                    "The enabled-section list did not match actual preferences.")
            client.command("files.add", paths=[str(source)])
            client.command("timer.start", seconds=180)
            client.command("timer.pause")
            paused = client.request()["timer"]["remaining"]
            for tab in ("media", "calendar", "files", "timer"):
                client.command("selectTab", tab=tab)
                selected(client, tab)
                capture(client, tab + "-first", tab)
                capture(client, tab + "-remounted", tab)
                client.command("collapse")
                client.command("expand")
                selected(client, tab)
            client.command("preferences", values={"accent": "blue"})
            selected(client, "timer")
            client.command("preferences", values={"expandedLayout": "media"})
            selected(client, "media")
            client.command("selectTab", tab="files")
            client.command("preferences", values={"expandedLayout": "duo"})
            selected(client, "media")
            capture(client, "duo", "media")
            client.command("preferences", values={"expandedLayout": "calendar"})
            selected(client, "calendar")
            client.command("selectTab", tab="media")
            client.command("preferences", values={"expandedLayout": "calendar"})
            # An unchanged default is not a fresh instruction to abandon the
            # user's choice, even when a new native view mounts afterward.
            capture(client, "same-default-explicit-media", "media")

            client.command("selectTab", tab="files")
            client.command("preferences", values={"enableFileTray": False})
            selected(client, "calendar")
            client.command("selectTab", tab="files", expected=409)
            selected(client, "calendar")
            client.command("preferences", values={"enableCalendar": False})
            selected(client, "media")
            client.command("preferences", values={"enableMedia": False})
            selected(client, "timer")
            client.command("preferences", values={"enableTimer": False})
            require(selected(client, None)["enabledTabs"] == [], "Disabled sections remained available.")
            capture(client, "all-disabled", None)
            for tab in ("media", "calendar", "files", "timer"):
                client.command("selectTab", tab=tab, expected=409)
                selected(client, None)
            client.command("selectTab", tab="missing-section", expected=400)
            client.command("preferences", values={"enableFileTray": True})
            selected(client, "files")
            client.command("preferences", values={"enableTimer": True, "enableMedia": True, "enableCalendar": True})
            selected(client, "files")
            state = client.request()
            require(len(state["files"]) == 1 and not state["timer"]["running"] and
                    abs(state["timer"]["remaining"] - paused) < 0.25,
                    "Selection changes lost the tray or paused timer state.")

            destination, held = directory / "preferences.json", directory / "held-preferences.json"
            original = destination.read_bytes()
            destination.rename(held)
            destination.mkdir(mode=0o700)
            try:
                client.command("preferences", values={"expandedLayout": "duo"}, expected=500)
                state = capture(client, "failed-save-runtime-default", "media")
                require(state["errors"] and held.read_bytes() == original,
                        "A failed default-layout save hid its error or replaced the original settings.")
            finally:
                destination.rmdir()
                held.rename(destination)
        with self.app(directory) as client:
            state = selected(client, "calendar")
            require(state["preferences"]["expandedLayout"] == "calendar" and len(state["files"]) == 1 and
                    not state["timer"]["running"] and abs(state["timer"]["remaining"] - paused) < 0.25,
                    "Restart did not apply the persisted default and preserve independent activity state.")
            client.command("timer.cancel")
        require(source.read_bytes() == source_bytes and
                (directory / "calendar-settings.json").read_bytes() == calendar_policy,
                "Section selection changed its source file or paused calendar policy.")
        write_private(directory / "selection-observations.json", json_bytes(observations))
        self.record("activity selection: explicit choices survive native remounts, defaults/fallbacks, failures and restart")

        directory = self.directory("activity-empty", preferences={**SAFE, "enableFileTray": False,
            "enableTimer": False, "expandedLayout": "duo", "hideWhenIdle": False,
            "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": True})
        with self.app(directory) as client:
            state = selected(client, None)
            require(state["enabledTabs"] == [], "Fresh all-disabled startup offered a section.")
            client.command("expand")
            write_private(directory / "empty.png", client.request("/render?surface=notch"))
            selected(client, None)
            client.command("preferences", values={"enableTimer": True})
            selected(client, "timer")
        with self.app(directory) as client:
            state = selected(client, "timer")
            require(state["enabledTabs"] == ["timer"], "Unavailable startup default did not choose the enabled section.")
        self.record("activity selection: real empty startup and available-section fallback survive restart")

    def displays(self):
        """Use real NSScreen discovery and native window placement; no virtual displays."""
        # Deliberately omit selectedDisplayUUID to exercise the legacy file.
        initial = {**SAFE, "showOnAllDisplays": False, "preferBuiltInDisplay": False,
                   "hideWhenIdle": False, "expandOnHover": False, "hideInFullscreen": False,
                   "reduceMotion": True}
        directory = self.directory("display-selection", preferences=initial)
        samples = []

        def settled(client, mode, requested=""):
            def matches(state):
                selection = state["displaySelection"]
                available = selection["available"]
                if not available or selection["mode"] != mode or selection["requestedUUID"] != requested:
                    return False
                primary = next((d for d in available if d["isMain"]), available[0])
                target = ([d for d in available if d.get("uuid") == requested and d["canSelect"]]
                          if mode == "selected" else
                          available if mode == "all" else
                          [next((d for d in available if d["isBuiltIn"]), primary)]
                          if mode == "builtIn" else [primary])
                fallback = mode == "selected" and not target
                if fallback:
                    target = [primary]
                if mode == "builtIn":
                    fallback = not any(d["isBuiltIn"] for d in available)
                if mode == "main":
                    fallback = not any(d["isMain"] for d in available)
                ids = {d["id"] for d in target}
                panels = [w for w in state["nativeWindows"] if w["title"] == "OpenCove"]
                if (set(selection["selectedDisplayIDs"]) != ids or selection["isFallback"] != fallback
                        or len(panels) != len(ids) or {w.get("displayID") for w in panels} != ids):
                    return False
                for panel in panels:
                    display = next(d for d in target if d["id"] == panel["displayID"])
                    if (panel.get("contentHidden", True) or panel["width"] <= 0 or panel["height"] <= 3
                            or panel["x"] < display["x"] - 1 or panel["y"] < display["y"] - 1
                            or panel["x"] + panel["width"] > display["x"] + display["width"] + 1
                            or not -1 <= display["y"] + display["height"] - panel["y"] - panel["height"] <= 7):
                        return False
                return True
            state = wait_for(client.request, matches, "Display policy and actual native placement did not agree.")
            samples.append({"selection": state["displaySelection"], "panels": [w for w in state["nativeWindows"]
                            if w["title"] == "OpenCove"]})
            return state

        with self.app(directory) as client:
            state = settled(client, "main")
            require(state["preferences"]["selectedDisplayUUID"] == "" and not state["errors"],
                    "A legacy display preference file was not read without repair.")
            for mode in ("builtIn", "all", "main"):
                client.command("display.select", choice=mode)
                settled(client, mode)
            available = state["displaySelection"]["available"]
            selectable = [d["uuid"] for d in available if d["canSelect"]]
            require(selectable, "No real display has a unique identity for saved-choice verification.")
            for identity in selectable:
                client.command("display.select", choice=identity)
                settled(client, "selected", identity)
            selected = selectable[-1]
            saved = (directory / "preferences.json").read_bytes()
            for action, values in (("display.select", {"choice": "invalid-display"}),
                                   ("preferences", {"values": {"selectedDisplayUUID": "invalid-display"}})):
                client.command(action, expected=400, **values)
                require((directory / "preferences.json").read_bytes() == saved,
                        "Invalid display input changed saved settings.")
            missing = str(uuid.uuid4()).upper()
            require(missing not in [d.get("uuid") for d in available], "Unavailable-choice UUID unexpectedly exists.")
            client.command("display.select", choice=missing, expected=409)
            settled(client, "selected", selected)
            require((directory / "preferences.json").read_bytes() == saved,
                    "A rejected unavailable display changed saved settings.")
        with self.app(directory) as client:
            settled(client, "selected", selected)
            client.command("preferences", values={"selectedDisplayUUID": missing})
            state = settled(client, "selected", missing)
            require(state["preferences"]["selectedDisplayUUID"] == missing and state["displaySelection"]["status"],
                    "Unavailable saved display did not retain its choice and fallback explanation.")
            write_private(directory / "unavailable-settings.png", client.request("/render?surface=settings"))
        with self.app(directory) as client:
            settled(client, "selected", missing)
            client.command("display.select", choice="all")
            state = settled(client, "all", missing)
            require(state["preferences"]["selectedDisplayUUID"] == missing,
                    "All displays erased the saved individual choice.")
            client.command("preferences", values={"showOnAllDisplays": False})
            settled(client, "selected", missing)
            client.command("preferences", values={"selectedDisplayUUID": selected.lower()})
            settled(client, "selected", selected)
        with self.app(directory) as client:
            state = settled(client, "selected", selected)
            require(not state["errors"], "A valid lowercase saved identity was treated as damaged.")
            destination, held = directory / "preferences.json", directory / "held-preferences.json"
            original = destination.read_bytes()
            destination.rename(held)
            destination.mkdir(mode=0o700)
            try:
                client.command("display.select", choice="main", expected=500)
                state = settled(client, "main")
                require(state["errors"] and held.read_bytes() == original,
                        "Failed display save hid its error or replaced original settings.")
                write_private(directory / "save-error-settings.png", client.request("/render?surface=settings"))
            finally:
                destination.rmdir()
                held.rename(destination)
        with self.app(directory) as client:
            settled(client, "selected", selected)
            client.command("display.select", choice="main")
            require(settled(client, "main")["preferences"]["selectedDisplayUUID"] == "",
                    "Choosing Main did not clear the saved identity.")
        with self.app(directory) as client:
            settled(client, "main")
        write_private(directory / "placement.json", json_bytes(samples))
        self.record("displays: real placement, legacy/UUID restart, unavailable fallback and failed-save recovery",
                    actualDisplays=len(available), selectableDisplays=len(selectable), placementSamples=len(samples),
                    multiDisplayObserved=len(available) > 1)

        original = json_bytes({**initial, "selectedDisplayUUID": "damaged"})
        directory = self.directory("display-recovery", raw=original)
        with self.app(directory) as client:
            state = settled(client, "main")
            require(state["preferences"]["selectedDisplayUUID"] == "" and state["errors"],
                    "Malformed saved display did not show a repair notice.")
            require((directory / "preferences.json").read_bytes() == original,
                    "Display repair overwrote the original before saving.")
            for key, value in SAFE.items():
                if value is False:
                    require(state["preferences"][key] is False, "Display repair re-enabled an integration.")
            write_private(directory / "repair-settings.png", client.request("/render?surface=settings"))
            client.command("display.select", choice="all")
            settled(client, "all")
        self.backup(directory, "preferences.recovery.*.json", original)
        with self.app(directory) as client:
            state = settled(client, "all")
            require(state["preferences"]["selectedDisplayUUID"] == "" and not state["errors"],
                    "Repaired display settings did not restart cleanly.")
        self.record("displays: malformed identity repair, opt-outs and byte-exact 0600 backup")

    def motion(self):
        """Exercise the real native panel animator through the authenticated API."""
        directory = self.directory("motion-interruption", preferences={**SAFE, "hideWhenIdle": False,
            "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": True,
            "animationSpeed": 0.25, "collapseDelay": 5})
        samples = []
        started = time.monotonic()

        def panels(state):
            return sorted((w for w in state["nativeWindows"] if w["title"] == "OpenCove"),
                          key=lambda w: (w["x"] + w["width"] / 2, w["y"] + w["height"]))

        def matches(rows, target, *, hidden=False):
            return bool(rows) and len(rows) == len(target) and all(
                row["contentHidden"] == hidden and all(abs(row[key] - goal[key]) <= 1
                    for key in ("x", "y", "width", "height")) for row, goal in zip(rows, target))

        @contextmanager
        def capture_frames():
            try:
                yield
            finally:
                write_private(directory / "native-frames.json", json_bytes(samples))

        with capture_frames(), self.app(directory) as client:
            def read(label):
                state = client.request()
                rows = panels(state)
                require(rows, "The owned app has no visible native panel for motion verification.")
                samples.append({"seconds": time.monotonic() - started, "phase": label,
                                "expanded": state["expanded"], "panels": rows})
                return rows

            def until(predicate, label, timeout=2):
                deadline = time.monotonic() + timeout
                while True:
                    rows = read(label)
                    if predicate(rows):
                        return rows
                    require(time.monotonic() < deadline, "Native motion did not reach " + label + ".")
                    time.sleep(0.01)

            def hold(target, label, *, hidden=False, seconds=0.95):
                deadline = time.monotonic() + seconds
                while True:
                    require(matches(read(label), target, hidden=hidden),
                            "An old native animation changed the settled " + label + " state.")
                    if time.monotonic() >= deadline:
                        return
                    time.sleep(0.025)

            client.command("selectTab", tab="timer")
            client.command("collapse")
            compact = read("compact-calibration")
            client.command("expand")
            expanded = until(lambda rows: all(w["height"] > c["height"] + 20
                for w, c in zip(rows, compact)), "expanded-calibration")
            time.sleep(0.12)
            write_private(directory / "expanded-reference.png", client.request("/render?surface=live-notch"))
            client.command("collapse")
            until(lambda rows: matches(rows, compact), "compact-calibration")
            time.sleep(0.12)
            write_private(directory / "compact-reference.png", client.request("/render?surface=live-notch"))
            animated = not client.request()["systemReduceMotion"]
            interruption_latency = []
            speed_observations = []
            if animated:
                client.command("preferences", values={"reduceMotion": False})
                # Read actual NSWindow geometry at slow, normal and fast speeds.
                # These are caller samples, not display-frame/FPS measurements.
                for speed in (0.5, 1, 2):
                    client.command("preferences", values={"animationSpeed": speed})
                    for action, origin, target in (("expand", compact, expanded), ("collapse", expanded, compact)):
                        client.command(action)
                        began = time.monotonic()
                        previous = origin
                        intermediate = 0
                        captured = False
                        while True:
                            rows = read("speed-%s-%s" % (speed, action))
                            require(len(rows) == len(target), "A moving native panel disappeared.")
                            for row, prior, small, large in zip(rows, previous, compact, expanded):
                                for key in ("width", "height"):
                                    require(small[key] - 1 <= row[key] <= large[key] + 1,
                                            "Native motion exceeded its settled dimensions.")
                                    require(row[key] >= prior[key] - 1 if action == "expand"
                                            else row[key] <= prior[key] + 1,
                                            "Native motion reversed without a new command.")
                                require(abs(row["y"] + row["height"] - small["y"] - small["height"]) <= 1
                                        and abs(row["x"] + row["width"] / 2 - small["x"] - small["width"] / 2) <= 1,
                                        "Native motion moved its top/center anchor.")
                            if not matches(rows, origin) and not matches(rows, target):
                                intermediate += 1
                                if speed == 0.5 and not captured and time.monotonic() - began > 0.15:
                                    write_private(directory / (action + "-in-flight.png"),
                                                  client.request("/render?surface=live-notch"))
                                    captured = True
                            if matches(rows, target):
                                break
                            require(time.monotonic() - began < 2, "A native speed transition did not settle.")
                            previous = rows
                            time.sleep(0.005)
                        require(intermediate > 0, "Native motion jumped directly to its target.")
                        speed_observations.append({"speed": speed, "action": action,
                            "callerObservedSeconds": time.monotonic() - began,
                            "intermediateSamples": intermediate})
                        # Let the separately timed content fade finish before
                        # the next case; capture the real mounted surface too.
                        time.sleep(0.12 / speed)
                        write_private(directory / ("speed-%s-%s.png" % (speed, action)),
                                      client.request("/render?surface=live-notch"))
                client.command("preferences", values={"animationSpeed": 0.25})
                for action, origin, target in (("expand", compact, expanded), ("collapse", expanded, compact)):
                    client.command(action)
                    # Establish actual intermediate geometry, not only a command
                    # acknowledgment or a model's intended animation flag.
                    until(lambda rows: all(min(a["height"], b["height"]) + 2 < w["height"]
                        < max(a["height"], b["height"]) - 2
                        for w, a, b in zip(rows, origin, target)), action + "-moving")
                    time.sleep(0.1)
                    client.command("preferences", values={"reduceMotion": True})
                    interrupted = time.monotonic()
                    until(lambda rows: matches(rows, target), action + "-reduce-motion", timeout=0.2)
                    interruption_latency.append(time.monotonic() - interrupted)
                    write_private(directory / (action + "-reduce-motion.png"),
                                  client.request("/render?surface=live-notch"))
                    hold(target, action + "-settled")
                    client.command("preferences", values={"reduceMotion": False})

                # Retarget several times while the native window is moving.
                for action in ("expand", "collapse", "expand"):
                    client.command(action)
                    deadline = time.monotonic() + 0.12
                    while time.monotonic() < deadline:
                        rows = read("rapid-reversal")
                        require(len(rows) == len(compact), "A native panel vanished during reversal.")
                        for row, small, large in zip(rows, compact, expanded):
                            require(small["height"] - 1 <= row["height"] <= large["height"] + 1
                                and small["width"] - 1 <= row["width"] <= large["width"] + 1
                                and abs(row["y"] + row["height"] - small["y"] - small["height"]) <= 1
                                and abs(row["x"] + row["width"] / 2 - small["x"] - small["width"] / 2) <= 1,
                                "A reversed native animation exceeded its bounds or moved its top/center anchor.")
                        time.sleep(0.01)
                until(lambda rows: matches(rows, expanded), "reversal-expanded")
                client.command("preferences", values={"reduceMotion": True})
                client.command("collapse")
                until(lambda rows: matches(rows, compact), "before-idle-hide")
                client.command("preferences", values={"reduceMotion": False, "hideWhenIdle": True})
                until(lambda rows: all(3 < row["height"] < small["height"] - 1
                    for row, small in zip(rows, compact)), "idle-shrinking")
                client.command("preferences", values={"reduceMotion": True})
                hidden = until(lambda rows: all(row["height"] <= 3 and row["contentHidden"] for row in rows),
                               "idle-reduce-motion", timeout=0.2)
                client.command("expand")
                until(lambda rows: matches(rows, expanded), "restored-content")
                hold(expanded, "restored-content")
                require(all(w["contentHidden"] for w in hidden), "The settled idle surface retained its content.")
            else:
                # Do not alter the user's system accessibility preference.
                client.command("preferences", values={"reduceMotion": False})
                client.command("expand")
                until(lambda rows: matches(rows, expanded), "system-reduced-expand", timeout=0.2)
                client.command("collapse")
                until(lambda rows: matches(rows, compact), "system-reduced-collapse", timeout=0.2)

            client.command("preferences", values={"reduceMotion": True, "hideWhenIdle": False})
            client.command("expand")
            until(lambda rows: matches(rows, expanded), "final-expanded")
            write_private(directory / "expanded.png", client.request("/render?surface=notch"))
            client.command("collapse")
            until(lambda rows: matches(rows, compact), "final-compact")
        with self.app(directory) as client:
            state = client.request()
            require(state["preferences"]["reduceMotion"] and matches(panels(state), compact),
                    "Reduce Motion or native compact geometry did not survive restart.")
        if animated:
            # Decode the actual mounted captures after the app has stopped.
            # Geometry alone cannot catch controls left invisible by a delayed
            # SwiftUI fade when Reduce Motion interrupts the native animator.
            reader = r'''
import AppKit
import Foundation
var counts: [Int] = []
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))),
          image.pixelsWide > 40, image.pixelsHigh > 16 else { exit(1) }
    var count = 0
    for y in 8..<(image.pixelsHigh - 8) {
        for x in 20..<(image.pixelsWide - 20) {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { exit(1) }
            if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.65 && color.alphaComponent > 0.65 {
                count += 1
            }
        }
    }
    counts.append(count)
}
print(String(data: try JSONSerialization.data(withJSONObject: counts), encoding: .utf8)!)
'''
            decoded = subprocess.run(["xcrun", "swift", "-e", reader, *[str(directory / name) for name in (
                "expanded-reference.png", "expand-reduce-motion.png", "compact-reference.png", "collapse-reduce-motion.png")]],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            require(decoded.returncode == 0, "Native interrupted-content PNG decoding failed: " + decoded.stderr[:1000])
            counts = json.loads(decoded.stdout)
            require(counts[0] > 100 and counts[2] > 30 and counts[1] >= counts[0] * 0.85 and counts[3] >= counts[2] * 0.85,
                    "Reduce Motion settled native geometry but left its active controls faded or invisible.")
            write_private(directory / "interrupted-content-pixels.json", json_bytes(counts))
        self.record("motion: native interruption, reversal, hidden-content cleanup and preference restart",
                    observedAnimation=animated, interruptionReadLatencySeconds=interruption_latency,
                    speedObservations=speed_observations,
                    nativeGeometrySamples=len(samples))

    def compact_activity(self):
        directory = self.directory("compact-activity", preferences={**SAFE, "enableCalendar": True,
            "hideWhenIdle": False, "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": True,
            "enableNotifications": True, "hudDuration": 0.5})
        # A real damaged private policy keeps EventKit reads paused. No calendar
        # permission, synthetic event or personal player is needed for fallback.
        write_private(directory / "calendar-settings.json", b'{"excludedCalendarIdentifiers": [42]}')
        observations = []

        def read(client, expected):
            state = wait_for(client.request, lambda s: s["compactActivity"] == expected,
                             "Compact activity did not follow actual availability and preference.")
            require(state["calendarAuthorization"] == "Saved calendar settings need review" and
                    not state["media"]["available"], "Empty compact flow enabled a private data source.")
            observations.append({"choice": state["preferences"]["compactActivity"],
                                 "resolved": state["compactActivity"], "tab": state["visibleTab"],
                                 "expanded": state["expanded"]})
            return state

        with self.app(directory) as client:
            require(read(client, "clock")["preferences"]["compactActivity"] == "automatic",
                    "Legacy preferences did not retain automatic compact switching.")
            for choice in ("media", "calendar", "timer"):
                client.command("preferences", values={"compactActivity": choice})
                read(client, "clock")
            client.command("preferences", values={"compactActivity": "not-an-activity"}, expected=400)
            client.command("timer.start", seconds=180)
            client.command("timer.pause")
            paused = read(client, "timer")["timer"]["remaining"]
            write_private(directory / "timer.png", client.request("/render?surface=notch"))
            client.command("selectTab", tab="files")
            client.command("collapse")
            client.command("compact.open")
            state = read(client, "timer")
            require(state["expanded"] and state["visibleTab"] == "timer",
                    "Opening compact timer did not select the real timer section.")
            client.command("collapse")
            client.command("preferences", values={"enableTimer": False})
            read(client, "clock")
            client.command("preferences", values={"enableTimer": True, "compactActivity": "calendar"})
            read(client, "timer")
            destination = directory / "preferences.json"
            original = destination.read_bytes()
            destination.rename(directory / "held-preferences.json")
            destination.mkdir(mode=0o700)
            try:
                client.command("preferences", values={"compactActivity": "timer"}, expected=500)
                require(read(client, "timer")["preferences"]["compactActivity"] == "timer",
                        "A failed compact preference save discarded the applied session choice.")
            finally:
                destination.rmdir()
                (directory / "held-preferences.json").rename(destination)
            require(destination.read_bytes() == original, "Failed compact save changed the saved settings.")
            client.command("preferences", values={"compactActivity": "calendar"})
            client.command("selectTab", tab="files")
            client.command("collapse")
            client.command("notification.post", title="Owned compact verification", body="Temporary local activity")
            require(client.request()["hud"] is not None, "The real local notification did not create its temporary HUD.")
            client.command("compact.open")
            require(client.request()["visibleTab"] == "files", "Opening a HUD replaced the prior selected section.")
            wait_for(client.request, lambda s: s["hud"] is None, "Temporary HUD did not retire.")
            client.command("collapse")
            read(client, "timer")
            write_private(directory / "settings.png", client.request("/render?surface=settings"))
        with self.app(directory) as client:
            restored = read(client, "timer")
            require(restored["preferences"]["compactActivity"] == "calendar" and
                    abs(restored["timer"]["remaining"] - paused) < 0.25,
                    "Compact choice or paused timer did not survive actual process restart.")
            client.command("timer.cancel")
            read(client, "clock")
            client.command("preferences", values={"hideWhenIdle": True})
            wait_for(client.request, lambda s: any(w.get("contentHidden") is True for w in s["nativeWindows"]),
                     "Unavailable preferred activity kept an otherwise idle panel visible.")
        write_private(directory / "observations.json", json_bytes(observations))
        self.record("compact: legacy/default, real timer, disabled/empty fallback, HUD restoration and restart")

    def compact_dismissal(self):
        directory = self.directory("compact-dismissal", preferences={**SAFE, "hideWhenIdle": False,
            "expandOnHover": False, "hideInFullscreen": False, "reduceMotion": False,
            "enableNotifications": True, "hudDuration": 0.5})
        observations = []

        def read(client, activity):
            state = wait_for(client.request, lambda s: s["compactActivity"] == activity,
                             "Compact dismissal did not select the available activity.")
            observations.append({key: state[key] for key in (
                "compactActivity", "compactActivities", "dismissedCompactActivities", "expanded")})
            return state

        def dismiss(client):
            state = client.request()
            target = state["compactDismissTarget"]
            require(target, "A real compact activity did not offer its dismissal target.")
            preferences = (directory / "preferences.json").read_bytes()
            timer = (directory / "activity-timer.json").read_bytes()
            client.command("compact.dismiss", target=target)
            require((directory / "preferences.json").read_bytes() == preferences and
                    (directory / "activity-timer.json").read_bytes() == timer,
                    "Dismissing presentation wrote preferences or timer state.")
            return target

        with self.app(directory) as client:
            state = read(client, "clock")
            require(state["compactActivities"] == [] and state["compactDismissTarget"] is None
                    and state["compactRestoreTarget"] is None, "An empty clock offered an activity action.")
            for action in ("compact.dismiss", "compact.restore"):
                client.command(action, expected=400)
                client.command(action, target="bad", expected=400)
                client.command(action, target=str(uuid.uuid4()), expected=409)
            client.command("timer.start", seconds=90)
            state = read(client, "timer")
            first = state["compactDismissTarget"]
            time.sleep(1.1)
            require(read(client, "timer")["compactDismissTarget"] == first,
                    "A countdown tick replaced the current activity target.")
            dismiss(client)
            state = read(client, "clock")
            require(state["dismissedCompactActivities"] == ["timer"] and state["timer"]["running"],
                    "Dismissal canceled the real timer or retained its compact presentation.")
            restore = state["compactRestoreTarget"]
            client.command("timer.pause")
            require(read(client, "clock")["compactRestoreTarget"] == restore,
                    "Pause replaced the dismissed timer instance.")
            client.command("timer.resume")
            require(read(client, "clock")["compactRestoreTarget"] == restore,
                    "Resume replaced the dismissed timer instance.")
            client.command("expand")
            client.command("compact.restore", target=restore)
            state = read(client, "timer")
            require(not state["expanded"] and state["timer"]["running"] and not state["dismissedCompactActivities"],
                    "Restore did not bring the real timer forward in compact form.")
            client.command("compact.restore", target=restore, expected=409)
            client.command("compact.dismiss", target=first, expected=409)

            previous = state["compactDismissTarget"]
            client.command("timer.start", seconds=90)
            client.command("compact.dismiss", target=previous, expected=409)
            dismiss(client)
            previous_restore = read(client, "clock")["compactRestoreTarget"]
            client.command("timer.start", seconds=90)
            require(read(client, "timer")["dismissedCompactActivities"] == [],
                    "An earlier dismissal hid a new timer with the same duration.")
            client.command("compact.restore", target=previous_restore, expected=409)
            target = client.request()["compactDismissTarget"]
            client.command("notification.post", title="Owned dismissal verification", body="Temporary HUD")
            client.command("compact.dismiss", target=target, expected=409)
            wait_for(client.request, lambda s: s["hud"] is None, "The real HUD did not retire.")
            require(read(client, "timer")["dismissedCompactActivities"] == [],
                    "A command during a HUD dismissed its underlying activity.")
            target = client.request()["compactDismissTarget"]
            client.command("expand")
            client.command("compact.dismiss", target=target, expected=409)
            require(client.request()["expanded"], "A refused expanded dismissal collapsed the panel.")
            client.command("collapse")

            client.command("preferences", values={"hideWhenIdle": True})
            dismiss(client)
            state = read(client, "clock")
            restore = state["compactRestoreTarget"]
            wait_for(client.request, lambda s: all(w["contentHidden"] and w["height"] <= 3
                     for w in s["nativeWindows"] if w["title"] == "OpenCove")
                     and any(w["title"] == "OpenCove" for w in s["nativeWindows"]),
                     "All-dismissed compact content did not retire at the edge.")
            client.command("compact.restore", target=restore)
            read(client, "timer")
            wait_for(client.request, lambda s: any(not w["contentHidden"] and w["height"] > 3
                     for w in s["nativeWindows"] if w["title"] == "OpenCove"),
                     "Restore did not reveal the real native timer.")
            time.sleep(0.3)
            write_private(directory / "restored-timer.png", client.request("/render?surface=live-notch"))
            client.command("timer.start", seconds=1)
            dismiss(client)
            expired = read(client, "clock")["compactRestoreTarget"]
            state = wait_for(client.request, lambda s: s["timer"]["remaining"] == 0 and s["hud"] is None,
                             "The dismissed real timer did not complete.")
            require(state["compactRestoreTarget"] is None and not state["dismissedCompactActivities"],
                    "A completed timer remained restorable.")
            client.command("compact.restore", target=expired, expected=409)
            client.command("timer.start", seconds=90)
            dismiss(client)
            client.command("preferences", values={"compactActivity": "timer"})
            require(not read(client, "timer")["dismissedCompactActivities"],
                    "An explicit compact preference retained a hidden selection.")
            dismiss(client)
            client.command("preferences", values={"enableTimer": False})
            read(client, "clock")
            client.command("preferences", values={"enableTimer": True})
            read(client, "timer")
            dismiss(client)
        with self.app(directory) as client:
            state = read(client, "timer")
            require(not state["dismissedCompactActivities"] and state["timer"]["running"],
                    "Session-only dismissal persisted or canceled its timer across restart.")
            client.command("timer.cancel")
        write_private(directory / "observations.json", json_bytes(observations))
        self.record("compact dismissal: real timer instance, stale actions, pause/resume, HUD guards, native hide/restore, expiry and restart")

    def preferences(self):
        for name, original in (
            ("field-recovery", json_bytes({**SAFE, "reduceMotion": "damaged", "notchWidth": 999,
                                            "accent": "bad", "enableCalendar": False, "compactActivity": "bad",
                                            "peekOnSongChange": "bad", "mediaPeekDuration": 100})),
            ("whole-recovery", b'{"invalid": [\xff\x00\n')):
            directory = self.directory(name, raw=original)
            with self.app(directory) as client:
                state = client.request()
                for key, value in SAFE.items():
                    if value is False and key not in ("enableNotifications", "enableHaptics"):
                        require(state["preferences"][key] is False, "Recovery re-enabled an integration.")
                require(not state["preferences"]["allowAppleScript"] and state["errors"], "Recovery did not retain opt-out/error.")
                require((directory / "preferences.json").read_bytes() == original, "Startup overwrote damaged preferences.")
                if name == "field-recovery":
                    require(state["preferences"]["notchWidth"] == 400 and not state["preferences"]["reduceMotion"],
                            "Field recovery did not normalize malformed settings.")
                    require(state["preferences"]["compactActivity"] == "automatic",
                            "Field recovery retained an unknown compact activity.")
                    require(not state["preferences"]["peekOnSongChange"] and state["preferences"]["mediaPeekDuration"] == 10,
                            "Field recovery did not disable malformed peek consent or bound its duration.")
                saved = client.command("preferences", values={"reduceMotion": True})
                require(saved["preferences"]["reduceMotion"], "Actual recovery save was not applied.")
            self.backup(directory, "preferences.recovery.*.json", original)
            with self.app(directory) as client:
                restored = client.request()["preferences"]
                require(restored["reduceMotion"] and not restored["enablePrivateAPIs"] and
                        not restored["enableCalendar"] and not restored["enableMedia"],
                        "Recovered settings/opt-outs did not survive restart.")
            self.backup(directory, "preferences.recovery.*.json", original)
            self.record(name + ": real save/restart and byte-exact 0600 original backup")

        directory = self.directory("onboarding-save-failure")
        with self.app(directory) as client:
            destination = directory / "preferences.json"
            original = destination.read_bytes()
            destination.rename(directory / "held-preferences.json")
            destination.mkdir(mode=0o700)
            try:
                client.command("onboarding.complete", expected=500)
                state = client.request()
                require(state["preferences"]["completedOnboarding"] is False and state["errors"],
                        "Failed onboarding save still completed setup.")
            finally:
                destination.rmdir()
                (directory / "held-preferences.json").rename(destination)
            require(destination.read_bytes() == original, "Failed save replaced original settings.")
            # A real development login-registration failure can still write JSON.
            client.command("preferences", expected=500,
                           values={**SAFE, "completedOnboarding": True, "launchAtLogin": True})
            state = client.request()
            require(not state["preferences"]["completedOnboarding"], "Overall save failure completed onboarding.")
            require(not json.loads(destination.read_bytes())["completedOnboarding"], "Failed completion persisted true.")
        with self.app(directory) as client:
            require(not client.request()["preferences"]["completedOnboarding"], "Failed completion survived restart as true.")
            client.command("onboarding.complete")
        with self.app(directory) as client:
            require(client.request()["preferences"]["completedOnboarding"], "Successful completion did not survive restart.")
        self.record("onboarding: failed destination and login saves stay incomplete; retry/restart succeeds")

    def indicators(self):
        # Restored consent must stay dormant when the feature or its view is off.
        # Never enable live capture or ask for permission in this caller.
        for name, media, indicator in (("media-off", False, True), ("indicator-off", True, False)):
            directory = self.directory("indicators-" + name, preferences={**SAFE,
                "enableMedia": media, "showPlaybackIndicator": indicator, "showLiveWaveform": True})
            for restart in range(2):
                with self.app(directory) as client:
                    def dormant(state):
                        wave = state["waveform"]
                        return not any(wave[key] for key in ("enabled", "available", "startAttempts",
                                       "captureActive", "captureStarting", "meterActive"))
                    require(dormant(client.request()), "A disabled feature/view attempted waveform capture at startup.")
                    for value in (True, False, True):
                        client.command("preferences", values={"reduceMotion": value})
                        require(dormant(client.request()), "An unrelated save started dormant waveform capture.")
                    state = client.request()
                    require(state["preferences"]["showPlaybackIndicator"] == indicator
                            and state["preferences"]["showLiveWaveform"], "Saved dormant choices did not survive restart.")
                    if restart == 0:
                        write_private(directory / "settings-media.png", client.request("/render?surface=settings-media"))
                        write_private(directory / "lock.png", client.request("/render?surface=lock"))
        legacy = self.directory("indicators-legacy")
        with self.app(legacy) as client:
            require(client.request()["preferences"]["showPlaybackIndicator"] is True,
                    "A legacy document lost the existing decorative indicator default.")
        raw = json_bytes({**SAFE, "showPlaybackIndicator": "damaged", "showLiveWaveform": True})
        damaged = self.directory("indicators-damaged", raw=raw)
        with self.app(damaged) as client:
            state = client.request()
            require(state["preferences"]["showPlaybackIndicator"] is False
                    and state["waveform"]["startAttempts"] == 0, "Malformed indicator choice enabled capture.")
            client.command("preferences", values={"reduceMotion": True})
            self.backup(damaged, "preferences.recovery.*.json", raw)
        self.record("indicators: dormant saved live choices, repeated saves/restart, legacy default and malformed opt-out recovery")

    def hud_timing(self):
        """Saved per-category timing through the real API and mounted panel."""
        kinds = ("volume", "brightness", "battery", "bluetooth", "focus", "notification", "lock")
        directory = self.directory("hud-timing", preferences={**SAFE, "enableBattery": False,
            "enableBluetooth": False, "enableFocus": False, "enableNotifications": True,
            "enableVolumeHUD": True, "hideWhenIdle": False, "hideInFullscreen": False,
            "expandOnHover": False, "reduceMotion": False, "notchWidth": 200, "notchHeight": 32,
            "hudDuration": 3, "hudSpeed": "smooth"})
        frames = []
        def sample(client, seconds):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                s = client.request()
                frames.append({"time": time.monotonic(), "hud": s["hud"]["kind"] if s["hud"] else None,
                    "remaining": s["hudRemaining"], "panels": [r for r in s["nativeWindows"] if r["title"] == "OpenCove"]})
                time.sleep(0.02)
        with self.app(directory) as client:
            initial = client.request()
            require(all(initial["preferences"][k + "HUDDuration"] == 0 and
                initial["preferences"][k + "HUDSpeed"] == "global" for k in kinds),
                "Legacy preferences did not inherit default overlay timing.")
            client.command("timer.start", seconds=30)
            client.command("timer.pause")
            client.command("selectTab", tab="files")
            client.command("collapse")
            before = client.request()
            require(before["hud"] is None, "Unexpected real event prevents isolated overlay verification.")
            client.command("hud.preview", kind="unknown", expected=400)
            client.command("hud.preview", kind="battery", expected=409)
            require(client.request()["preferences"]["enableBattery"] is False,
                    "Preview enabled a disabled integration.")
            client.command("expand")
            client.command("hud.preview", kind="volume", expected=409)
            client.command("collapse")
            preview = client.command("hud.preview", kind="volume")
            require(preview["hud"]["origin"] == "preview" and "preview" in preview["hud"]["title"]
                and 2.5 < preview["hudRemaining"] <= 3,
                "Labelled volume preview did not inherit the default duration.")
            if preview["system"]["volumeAvailable"]:
                require(preview["hud"].get("value") == preview["system"]["volume"],
                        "Volume preview substituted a value for the cached actual reading.")
            else:
                require(preview["hud"].get("value") is None and "unavailable" in preview["hud"]["subtitle"],
                        "Unavailable volume preview showed a made-up reading.")
            client.command("preferences", values={"hudDuration": 0.5})
            time.sleep(0.65)
            require(client.request()["hud"] is not None, "Saving timing restarted the current captured deadline.")
            client.command("preferences", values={"volumeHUDDuration": 1.5, "volumeHUDSpeed": "fast",
                "notificationHUDDuration": 0.5, "notificationHUDSpeed": "instant"})
            expected = client.request()["preferences"]
            for invalid in ({"volumeHUDDuration": True}, {"volumeHUDDuration": -1},
                            {"volumeHUDDuration": 0.2}, {"volumeHUDDuration": 11},
                            {"notificationHUDSpeed": "slow"}, {"focusHUDSpeed": 1}):
                client.command("preferences", values=invalid, expected=400)
                require(client.request()["preferences"] == expected, "Rejected overlay timing changed preferences.")
            client.command("hud.preview", kind="notification")
            note = client.request()
            require(note["hud"]["subtitle"] == "Preview only · no system notification"
                and note["notifications"] == before["notifications"],
                "Preview posted an activity instead of a labelled presentation.")
            sample(client, 0.16)
            write_private(directory / "notification-preview.png", client.request("/render?surface=live-notch"))
            client.command("hud.preview", kind="volume")
            sample(client, 0.55)
            current = client.request()
            require(current["hud"]["kind"] == "volume" and 0.6 < current["hudRemaining"] < 1.3,
                    "An old notification deadline dismissed its replacement.")
            renewed = client.command("hud.preview", kind="volume")
            require(renewed["hudRemaining"] > current["hudRemaining"] + 0.25,
                    "Repeated preview failed to restart the captured duration.")
            time.sleep(1.1)
            require(client.request()["hud"] is not None, "Old same-category deadline dismissed a repeated overlay.")
            write_private(directory / "volume-preview.png", client.request("/render?surface=live-notch"))
            finished = wait_for(client.request, lambda s: s["hud"] is None, "Overlay failed to retire.", 4)
            require(finished["hudRemaining"] is None and finished["timer"] == before["timer"]
                and finished["files"] == before["files"] and finished["tab"] == before["tab"],
                "Temporary overlay changed the underlying paused timer, files or selection.")
            time.sleep(0.3)
            client.command("preferences", values={"reduceMotion": True})
            client.command("hud.preview", kind="volume")
            sample(client, 0.2)
            write_private(directory / "reduced-preview.png", client.request("/render?surface=live-notch"))
            write_private(directory / "settings.png", client.request("/render?surface=settings-activities"))
            client.command("preferences", values={"enableVolumeHUD": False})
            require(client.request()["hud"] is None, "Disabling an overlay retained its preview.")
            client.command("hud.preview", kind="volume", expected=409)
            client.command("timer.cancel")
        with self.app(directory) as client:
            p = client.request()["preferences"]
            require(p["volumeHUDDuration"] == 1.5 and p["volumeHUDSpeed"] == "fast"
                and p["notificationHUDDuration"] == 0.5 and p["notificationHUDSpeed"] == "instant"
                and not p["enableVolumeHUD"] and not p["enablePrivateAPIs"],
                "Overlay timing or independent consent changed across restart.")
            client.command("preferences", values={"volumeHUDDuration": 0, "volumeHUDSpeed": "global"})
        write_private(directory / "native-frames.json", json_bytes(frames))
        self.record("overlay timing: legacy defaults, strict ranges, read-only previews, repeated/replaced deadlines, native captures and restart")
        replacement = self.directory("hud-replacement", preferences={**SAFE, "enableNotifications": True,
            "enableBattery": False, "enableBluetooth": False, "enableFocus": False,
            "hideWhenIdle": False, "hideInFullscreen": False, "expandOnHover": False,
            "reduceMotion": False, "notchWidth": 200, "notchHeight": 32, "animationSpeed": 0.25,
            "volumeHUDDuration": 3, "volumeHUDSpeed": "smooth",
            "notificationHUDDuration": 0.5, "notificationHUDSpeed": "instant"})
        def panels(s):
            return sorted([r for r in s["nativeWindows"] if r["title"] == "OpenCove"],
                          key=lambda r: r["displayID"])
        with self.app(replacement) as client:
            time.sleep(0.3)
            client.command("hud.preview", kind="notification")
            time.sleep(0.1)
            target = panels(client.request())
            wait_for(client.request, lambda s: s["hud"] is None, "Calibration overlay did not retire.")
            time.sleep(1)
            client.command("hud.preview", kind="volume")
            time.sleep(0.08)
            during = client.request()
            client.command("hud.preview", kind="notification")
            time.sleep(0.05)
            immediate = client.request()
            require(len(panels(immediate)) == len(target) > 0 and all(
                abs(a[key] - b[key]) <= 1 for a, b in zip(panels(immediate), target)
                for key in ("width", "height", "x", "y")),
                "An instant replacement retained the previous category's native frame animation.")
            write_private(replacement / "native-frames.json", json_bytes({"target": target,
                "during": panels(during), "replacement": panels(immediate)}))
            write_private(replacement / "instant-replacement.png", client.request("/render?surface=live-notch"))
        self.record("overlay replacement: instant category settles an interrupted smooth native transition",
                    observedAnimation=not during["systemReduceMotion"])
        raw = json_bytes({**SAFE, "volumeHUDDuration": "bad", "brightnessHUDSpeed": "bad",
            "notificationHUDDuration": 20, "focusHUDDuration": True, "hudDuration": 4})
        damaged = self.directory("hud-timing-recovery", raw=raw)
        with self.app(damaged) as client:
            p = client.request()["preferences"]
            require(p["volumeHUDDuration"] == 0 and p["brightnessHUDSpeed"] == "global"
                and p["notificationHUDDuration"] == 10 and p["focusHUDDuration"] == 0
                and p["hudDuration"] == 4 and not p["enablePrivateAPIs"],
                "Damaged per-category fields did not repair independently.")
            client.command("preferences", values={"hudDuration": 3})
            self.backup(damaged, "preferences.recovery.*.json", raw)
        self.record("overlay recovery: exact private original backup and individual timing repair without consent")

    def timer_presentation(self):
        """Real deadline, native-layer progress and no hidden countdown publications."""
        directory = self.directory("timer-presentation", preferences={**SAFE, "enableBattery": False,
            "enableBluetooth": False, "enableFocus": False, "hideWhenIdle": False,
            "expandOnHover": False, "reduceMotion": False, "accent": "mint"})
        captures = []
        with self.app(directory) as client:
            client.command("selectTab", tab="files")
            client.command("expand")
            client.command("timer.start", seconds=40)
            time.sleep(0.5)
            first = client.request()
            time.sleep(1.3)
            later = client.request()
            require(later["timer"]["remaining"] < first["timer"]["remaining"] - 1.1
                and later["timerClock"] == first["timerClock"],
                "Hidden timer froze caller time or kept publishing countdown state.")
            require(not any(r["animationCount"] for r in later["timerProgressMotion"]),
                    "Hidden timer retained native progress motion.")
            client.command("timer.start", seconds=0, expected=400)
            rejected = client.request()
            require(rejected["timer"]["endsAt"] == later["timer"]["endsAt"]
                and rejected["timerClock"] == later["timerClock"],
                "Rejected duration changed the actual timer.")
            client.command("selectTab", tab="timer")
            animated = not first["systemReduceMotion"]
            def rings(state):
                return [r for r in state["timerProgressMotion"] if r["visible"]]
            first = wait_for(client.request, lambda s: rings(s)
                and 0.1 < rings(s)[0]["fraction"] <= 1
                and (not animated or rings(s)[0]["animationCount"] == 1),
                "Actual timer progress did not mount.")
            time.sleep(0.3)
            second = client.request()
            if animated:
                require(rings(second)[0]["fraction"] < rings(first)[0]["fraction"] - 0.002,
                        "Native timer progress jumped or did not advance between second ticks.")
            for name in ("running-first", "running-second"):
                path = directory / (name + ".png")
                write_private(path, client.request("/render?surface=live-notch"))
                captures.append(path)
                time.sleep(1.2 if name == "running-first" else 0)
            after_capture = client.request()
            require(after_capture["timerClock"] == first["timerClock"]
                and (not animated or rings(after_capture)[0]["animationCount"] == 1),
                "Native capture stopped progress or countdown state still published every second.")
            client.command("timer.pause")
            paused = wait_for(client.request, lambda s: rings(s) and rings(s)[0]["animationCount"] == 0,
                              "Paused native timer kept animating.")
            time.sleep(0.4)
            held = client.request()
            require(held["timer"] == paused["timer"]
                and abs(rings(held)[0]["fraction"] - rings(paused)[0]["fraction"]) < 0.00001,
                "Paused timer or ring moved.")
            client.command("timer.resume")
            client.command("preferences", values={"reduceMotion": True})
            reduced = wait_for(client.request, lambda s: rings(s) and rings(s)[0]["animationCount"] == 0,
                               "Reduce Motion left a native timer animation running.")
            require(0 < rings(reduced)[0]["fraction"] < 1, "Reduced progress lost its actual deadline value.")
            client.command("preferences", values={"reduceMotion": False})
            client.command("selectTab", tab="files")
            wait_for(client.request, lambda s: not any(r["animationCount"] for r in s["timerProgressMotion"]),
                     "Leaving Timer retained a progress animation.")
            client.command("timer.start", seconds=1)
            finished = wait_for(client.request, lambda s: not s["timer"]["running"] and s["timer"]["remaining"] == 0,
                                "Hidden absolute timer did not complete.", 5)
            receipts = [n for n in finished["notifications"] if n["source"] == "Timer"]
            require(len(receipts) == 1, "Hidden timer did not record exactly one completion.")
            time.sleep(1.1)
            require([n for n in client.request()["notifications"] if n["source"] == "Timer"] == receipts,
                    "An old deadline repeated timer completion.")
            client.command("timer.start", seconds=30)
            deadline = client.request()["timer"]["endsAt"]
        with self.app(directory) as client:
            restored = client.request()["timer"]
            require(restored["running"] and 0 < restored["remaining"] < 30
                and restored["endsAt"] == deadline,
                "Timer restart changed its saved deadline or failed to derive remaining time.")
            client.command("timer.cancel")
        # Decode real mounted PNGs after the app stops. The icon alone is too
        # small to pass this ring extent check, catching model-only CA captures.
        decoder = r'''
import AppKit
import Foundation
var result: [[String: Int]] = []
var labels: [[UInt8]] = []
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else { exit(1) }
    var minX = image.pixelsWide, maxX = 0, minY = image.pixelsHigh, maxY = 0
    var label: [UInt8] = []
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { exit(1) }
            if x >= image.pixelsWide / 3 {
                let rgb = [c.redComponent, c.greenComponent, c.blueComponent]
                label.append(c.alphaComponent > 0.5 && rgb.max()! > 0.5 && rgb.max()! - rgb.min()! < 0.1 ? 1 : 0)
                continue
            }
            if c.alphaComponent > 0.5 && c.greenComponent - c.redComponent > 0.1
                && c.greenComponent - c.blueComponent > 0.08 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    result.append(["width": maxX - minX, "height": maxY - minY])
    labels.append(label)
}
if labels.count == 2 { result[1]["labelChanged"] = labels[0] != labels[1] ? 1 : 0 }
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
        decoded = subprocess.run(["xcrun", "swift", "-e", decoder, *map(str, captures)],
                                 text=True, capture_output=True, timeout=60)
        require(decoded.returncode == 0, "Actual timer PNG decoding failed: " + decoded.stderr[:1000])
        pixels = json.loads(decoded.stdout)
        write_private(directory / "ring-pixels.json", json_bytes(pixels))
        require(len(pixels) == 2 and all(p["width"] > 70 and p["height"] > 70 for p in pixels),
                "Mounted native capture omitted actual running progress.")
        require(pixels[1]["labelChanged"] == 1, "Mounted countdown label stopped updating without service ticks.")
        self.record("timer presentation: no hidden publications, actual native progress, pause/resume, reduced motion, capture, completion and restart",
                    observedAnimation=animated)

    def timers(self):
        directory = self.directory("timer-restart")
        with self.app(directory) as client:
            started = client.command("timer.start", seconds=9)["timer"]
        with self.app(directory) as client:
            restored = client.request()["timer"]
            require(restored["running"] and restored["endsAt"] == started["endsAt"], "Restart replaced the running deadline.")
            paused = client.command("timer.pause")["timer"]
        time.sleep(0.4)
        with self.app(directory) as client:
            restored = client.request()["timer"]
            require(not restored["running"] and abs(restored["remaining"] - paused["remaining"]) < 0.05,
                    "Paused remaining time changed across process restart.")
            client.command("timer.start", seconds=2)
        time.sleep(2.2)
        with self.app(directory) as client:
            state = wait_for(client.request, lambda s: not s["timer"]["running"] and s["timer"]["remaining"] == 0,
                             "Overdue timer did not finish after process restart.")
            require(any(n["title"] == "Timer finished" for n in state["notifications"]),
                    "Overdue timer did not report completion through activity notification.")
        self.record("timer: running deadline, pause persistence, completion while process stopped")

    def timer_corruption(self):
        directory = self.directory("timer-corruption")
        original = b'{"running":true,"duration":-9,"remaining":-2,"endsAt":1}\n'
        write_private(directory / "activity-timer.json", original)
        with self.app(directory) as client:
            state = client.request()
            require(not state["timer"]["running"] and state["timer"]["remaining"] == 0,
                    "Corrupt timer was restored as active.")
            require(any("timer" in e.lower() for e in state["errors"]), "Corrupt timer recovery is invisible.")
            require((directory / "activity-timer.json").read_bytes() == original, "Startup overwrote corrupt timer.")
            repaired = client.command("timer.start", seconds=30)
            require(repaired["timer"]["running"] and repaired["timer"]["duration"] == 30,
                    "Successful timer recovery did not publish its running timer.")
            require(any("activity-timer.json" in notice and "preserved" in notice for notice in repaired.get("notices", [])),
                    "Successful timer recovery did not expose a separate notice.")
            for surface in ("settings", "onboarding"):
                write_private(directory / (surface + ".png"), client.request("/render?surface=" + surface))
            client.command("timer.cancel")
        self.backup(directory, "activity-timer.json.recovery.*", original)
        with self.app(directory) as client:
            require(client.request()["timer"]["remaining"] == 0, "Repaired timer failed restart.")
        self.record("timer: corrupt persisted input safely recovers and keeps exact private backup")

    def calendar(self):
        directory = self.directory("calendar-dangling-link", preferences={**SAFE, "enableCalendar": True})
        link = directory / "calendar-settings.json"
        target = directory / "never-created-calendar-target.json"
        link.symlink_to(target)
        with self.app(directory) as client:
            state = client.request()
            require(not state["events"] and not state.get("calendarActivity"), "Paused calendar exposed events.")
            require(any("Calendar reads are paused" in e for e in state["errors"]), "Dangling policy did not pause calendar recovery.")
            client.command("calendar.refresh")
            require(not client.request()["events"], "Calendar refresh bypassed recovery pause.")
        require(link.is_symlink() and not target.exists(), "Calendar recovery changed the symlink/target.")
        self.record("calendar: dangling policy link pauses real reads without an authorization request")

    def weather(self):
        """Opt-in, live provider flow. Uses public city coordinates, never device location."""
        directory = self.directory("weather-service", preferences={**SAFE, "enableWeather": True})
        location_file = directory / "weather-location.json"

        def loaded(client, name, zone):
            state = wait_for(client.request, lambda s: s["weather"]["available"]
                             and s["weather"]["locationName"] == name,
                             "The real weather provider did not supply the selected city; inspect private app log/state.", 35)
            weather = state["weather"]
            require(weather["timeZoneIdentifier"] == zone, "Provider time zone does not match the public city.")
            require(len(weather["hourly"]) == 24 and len(weather["daily"]) == 7, "Live forecast is incomplete.")
            require(not weather.get("forecastNotice"), "Live forecast contains unavailable fields.")
            dates = [datetime.fromisoformat(day["date"].replace("Z", "+00:00")).astimezone(ZoneInfo(zone)).date()
                     for day in weather["daily"]]
            require(all(b == a + timedelta(days=1) for a, b in zip(dates, dates[1:])),
                    "Forecast civil dates skipped or repeated across a timezone/DST boundary.")
            require(all(hour["temperature"] is not None and math.isfinite(hour["temperature"])
                        and 0 <= hour["precipitationProbability"] <= 100 for hour in weather["hourly"]),
                    "Live hourly values are unavailable or outside their physical bounds.")
            require(not state["weatherStatus"]["requestingLocation"], "Manual coordinates requested device location.")
            return state

        def presentation(client, name):
            """Independent time/interval checks on actual provider-backed app state."""
            baseline = client.request()["weatherStatus"]["requestAttempts"]
            for style in ("conditions", "precipitation", "sun"):
                client.command("preferences", values={"weatherStyle": style})
                state = client.request()
                weather, widget = state["weather"], state["weatherPresentation"]
                require(state["preferences"]["weatherStyle"] == style and widget["style"] == style,
                        "Saved style and the native weather presentation disagree.")
                require(state["weatherStatus"]["requestAttempts"] == baseline,
                        "Changing the weather presentation queued another provider request.")
                now = datetime.fromisoformat(widget["asOf"].replace("Z", "+00:00"))
                zone = ZoneInfo(weather["timeZoneIdentifier"])
                def instant(value):
                    return datetime.fromisoformat(value.replace("Z", "+00:00"))
                today = next((day for day in weather["daily"]
                              if instant(day["date"]).astimezone(zone).date() == now.astimezone(zone).date()), None)
                require(widget.get("today") == today, "Widget selected a day in the host timezone instead of the city timezone.")
                hours = [hour for hour in weather["hourly"] if instant(hour["date"]) + timedelta(hours=1) > now][:3]
                probability_hours = [hour for hour in weather["hourly"] if instant(hour["date"]) > now][:3]
                require(widget["hours"] == hours and widget["precipitationHours"] == probability_hours,
                        "Widget's bounded hours do not cover the actual current/next intervals.")
                current = next((hour for hour in probability_hours
                                if instant(hour["date"]) - timedelta(hours=1) <= now < instant(hour["date"])), None)
                chance, period = None, None
                if current is not None and current.get("precipitationProbability") is not None:
                    chance, period = current["precipitationProbability"], "hour"
                elif today is not None and today.get("precipitationProbability") is not None:
                    chance, period = today["precipitationProbability"], "day"
                require(widget.get("precipitationProbability") == chance and widget.get("precipitationPeriod") == period,
                        "Precipitation chance does not use the hour ending at the provider timestamp.")
                events = sorted((instant(day[kind]), kind) for day in weather["daily"] for kind in ("sunrise", "sunset")
                                if day.get(kind) and instant(day[kind]) > now)
                actual = widget.get("nextSunEvent")
                require((not events and actual is None) or (events and actual is not None and
                        instant(actual["date"]) == events[0][0] and actual["kind"] == events[0][1]),
                        "Widget selected a past or incorrect next sun event.")
                rise, setting = (today.get("sunrise"), today.get("sunset")) if today else (None, None)
                duration = today.get("daylightDuration") if today else None
                expected_sun = "continuousDaylight" if duration == 86400 else "continuousNight" if duration == 0 else \
                               "events" if rise or setting else "unavailable"
                require(widget.get("sunCondition") == expected_sun,
                        "Solar presentation does not match the provider's actual daylight duration.")
                if rise and setting and instant(setting) > instant(rise):
                    span = (instant(setting) - instant(rise)).total_seconds()
                    progress = min(1, max(0, (now - instant(rise)).total_seconds() / span))
                    require(abs(widget["daylightProgress"] - progress) <= 2 / span and
                            widget["isDaylight"] == (instant(rise) <= now < instant(setting)),
                            "Daylight progress or its day/night state disagrees with the actual forecast.")
                else:
                    daylight = True if duration == 86400 else False if duration == 0 else None
                    require(widget.get("daylightProgress") is None and widget.get("isDaylight") is daylight,
                            "Missing sun data produced a fabricated daylight position.")
                stem = name.lower() + "-" + style
                write_private(directory / (stem + ".json"), json_bytes({"weather": weather, "presentation": widget,
                              "requestAttempts": baseline, "sourceTreeSHA256": state["sourceTreeSHA256"]}))
                for surface in ("weather", "lock", "settings-weather"):
                    write_private(directory / (stem + "-" + surface + ".png"), client.request("/render?surface=" + surface))
                original_surface = state["preferences"]["nowPlayingStyle"]
                client.command("preferences", values={"nowPlayingStyle": "frosted"})
                try:
                    write_private(directory / (stem + "-lock-frosted.png"), client.request("/render?surface=lock"))
                    require(client.request()["weatherStatus"]["requestAttempts"] == baseline,
                            "Changing the lock surface queued a weather request.")
                finally:
                    client.command("preferences", values={"nowPlayingStyle": original_surface})
            return baseline

        with self.app(directory) as client:
            empty = client.request()
            require(not empty["weatherStatus"]["hasLocation"] and not empty["weather"]["available"],
                    "Weather requested a location without an explicit selection.")
            for style in ("conditions", "sun", "precipitation"):
                client.command("preferences", values={"weatherStyle": style})
                blank = client.request()
                require(blank["weatherStatus"]["requestAttempts"] == 0 and not blank["weatherStatus"]["requestingLocation"]
                        and not blank["weatherPresentation"]["hours"] and not blank["weatherPresentation"]["precipitationHours"]
                        and blank["weatherPresentation"].get("nextSunEvent") is None
                        and blank["weatherPresentation"].get("precipitationProbability") is None,
                        "A style without a location fetched weather or fabricated a value.")
            client.command("weather.location", expected=400, latitude=91, longitude=0)
            require(not location_file.exists(), "Invalid coordinates were saved.")
            client.command("weather.location", latitude=49.28, longitude=-123.12, name="Vancouver")
            state = loaded(client, "Vancouver", "America/Vancouver")
            require(stat.S_IMODE(location_file.stat().st_mode) == 0o600
                    and json.loads(location_file.read_bytes())["consented"], "Saved weather consent is not private.")
            write_private(directory / "weather.png", client.request("/render?surface=weather"))
            write_private(directory / "lock.png", client.request("/render?surface=lock"))
            presentation(client, "Vancouver")
            client.command("weather.location", latitude=52.52, longitude=13.405, name="Berlin")
            loaded(client, "Berlin", "Europe/Berlin")
            write_private(directory / "berlin.png", client.request("/render?surface=weather"))
            presentation(client, "Berlin")
        with self.app(directory) as client:
            loaded(client, "Berlin", "Europe/Berlin")
            require(client.request()["preferences"]["weatherStyle"] == "sun"
                    and client.request()["weatherPresentation"]["style"] == "sun", "Weather style did not survive restart.")
            polar_conditions = []
            for city, latitude in (("South Pole", -89.99), ("North Pole", 89.99)):
                client.command("weather.location", latitude=latitude, longitude=0, name=city)
                polar = wait_for(client.request, lambda s: s["weather"]["available"] and s["weather"]["locationName"] == city,
                                 "The actual polar provider did not return conditions.", 35)
                presentation(client, city)
                polar = client.request()
                today = polar["weatherPresentation"].get("today")
                require(today is not None and today.get("daylightDuration") is not None,
                        "The live polar response lacks a usable daylight duration.")
                condition = polar["weatherPresentation"]["sunCondition"]
                if today["daylightDuration"] in (0, 86400):
                    require(today.get("sunrise") is None and today.get("sunset") is None
                            and polar["weatherPresentation"].get("daylightProgress") is None,
                            "Polar midnight boundaries became fabricated sunrise/set events or a daylight arc.")
                polar_conditions.append(condition)
            client.command("preferences", values={**SAFE, "enableWeather": False})
            client.command("weather.refresh", expected=409)
            stopped = client.request()
            require(not stopped["weatherStatus"]["loading"] and not stopped["weatherStatus"]["requestingLocation"],
                    "Weather opt-out retained an active request.")
            client.command("weather.clear")
            require(not location_file.exists() and not client.request()["weather"]["available"],
                    "Clear retained saved location or current conditions.")
            # Exercise synchronous remove failure through the real command path.
            location_file.mkdir(mode=0o700)
            client.command("weather.clear", expected=500)
            require(location_file.is_dir(), "Failed clear removed a directory.")
            location_file.rmdir()
            target = directory / "absent-location-target"
            location_file.symlink_to(target)
            client.command("weather.clear")
            require(not location_file.is_symlink() and not target.exists(), "Clear followed or retained a dangling link.")
        with self.app(directory) as client:
            empty = client.request()
            require(not empty["weatherStatus"]["hasLocation"] and not empty["weather"]["available"],
                    "Removed weather selection returned after restart.")
            write_private(directory / "empty.png", client.request("/render?surface=weather"))
            require(empty["weatherStatus"]["requestAttempts"] == 0
                    and empty["weatherPresentation"].get("nextSunEvent") is None
                    and empty["weatherPresentation"].get("precipitationProbability") is None,
                    "Removed weather kept a sun event/chance or restarted a provider request.")
        self.record("weather: real 24-hour/7-day provider, city/timezone change, restart, opt-out and clear failures",
                    provider="Open-Meteo", publicCities=["Vancouver", "Berlin"], deviceLocationRequested=False)
        self.record("weather: actual conditions/sun/precipitation views, correct intervals, no extra fetch on style changes and saved choice")
        self.record("weather: real polar daylight duration suppresses false midnight sun events",
                    publicCoordinates=[[-89.99, 0], [89.99, 0]], observedSolarConditions=polar_conditions)

    def files(self):
        directory = self.directory("tray-restart")
        sources = self.evidence / "owned-source-files"
        sources.mkdir(mode=0o700)
        paths = []
        for number in range(1026):
            path = sources / ("source-%04d.txt" % number)
            write_private(path, ("OpenCove source %d\n" % number).encode())
            paths.append(str(path))
        digests = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in paths}
        with self.app(directory) as client:
            first = client.command("files.add", paths=paths[:1])["files"]
            persisted_entry = json.loads((directory / "activity-tray.json").read_bytes())[0]
            require(client.command("files.add", paths=paths[:1])["files"] == first, "Actual file import failed deduplication.")
            client.command("files.add", paths=[str(sources / "missing")], expected=400)
            tray = directory / "activity-tray.json"
            tray.rename(directory / "held-tray.json")
            tray.mkdir(mode=0o700)
            try:
                messages = []
                for _ in range(2):
                    client.command("files.add", paths=paths[1:2], expected=500)
                    failed = client.request()
                    require(failed["files"] == first, "Failed tray save published an unsaved import.")
                    message = next((e for e in failed["errors"] if "activity-tray.json" in e), None)
                    require(message is not None, "Real tray save failure did not publish its diagnostic.")
                    messages.append(message)
                require(messages[0] == messages[1], "Repeated persistence failure did not preserve its same-text diagnostic.")
                succeeded = client.command("timer.start", seconds=30)
                require(succeeded["timer"]["running"] and messages[-1] in succeeded["errors"],
                        "Unrelated success was failed by, or erased, the previous activity diagnostic.")
                client.command("timer.cancel")
            finally:
                tray.rmdir()
                (directory / "held-tray.json").rename(tray)
            for start in range(1, 1023, 100):
                client.command("files.add", paths=paths[start:min(start + 100, 1023)])
            previous = client.request()["files"]
            require(len(previous) == 1023, "Real imports did not reach 1023 files.")
            saved = tray.read_bytes()
            client.command("files.add", paths=paths[1023:1025], expected=500)
            require(client.request()["files"] == previous and tray.read_bytes() == saved,
                    "Cross-limit import did not preserve the complete previous tray.")
            full = client.command("files.add", paths=paths[1023:1024])["files"]
            require(len(full) == 1024, "The documented tray capacity was not reachable.")
            require(len(client.command("files.add", paths=paths[:1])["files"]) == 1024,
                    "Duplicate repair failed at capacity.")
            saved = tray.read_bytes()
            client.command("files.add", paths=paths[1024:1025], expected=500)
            require(tray.read_bytes() == saved, "Refused capacity import changed saved tray.")
        with self.app(directory) as client:
            state = client.request()
            require(len(state["files"]) == 1024 and all(f["isAvailable"] for f in state["files"]),
                    "Real bookmarks/files failed process restart.")
            removed = state["files"][0]["id"]
            require(len(client.command("files.remove", id=removed)["files"]) == 1023, "Real tray removal failed.")
            require(not client.command("files.clear")["files"], "Real tray clear failed.")
        require(all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in digests.items()),
                "Tray operation changed an owned source file.")
        self.record("files: real add/deduplication, 1024 limit, rejected batch/save, bookmark restart, remove/clear preserve sources")

        # Real startup input with a damaged oversized bookmark, pointing only at
        # our real file. The API deliberately omits bookmark bytes from /state.
        # Keep the complete saved document just below the 16 MiB read bound.
        directory = self.directory("tray-byte-bound")
        limit = 16_777_216
        persisted_entry["bookmarkData"] = ""
        overhead = len(json_bytes([persisted_entry]))
        persisted_entry["bookmarkData"] = "A" * (((limit - overhead - 512) // 4) * 4)
        original = json_bytes([persisted_entry])
        write_private(directory / "activity-tray.json", original)
        with self.app(directory) as client:
            previous = client.request()["files"]
            require(len(previous) == 1, "Bounded damaged-bookmark tray did not load as real startup input.")
            saved = (directory / "activity-tray.json").read_bytes()
            require(len(saved) <= limit, "Startup wrote an oversized tray.")
            client.command("files.add", paths=paths[1:2], expected=500)
            require(client.request()["files"] == previous and (directory / "activity-tray.json").read_bytes() == saved,
                    "Byte-limit rejection changed the previous tray.")
        with self.app(directory) as client:
            require(len(client.request()["files"]) == 1, "Bounded tray was unreadable after rejected import/restart.")
        self.record("files: actual near-16-MiB damaged-bookmark startup rejects ordinary import and remains restart-readable")

        directory = self.directory("tray-unsafe-backup")
        link = directory / "activity-tray.json"
        target = directory / "never-created-tray-target.json"
        link.symlink_to(target)
        with self.app(directory) as client:
            for _ in range(2):
                client.command("files.add", paths=paths[:1], expected=500)
                require(not client.request()["files"] and link.is_symlink() and not target.exists(),
                        "Failed safe backup replaced the damaged tray or published an unsaved import.")
            succeeded = client.command("timer.start", seconds=30)
            require(succeeded["timer"]["running"] and succeeded["errors"],
                    "Previous backup failure made a later successful activity fail or lose diagnostics.")
            client.command("timer.cancel")
        require(not list(directory.glob("activity-tray.json.recovery.*")), "Unsafe input unexpectedly received a followed backup.")
        self.record("files: repeated failed safe backup preserves symlink/target/state; unrelated success remains HTTP 200")

    def temp_alias(self):
        # The documented /tmp path must work as supplied, before canonicalization.
        with tempfile.TemporaryDirectory(prefix="opencove-runtime-", dir="/tmp") as temporary:
            directory = Path(temporary)
            write_private(directory / "preferences.json", json_bytes(SAFE))
            with self.app(directory) as client:
                require(Path(client.request()["dataDirectory"]).resolve() == directory.resolve(),
                        "The /tmp launch selected a different data directory.")
        self.record("documented /tmp private-directory launch reaches the exact packaged app")

    def storage_alias(self):
        routing = self.evidence / "storage-routing"
        routing.mkdir(mode=0o700)
        for name in ("A", "B"):
            (routing / name).mkdir(mode=0o700)
        first = self.directory("storage-routing/A/data")
        second = self.directory("storage-routing/B/data")
        write_private(second / "sentinel.txt", b"OpenCove routing B must stay untouched\n")
        source = routing / "owned-source.txt"
        write_private(source, b"OpenCove routing source must stay unchanged\n")
        source_bytes = source.read_bytes()

        def inventory(directory):
            return {str(path.relative_to(directory)): {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "mode": stat.S_IMODE(path.stat().st_mode)}
                for path in directory.rglob("*") if path.is_file()}

        untouched = inventory(second)
        alias = routing / "current"
        alias.symlink_to(routing / "A", target_is_directory=True)
        with self.app(first, launch_directory=alias / "data") as client:
            before = client.request()
            require(before["dataDirectory"] == str(first.resolve()),
                    "Actual snapshot did not publish the physical locked A directory.")
            require((first / "instance.lock").is_file(), "Physical A has no instance lock.")
            alias.unlink()
            alias.symlink_to(routing / "B", target_is_directory=True)
            require((alias / "data").resolve() == second.resolve(), "Owned intermediate routing alias did not move to B.")
            preferences = client.command("preferences", values={"reduceMotion": True})
            require(preferences["dataDirectory"] == str(first.resolve()), "Preferences command moved the published owner to B.")
            timer = client.command("timer.start", seconds=30)
            files = client.command("files.add", paths=[str(source)])
            require(timer["timer"]["running"] and len(files["files"]) == 1,
                    "Ordinary routing-regression commands did not apply through the actual API.")
            require(json.loads((first / "preferences.json").read_bytes())["reduceMotion"],
                    "Preferences write did not stay in A.")
            require(json.loads((first / "activity-timer.json").read_bytes())["running"],
                    "Timer write did not stay in A.")
            require(len(json.loads((first / "activity-tray.json").read_bytes())) == 1,
                    "File tray write did not stay in A.")
            require(inventory(second) == untouched and not (second / "instance.lock").exists()
                    and not (second / "control.json").exists(), "Retargeted B received app state, instance lock or descriptor.")
            client.command("timer.cancel")
            client.command("files.clear")
        require(inventory(second) == untouched and source.read_bytes() == source_bytes,
                "Routing cleanup changed B or its owned source file.")
        with self.app(first) as client:
            require(client.request()["preferences"]["reduceMotion"], "Pinned A settings did not survive process restart.")
        self.record("storage: actual intermediate alias A-to-B retarget leaves all later writes/lock/control in physical A")

    def media_refresh(self):
        """Exercise the actual stdin wake protocol and owned-app recovery."""
        work, executable, environment = self.build_media_fixture("media-refresh-fixture")
        fixture_state = work / "playing.json"
        child = subprocess.Popen([str(executable), "--state", str(fixture_state)], env=environment,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, umask=0o077)
        try:
            wait_for(fixture_state.exists, bool, "Own media-refresh fixture did not start.")
            adapter = self.bundle / "Contents/Resources/OpenCoveMediaAdapter.js"
            require(adapter.is_file(), "Media refresh requires the packaged JavaScript reader.")

            def own_fixture():
                require(child.poll() is None, "Own media-refresh fixture stopped; no command sent.")
                state = json.loads(fixture_state.read_bytes())
                require(state["pid"] == child.pid, "Own fixture PID changed; no command sent.")
                return state

            def native_source():
                own_fixture()
                result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", str(adapter), "--read"],
                                        env=environment, capture_output=True, timeout=15)
                require(result.returncode == 0, "Native source check failed; no command sent.")
                payload = plistlib.loads(base64.b64decode(json.loads(result.stdout)["snapshot"]))
                require(payload.get("bundleID") == FIXTURE_ID, "Native source changed; no command sent.")

            directory = self.directory("media-refresh", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "reduceMotion": True, "hideWhenIdle": False, "expandOnHover": False,
                "notchWidth": 400, "notchHeight": 56, "showPlaybackIndicator": False})
            observations = []
            captures = []
            with self.app(directory) as client:
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["artworkAvailable"], "Own source did not reach the refresh app.", 25)
                for action in ("media.next", "media.previous", "media.playPause", "media.playPause"):
                    native_source()
                    old = client.request()["media"]
                    before = own_fixture()
                    began = time.monotonic()
                    client.command(action)
                    def changed(state):
                        if state["media"].get("sourceBundleIdentifier") != FIXTURE_ID:
                            return False
                        return (state["media"].get("contentItemIdentifier") != old.get("contentItemIdentifier")
                                if action != "media.playPause" else state["media"]["isPlaying"] != old["isPlaying"])
                    current = wait_for(client.request, changed, "Actual app transport metadata did not update.")
                    actual = own_fixture()
                    require(actual["track"] != before["track"] if action != "media.playPause"
                            else actual["playing"] != before["playing"], "App metadata was not confirmed by the real player.")
                    observations.append({"action": action, "callerObservedSeconds": time.monotonic() - began})
                    if action != "media.playPause":
                        path = directory / (action + "-first.png")
                        write_private(path, client.request("/render?surface=live-notch"))
                        captures.append(path)
                    expected = current["media"]
                    for _ in range(8):
                        time.sleep(0.15)
                        current = client.request()["media"]
                        require(current.get("contentItemIdentifier") == expected.get("contentItemIdentifier")
                            and current["isPlaying"] == expected["isPlaying"], "A stale snapshot undid actual transport state.")

                native_source()
                app_pid = client.request()["pid"]
                helpers = []
                for row in subprocess.check_output(["ps", "-axo", "pid=,ppid=,args="], text=True).splitlines():
                    parts = row.strip().split(None, 2)
                    if len(parts) == 3 and int(parts[1]) == app_pid and str(adapter) in parts[2] and "--watch" in parts[2]:
                        helpers.append(int(parts[0]))
                require(len(helpers) == 1, "Expected exactly one owned reader before the failure check.")
                client.command("media.next")
                time.sleep(0.15)
                os.kill(helpers[0], 9)
                time.sleep(0.5)
                require(client.request()["pid"] == app_pid, "A reader exit or queued refresh stopped the app.")
                client.command("preferences", values={"enableMedia": False})
                client.command("preferences", values={"enableMedia": True})
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["artworkAvailable"], "Own reader did not recover after explicit restart.", 25)
                # Opt-out must clear even a pending outgoing cover immediately.
                client.command("preferences", values={"enableMedia": False})
                path = directory / "optout-immediate.png"
                write_private(path, client.request("/render?surface=live-notch"))
                captures.append(path)
            write_private(directory / "observations.json", json_bytes(observations))
            pixels = r'''
import AppKit
import Foundation
var counts: [Int] = []
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else { exit(1) }
    var colored = 0
    for y in 0..<image.pixelsHigh {
        for x in 0..<(image.pixelsWide / 4) {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { exit(1) }
            let rgb = [c.redComponent, c.greenComponent, c.blueComponent]
            if c.alphaComponent > 0.5 && rgb.max()! - rgb.min()! > 0.2 { colored += 1 }
        }
    }
    counts.append(colored)
}
print(String(data: try JSONSerialization.data(withJSONObject: counts), encoding: .utf8)!)
'''
            decoded = subprocess.run(["xcrun", "swift", "-e", pixels, *map(str, captures)],
                                     text=True, capture_output=True, timeout=60)
            require(decoded.returncode == 0, "Actual media-refresh PNG decoding failed: " + decoded.stderr[:1000])
            counts = json.loads(decoded.stdout)
            write_private(directory / "cover-pixels.json", json_bytes(counts))
            require(len(counts) == 3 and min(counts[:2]) > 0 and counts[2] == 0,
                    "Mounted cover flashed a placeholder or media opt-out retained outgoing artwork.")
            self.record("media refresh: real transport readback, stale-state hold, reader exit during queued refresh and recovery")

            # Drive the real CLI stream directly, including an input EOF. The
            # input can request metadata only; it cannot control the player.
            selector = selectors.DefaultSelector()
            reader = None
            try:
                reader = subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", str(adapter), "--watch"],
                    env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                os.set_blocking(reader.stdout.fileno(), False)
                selector.register(reader.stdout, selectors.EVENT_READ)
                buffer = b""
                def frame():
                    nonlocal buffer
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        require(reader.poll() is None, "Owned CLI reader exited before a complete frame.")
                        if b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            payload = plistlib.loads(base64.b64decode(json.loads(line)["snapshot"]))
                            if payload.get("bundleID") == FIXTURE_ID:
                                return payload
                        for key, _ in selector.select(0.1):
                            chunk = os.read(key.fileobj.fileno(), 65536)
                            require(chunk, "Owned CLI reader closed its output.")
                            buffer += chunk
                            require(len(buffer) <= 23 * 1024 * 1024, "Owned CLI frame exceeded its bound.")
                    raise ControlFailure("Owned CLI reader did not publish a source frame.")
                initial = frame()
                item_key = "kMRMediaRemoteNowPlayingInfoContentItemIdentifier"
                initial_item = initial.get("info", {}).get(item_key)
                require(initial_item, "Owned CLI reader did not identify its initial item.")
                before = own_fixture()
                reader.stdin.write(b"refresh\n" * 100)
                reader.stdin.flush()
                reader.stdin.close()
                time.sleep(0.4)
                unchanged = own_fixture()
                require(unchanged["track"] == before["track"] and unchanged["playing"] == before["playing"],
                        "Metadata-only stdin input changed actual playback.")
                native_source()
                result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", str(adapter),
                    "--next", "--source", FIXTURE_ID], env=environment, capture_output=True, timeout=15)
                require(result.returncode == 0, "Own CLI next was rejected.")
                after = wait_for(own_fixture, lambda f: f["track"] != before["track"], "Own CLI player did not advance.")
                require(after["playing"] == before["playing"], "Metadata refresh input changed real playback.")
                current = wait_for(frame, lambda p: bool(p.get("info", {}).get(item_key))
                    and p["info"][item_key] != initial_item, "Input EOF stopped actual new-item metadata.", 20)
                self.record("media refresh: bounded CLI input, actual player readback and metadata stream after input EOF")
            finally:
                selector.close()
                stop(reader)
        finally:
            stop(child)

    def build_media_fixture(self, name):
        work = self.evidence / name
        work.mkdir(mode=0o700)
        bundle = work / "MediaFixture.app"
        executable = bundle / "Contents/MacOS/MediaFixture"
        executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": FIXTURE_ID, "CFBundleExecutable": "MediaFixture",
            "CFBundleName": "OpenCove Media Fixture", "CFBundlePackageType": "APPL", "LSUIElement": True}))
        with (work / "compile.log").open("wb") as log:
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                            str(ROOT / "script/MediaFixture.swift"), "-o", str(executable)],
                           stdout=log, stderr=log, check=True, timeout=90)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)],
                           stdout=log, stderr=log, check=True, timeout=15)
        environment = {k: v for k, v in os.environ.items() if not k.startswith("OPENCOVE_")}
        return work, executable, environment

    def compact_motion(self):
        """Crossfade actual mounted content at constant native geometry."""
        work, executable, environment = self.build_media_fixture("compact-motion-fixture")
        fixture_state = work / "playing.json"
        child = subprocess.Popen([str(executable), "--state", str(fixture_state)], env=environment,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, umask=0o077)
        try:
            wait_for(fixture_state.exists, bool, "Own compact-motion fixture did not start.")
            directory = self.directory("compact-motion", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "enableBattery": False, "enableBluetooth": False,
                "enableFocus": False, "showPlaybackIndicator": False, "hideWhenIdle": False,
                "expandOnHover": False, "hideInFullscreen": False, "animationSpeed": 0.25,
                "notchWidth": 400, "notchHeight": 56, "reduceMotion": True,
                "peekOnSongChange": False, "enableNotifications": True, "hudDuration": 2})
            samples, captures = [], []
            with self.app(directory) as client:
                def owned():
                    require(child.poll() is None and json.loads(fixture_state.read_bytes())["pid"] == child.pid,
                            "Own compact-motion fixture stopped or changed PID.")
                    state = client.request()
                    if state["preferences"]["enableMedia"]:
                        require(state["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                                "Compact-motion source changed; no player was controlled.")
                    else:
                        require(not state["media"]["available"], "Media opt-out did not clear the source.")
                    return state

                def capture(name):
                    state = owned()
                    rows = [w for w in state["nativeWindows"] if w["title"] == "OpenCove"]
                    require(rows == geometry, "Compact content verification changed native geometry.")
                    samples.append({"capture": name, "seconds": time.monotonic() - began,
                                    "activity": state["compactActivity"], "panels": rows})
                    path = directory / (name + ".png")
                    write_private(path, client.request("/render?surface=live-notch"))
                    captures.append(name)

                def dismiss():
                    client.command("compact.dismiss", target=owned()["compactDismissTarget"])

                def restore():
                    client.command("compact.restore", target=owned()["compactRestoreTarget"])

                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["artworkAvailable"], "Own compact-motion artwork did not become available.", 25)
                client.command("timer.start", seconds=180)
                client.command("timer.pause")
                client.command("collapse")
                time.sleep(0.25)
                state = owned()
                geometry = [w for w in state["nativeWindows"] if w["title"] == "OpenCove"]
                require(geometry, "Compact-motion native panel is missing.")
                # Physical cutouts can force different widths. Do not fabricate a
                # screen or claim a constant-size observation on that topology.
                equal_size = all(w["width"] == 400 and w["height"] == 56 for w in geometry)
                if not equal_size:
                    self.record("compact motion: constant-size capture unavailable on actual display topology",
                                observed=False, geometry=geometry)
                    return
                began = time.monotonic()
                capture("media-reference")
                dismiss()
                capture("timer-reference")
                restore()
                animated = not owned()["systemReduceMotion"]
                if animated:
                    client.command("preferences", values={"reduceMotion": False})
                    for phase, action in (("dismiss", dismiss), ("restore", restore)):
                        action()
                        start = time.monotonic()
                        index = 0
                        while time.monotonic() - start < 0.6:
                            capture("%s-%02d" % (phase, index))
                            index += 1
                            time.sleep(0.02)
                        time.sleep(0.4)
                    dismiss()
                    time.sleep(0.04)
                    client.command("preferences", values={"reduceMotion": True})
                    capture("reduce-on")
                    client.command("preferences", values={"reduceMotion": False})
                    for index in range(8):
                        capture("reduce-off-%d" % index)
                        time.sleep(0.04)
                    restore()
                    time.sleep(1)
                    for _ in range(6):
                        dismiss()
                        time.sleep(0.035)
                        restore()
                        time.sleep(0.035)
                    time.sleep(1)
                    capture("rapid-settled")
                    dismiss()
                    time.sleep(0.04)
                    client.command("preferences", values={"enableMedia": False})
                    capture("optout-immediate")
                    time.sleep(1)
                    capture("optout-settled")
                    client.command("preferences", values={"enableMedia": True, "hudSpeed": "instant"})
                    wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                        and s["artworkAvailable"], "Own compact-motion media did not return.", 25)
                    time.sleep(1)
                    dismiss()
                    time.sleep(0.04)
                    client.command("notification.post", title="Motion verification", body="Own local HUD")
                    capture("instant-hud")
                    time.sleep(0.2)
                    capture("instant-hud-settled")
                    wait_for(client.request, lambda s: s["hud"] is None, "Own compact-motion HUD did not expire.")
                    time.sleep(1)
                    capture("hud-expired")
                current = owned()
                require(current["media"]["isPlaying"] and not current["timer"]["running"]
                    and abs(current["timer"]["remaining"] - 180) < 0.25,
                    "Compact presentation changed actual playback or the paused timer.")
            write_private(directory / "samples.json", json_bytes({"animated": animated, "samples": samples}))
            if animated:
                # Decode actual native captures with AppKit, after stopping the
                # app. Compare RGB bytes; PNG encoding and alpha alone cannot
                # establish a content transition or a correctly settled surface.
                reader = r'''
import AppKit
import Foundation
var result: [[String: Any]] = []
var pixels: [[UInt8]] = []
let paths = Array(CommandLine.arguments.dropFirst())
for path in paths {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else { exit(1) }
    var rgb: [UInt8] = []
    var artwork = 0
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { exit(1) }
            rgb += [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
            // The own fixture's orange cover quadrant. Timer/notification
            // controls cannot contain these actual artwork pixels.
            if x < image.pixelsWide / 4 && c.redComponent > 0.45 && c.greenComponent > 0.2
                && c.blueComponent < 0.35 && c.redComponent > c.blueComponent * 2 { artwork += 1 }
        }
    }
    pixels.append(rgb)
    result.append(["capture": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                   "artworkPixels": artwork])
}
for i in pixels.indices {
    result[i]["equalsMedia"] = pixels[i] == pixels[0]
    result[i]["equalsTimer"] = pixels[i] == pixels[1]
    result[i]["equalsPrevious"] = i > 0 && pixels[i] == pixels[i - 1]
}
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
                decoded = subprocess.run(["xcrun", "swift", "-e", reader,
                    *[str(directory / (name + ".png")) for name in captures]],
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                require(decoded.returncode == 0, "Compact-motion PNG decoding failed: " + decoded.stderr[:1000])
                observations = json.loads(decoded.stdout)
                write_private(directory / "pixel-observations.json", json_bytes(observations))
                by_name = {row["capture"]: row for row in observations}
                require(not by_name["timer-reference"]["equalsMedia"], "Compact references contain identical content.")
                for phase in ("dismiss", "restore"):
                    intermediate = [row for row in observations if row["capture"].startswith(phase + "-")
                        and not row["equalsMedia"] and not row["equalsTimer"] and not row["equalsPrevious"]]
                    require(len(intermediate) >= 2, "Compact " + phase + " jumped without distinct intermediate content.")
                require(all(by_name[name]["equalsTimer"] for name in captures if name.startswith("reduce-")),
                        "Reduce Motion did not settle exact current content or disabling it resumed an old fade.")
                require(by_name["rapid-settled"]["equalsMedia"], "Rapid compact reversals retained stale content.")
                require(by_name["media-reference"]["artworkPixels"] > 0 and
                    by_name["optout-immediate"]["artworkPixels"] == 0 and by_name["optout-settled"]["equalsTimer"],
                    "Media opt-out retained outgoing artwork or failed to settle its replacement.")
                require(by_name["instant-hud-settled"]["equalsPrevious"] and by_name["hud-expired"]["equalsTimer"],
                        "Instant HUD overlapped outgoing content or expiry did not restore the timer.")
            self.record("compact motion: same-size native crossfades, rapid reversal, reduced-motion cancellation, opt-out and instant HUD"
                        if animated else "compact motion: current-content references with system Reduce Motion",
                        animated=animated, captures=len(captures))
        finally:
            stop(child)

    def media(self, pathological=False):
        work, executable, environment = self.build_media_fixture("media-fixture")
        for extra, code in ((["--help"], 0), ([], 2), (["--state", "relative.json"], 2),
                            (["--state", str(work / "invalid.json"), "--metadata-duration", "nan"], 2),
                            (["--state", str(work / "invalid.json"), "--metadata-duration", "-1"], 2),
                            (["--state", str(work / "invalid.json"), "--metadata-style", "unknown"], 2),
                            (["--state", str(work / "invalid.json"), "--explicit-metadata", "--live-metadata"], 2),
                            (["--state", str(work / "invalid.json"), "--explicit-metadata", "--rate-controls"], 2)):
            result = subprocess.run([str(executable), *extra], env=environment, capture_output=True, timeout=5)
            require(result.returncode == code, "Fixture help/default/invalid options did not fail safely before playback.")
        self.record("silent fixture actual CLI: help, absent env, relative path and nonfinite duration safety")

        adapter = self.bundle / "Contents/Resources/OpenCoveMediaAdapter.js"
        runner = ["/usr/bin/osascript", "-l", "JavaScript"]
        if not adapter.is_file():
            adapter = self.bundle / "Contents/Resources/OpenCoveMediaAdapter.swift"
            runner = ["/usr/bin/swift", "-swift-version", "5"]

        def read_adapter(*arguments):
            result = subprocess.run([*runner, str(adapter), *arguments],
                                    capture_output=True, timeout=25)
            # Never persist/print another player's raw metadata.
            payload = plistlib.loads(base64.b64decode(json.loads(result.stdout)["snapshot"]))
            return result.returncode, payload

        def session(name, metadata=None, style=None, rates=False, live=False, explicit=False):
            state_path = work / (name + ".json")
            arguments = [str(executable), "--state", str(state_path)]
            if metadata is not None:
                arguments += ["--metadata-duration", str(metadata)]
            if style is not None:
                arguments += ["--metadata-style", style]
            if rates:
                arguments += ["--rate-controls"]
            if live:
                arguments += ["--live-metadata"]
            if explicit:
                arguments += ["--explicit-metadata"]
            return state_path, subprocess.Popen(arguments, env=environment, stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL, umask=0o077)

        fixture_state, child = session("normal")
        try:
            wait_for(lambda: fixture_state.exists(), bool, "Owned silent fixture did not start.")
            directory = self.directory("media-app", preferences={**SAFE, "enableMedia": True, "enablePrivateAPIs": True})
            write_private(directory / "calendar-settings.json", b'{"excludedCalendarIdentifiers":"damaged"}')
            with self.app(directory) as client:
                def fixture():
                    require(child.poll() is None, "Owned fixture stopped; no media command sent.")
                    value = json.loads(fixture_state.read_bytes())
                    require(value["pid"] == child.pid, "Fixture state PID changed; no media command sent.")
                    return value

                def selected():
                    value = client.request()["media"]
                    require(value.get("sourceBundleIdentifier") == FIXTURE_ID and value.get("available"),
                            "Selected media is not the owned fixture; no media command sent.")
                    require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                            "Current native source is not the owned fixture; no media command sent.")
                    fixture()
                    return value

                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                         "OpenCove did not select the real silent fixture; personal player was not controlled.", 25)
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                         s["media"].get("supportsPlayPause"), "Fixture transport capability not published.")
                state = selected()
                require(not state["supportsPlaybackSpeed"] and not state["supportedPlaybackSpeeds"],
                        "A source without rate controls exposed a speed setter.")
                client.command("media.speed", speed=1.5, expected=409)
                wait_for(client.request, lambda s: s.get("artworkAvailable") and
                         s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                         "Original fixture artwork did not reach the actual app.", 20)
                client.command("selectTab", tab="media")
                write_private(directory / "media-artwork.png", client.request("/render?surface=notch"))
                short = wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2,
                                 "Actual native media labels did not mount.")
                require(all(not row["animating"] for row in short["mediaTextMotion"]),
                        "Short native media text started unnecessary motion.")
                indicator_animated = not short["systemReduceMotion"]
                def indicators(state):
                    return [row for row in state.get("playbackIndicatorMotion", []) if row["visible"]]

                native = wait_for(client.request, lambda s: indicators(s) and
                    all(row["animationCount"] == (5 if indicator_animated else 0)
                        and row["accessibilityLabel"] == "Playing" for row in indicators(s)),
                    "Actual native playback indicator did not appear.")
                time.sleep(1.1)
                advanced = client.request()
                if indicator_animated:
                    require(any(abs(a - b) > 0.1 for a, b in zip(indicators(native)[0]["heights"],
                                indicators(advanced)[0]["heights"])), "Native playback layers did not move.")
                client.command("preferences", values={"reduceMotion": True})
                reduced = wait_for(client.request, lambda s: indicators(s) and
                    all(row["animationCount"] == 0 and row["reduceMotion"] for row in indicators(s)),
                    "Reduced motion did not stop native playback layers.")
                time.sleep(0.25)
                require([r["heights"] for r in indicators(reduced)] ==
                        [r["heights"] for r in indicators(client.request())],
                        "Reduced native playback indicator kept moving.")
                client.command("preferences", values={"showPlaybackIndicator": False, "showLiveWaveform": True})
                disabled = wait_for(client.request, lambda s: not s.get("playbackIndicatorMotion"),
                                    "Indicator off retained native layers in expanded media.")
                require(not any(disabled["waveform"][key] for key in ("enabled", "startAttempts", "captureActive",
                                "captureStarting", "meterActive")), "Off indicator attempted live capture.")
                write_private(directory / "indicator-off-expanded.png", client.request("/render?surface=notch"))
                write_private(directory / "indicator-off-lock.png", client.request("/render?surface=lock"))
                client.command("collapse")
                wait_for(client.request, lambda s: not s.get("playbackIndicatorMotion"),
                         "Indicator off retained native layers in compact media.")
                write_private(directory / "indicator-off-compact.png", client.request("/render?surface=live-notch"))
                client.command("selectTab", tab="media")
                client.command("preferences", values={"showPlaybackIndicator": True, "showLiveWaveform": False})
                wait_for(client.request, lambda s: indicators(s), "Decorative selection did not restore native layers.")
                write_private(directory / "indicator-decorative-lock.png", client.request("/render?surface=lock"))
                write_private(directory / "indicator-settings.png", client.request("/render?surface=settings-media"))
                self.record("media: actual indicator off unmounts expanded/compact layers without capture; decorative/lock presentation restores")
                original_preferences = client.request()["preferences"]

                def indicator_colors(snapshot):
                    return [tuple(round(value, 5) for value in row["rgba"])
                            for row in indicators(snapshot) if len(row.get("rgba", [])) == 4]

                def expanded_media_mounted(snapshot):
                    return (snapshot["expanded"] and snapshot["visibleTab"] == "media"
                        and len([row for row in snapshot["mediaTextMotion"] if row["visible"]]) >= 2
                        and any(row["title"] == "OpenCove" and not row.get("contentHidden", True)
                            and row["height"] > 80 for row in snapshot["nativeWindows"]))

                def compact_media_mounted(snapshot):
                    return (not snapshot["expanded"] and not snapshot["mediaPeekVisible"]
                        and snapshot["compactActivity"] == "media"
                        and not any(row["visible"] for row in snapshot["mediaTextMotion"])
                        and any(row["title"] == "OpenCove" and not row.get("contentHidden", True)
                            and row["height"] <= 80 for row in snapshot["nativeWindows"]))

                client.command("preferences", values={"musicColorAccent": False, "accent": "blue"})
                plain = wait_for(client.request, lambda s: expanded_media_mounted(s)
                    and s["artworkAvailable"] and bool(indicator_colors(s))
                    and all(abs(channel - 1) < 0.01 for color in indicator_colors(s) for channel in color[:3]),
                                 "Own artwork/native fallback color did not settle.")
                plain_colors = indicator_colors(plain)
                color_item = plain["media"]["contentItemIdentifier"]
                write_private(directory / "artwork-color-off-expanded.png", client.request("/render?surface=live-notch"))
                client.command("preferences", values={"musicColorAccent": True})
                colored = wait_for(client.request, lambda s: bool(indicator_colors(s))
                    and indicator_colors(s) != plain_colors,
                    "Enabling artwork color with the same real cover did not update the native layers.")
                artwork_colors = indicator_colors(colored)
                require(colored["artworkAvailable"] and colored["media"]["contentItemIdentifier"] == color_item,
                        "Color-toggle verification must retain the actual item and artwork.")
                write_private(directory / "artwork-color-on-expanded.png", client.request("/render?surface=live-notch"))
                write_private(directory / "artwork-color-lock.png", client.request("/render?surface=lock"))
                client.command("preferences", values={"expandedLayout": "duo", "enableCalendar": True})
                require(client.request()["calendarAuthorization"] == "Saved calendar settings need review",
                        "Color Duo capture must pause calendar queries.")
                write_private(directory / "artwork-color-duo.png", client.request("/render?surface=live-notch"))
                client.command("preferences", values={"expandedLayout": "media", "enableCalendar": False})
                wait_for(client.request, lambda s: expanded_media_mounted(s) and indicator_colors(s) == artwork_colors,
                         "Returning from Duo lost the unchanged cover color.")
                client.command("collapse")
                wait_for(client.request, lambda s: compact_media_mounted(s) and indicator_colors(s) == artwork_colors,
                         "Compact and expanded media did not share the actual cover color.")
                write_private(directory / "artwork-color-on-compact.png", client.request("/render?surface=live-notch"))
                client.command("preferences", values={"musicColorAccent": False})
                compact_plain = wait_for(client.request, lambda s: compact_media_mounted(s)
                    and bool(indicator_colors(s)) and all(color[0] < 0.45 and color[1] > 0.65 and color[2] > 0.85
                        for color in indicator_colors(s)), "Compact did not restore its configured blue/cyan accent.")
                write_private(directory / "artwork-color-off-compact.png", client.request("/render?surface=live-notch"))
                client.command("preferences", values={"musicColorAccent": True})
                wait_for(client.request, lambda s: compact_media_mounted(s) and indicator_colors(s) == artwork_colors,
                         "Compact did not restore the unchanged cover color.")
                client.command("preferences", values={"enableMedia": False})
                require(not client.request()["playbackIndicatorMotion"], "Disabled media retained native playback layers.")
                client.command("preferences", values={"enableMedia": True})
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and compact_media_mounted(s) and s["artworkAvailable"] and indicator_colors(s) == artwork_colors,
                    "Re-enabled media failed to restore its actual cover color.", 25)
                client.command("selectTab", tab="media")
                wait_for(client.request, lambda s: expanded_media_mounted(s) and indicator_colors(s) == artwork_colors,
                         "Expanded media lost its cached color after remount.")
                write_private(directory / "artwork-color-observations.json", json_bytes({
                    "expandedOff": plain_colors, "expandedOn": artwork_colors,
                    "compactOff": indicator_colors(compact_plain), "compactOn": artwork_colors}))
                client.command("preferences", values={"accent": original_preferences["accent"],
                    "musicColorAccent": original_preferences["musicColorAccent"],
                    "expandedLayout": original_preferences["expandedLayout"]})
                self.record("media: real unchanged-cover color toggles, shared native compact/expanded tint, Duo/lock captures and opt-out remount")
                client.command("preferences", values={"reduceMotion": False})
                client.command("selectTab", tab="timer")
                wait_for(client.request, lambda s: not s.get("playbackIndicatorMotion"),
                         "Departed media section retained native playback layers.")
                client.command("selectTab", tab="media")
                wait_for(client.request, lambda s: indicators(s) and
                         all(row["animationCount"] == (5 if indicator_animated else 0) for row in indicators(s)),
                         "Returning media section did not restore its playback indicator.")
                client.command("collapse")
                baseline = client.request()
                before = selected()["elapsed"]
                observed_at = time.monotonic()
                updated = wait_for(client.request, lambda s:
                    s["playbackClock"]["receivedSamples"] - baseline["playbackClock"]["receivedSamples"] >= 3,
                    "Too few actual source samples arrived for clock-observer verification.", 18)
                after = selected()["elapsed"]
                observed_seconds = time.monotonic() - observed_at
                require(abs(after - before - observed_seconds) < 1,
                        "Actual API playback position stopped advancing with the compact panel.")
                samples = updated["playbackClock"]["receivedSamples"] - baseline["playbackClock"]["receivedSamples"]
                notifications = updated["playbackClock"]["changeNotifications"] - baseline["playbackClock"]["changeNotifications"]
                write_private(directory / "clock-observation.json", json_bytes({
                    "before": baseline["playbackClock"], "after": updated["playbackClock"],
                    "elapsedBefore": before, "elapsedAfter": after, "observedSeconds": observed_seconds,
                    "samples": samples, "notifications": notifications}))
                require(samples >= 2 and notifications < samples,
                        "Stable real playback still notified clock observers for every source sample.")
                client.command("selectTab", tab="media")
                # With decorative motion and hardware indicators disabled,
                # render the existing native view, not a newly mounted preview.
                # This checks the real mounted progress schedule independently
                # of /state's always-projected clock.
                client.command("preferences", values={"reduceMotion": True, "enableBattery": False,
                                                       "enableFocus": False, "enableBluetooth": False})
                def live_frame(name):
                    data = client.request("/render?surface=live-notch")
                    require(data.startswith(b"\x89PNG"), "Live native view did not render a PNG.")
                    write_private(directory / (name + ".png"), data)
                    return hashlib.sha256(data).hexdigest()

                time.sleep(0.3)
                playing_first = live_frame("mounted-playing-first")
                time.sleep(1.1)
                require(live_frame("mounted-playing-later") != playing_first,
                        "Actual mounted progress view did not change while playing.")
                client.command("media.playPause")
                wait_for(fixture, lambda s: not s["playing"], "Actual fixture pause was not delivered.")
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                         not s["media"].get("isPlaying"), "The actual app kept stale playing state after pause.")
                paused = selected()["elapsed"]
                wait_for(client.request, lambda s: indicators(s) and
                    all(row["animationCount"] == 0 and row["heights"] == [3] * 5
                        and row["accessibilityLabel"] == "Paused" for row in indicators(s)),
                    "Paused native playback indicator did not settle.")
                time.sleep(0.3)
                paused_frame = live_frame("mounted-paused-first")
                time.sleep(0.75)
                require(abs(selected()["elapsed"] - paused) < 0.25,
                        "Actual paused API playback position kept advancing.")
                require(live_frame("mounted-paused-later") == paused_frame,
                        "Actual mounted paused view kept changing.")
                seek_position = 9 if abs(paused - 9) > 2 else 15
                client.command("media.seek", seconds=seek_position, target=selected()["seekTarget"])
                wait_for(fixture, lambda s: not s["playing"] and abs(s["elapsed"] - seek_position) < 0.25,
                         "Actual paused seek did not reach the fixture.")
                wait_for(client.request, lambda s: not s["media"].get("isPlaying") and
                         abs(s["media"].get("elapsed", -1) - seek_position) < 0.25,
                         "The actual app did not publish the new paused playback position.")
                time.sleep(0.3)
                require(live_frame("mounted-paused-seek") != paused_frame,
                        "Paused seek did not refresh the actual mounted progress view.")
                for surface in ("notch", "lock"):
                    write_private(directory / ("paused-" + surface + ".png"),
                                  client.request("/render?surface=" + surface))
                selected()
                client.command("media.playPause")
                wait_for(fixture, lambda s: s["playing"], "Actual fixture play was not delivered.")
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                         s["media"].get("isPlaying"), "The actual app kept stale paused state after play.")
                resumed_frame = live_frame("mounted-resumed-first")
                time.sleep(1.1)
                require(live_frame("mounted-resumed-later") != resumed_frame,
                        "The paused finite timeline failed to restart the actual mounted progress view.")
                client.command("preferences", values={"reduceMotion": False})
                wait_for(client.request, lambda s: indicators(s) and
                    all(row["animationCount"] == (5 if indicator_animated else 0) for row in indicators(s)),
                    "Native playback layers did not resume.")
                state = wait_for(client.request, lambda s: s["media"].get("supportsSeek"),
                                 "Fixture did not expose safe seek capability.")
                before_playing_seek = selected()
                # Choose a real discontinuity. A fixed target can coincide with
                # normally advancing playback and correctly need no correction.
                playing_seek = 60 if before_playing_seek["elapsed"] < 40 else 15
                clock_before_seek = client.request()["playbackClock"]["changeNotifications"]
                client.command("media.seek", seconds=playing_seek)
                wait_for(fixture, lambda s: playing_seek - 1 <= s["elapsed"] <= playing_seek + 6,
                         "Actual native seek did not reach the fixture.")
                wait_for(client.request, lambda s: s["playbackClock"]["changeNotifications"] > clock_before_seek
                         and playing_seek - 1 <= s["media"]["elapsed"] <= playing_seek + 6,
                         "The real playing seek did not notify progress observers.")
                native = read_adapter("--read")[1]
                require(native.get("bundleID") == FIXTURE_ID, "Fixture lost selection before stale-item check.")
                old_item = native.get("info", {}).get("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")
                require(isinstance(old_item, str) and old_item, "Native fixture has no actual content-item ID.")
                selected()
                old_track = fixture()["track"]
                client.command("media.next")
                wait_for(fixture, lambda s: s["track"] != old_track, "Actual fixture next command was not delivered.")
                expected_title = "OpenCove verification " + str(fixture()["track"])
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                         s["media"].get("title") == expected_title, "The actual app kept the old item after next.")
                observations = []

                def native_transition():
                    current = read_adapter("--read")[1]
                    item = current.get("info", {}).get("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")
                    observations.append({"sourceIsFixture": current.get("bundleID") == FIXTURE_ID,
                                         "itemPresent": isinstance(item, str) and bool(item), "itemChanged": item != old_item})
                    (work / "item-transition-observations.json").write_bytes(json_bytes(observations))
                    return current

                # Public MediaPlayer publication and MediaRemote observation
                # are asynchronous. Wait for the real changed item, never a
                # fixed delay or an assumed identity derived from our title.
                wait_for(native_transition, lambda current: current.get("bundleID") == FIXTURE_ID and
                         isinstance(current.get("info", {}).get("kMRMediaRemoteNowPlayingInfoContentItemIdentifier"), str) and
                         current["info"]["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] not in ("", old_item),
                         "Native current-item identifier did not publish the real fixture track transition.", 15)
                selected()
                code, _ = read_adapter("--seek", "60", "--source", FIXTURE_ID, "--item", old_item)
                require(code != 0 and fixture()["elapsed"] < 30, "Stale native item seek was not rejected.")
                self.record("media: owned real fixture readback, pause/play, normal app seek, next, stale adapter item rejection",
                            metadataBackend=state["media"]["metadataBackend"], originalArtwork=True,
                            compactPlaybackClock=True, pausedSeek=True,
                            nativePlaybackIndicator=indicator_animated, actualMountedProgress=True,
                            stableClockSamples=samples, stableClockNotifications=notifications)
        finally:
            stop(child)

        fixture_state, child = session("playback-rates", rates=True)
        try:
            wait_for(fixture_state.exists, bool, "Rate-capable fixture did not start.")
            directory = self.directory("media-rates", preferences={**SAFE, "enableMedia": True, "enablePrivateAPIs": True})
            with self.app(directory) as client:
                def fixture_rate():
                    require(child.poll() is None, "Own rate fixture stopped; no media command sent.")
                    value = json.loads(fixture_state.read_bytes())
                    require(value["pid"] == child.pid, "Own rate fixture PID changed; no media command sent.")
                    return value

                def owned_rate():
                    value = fixture_rate()
                    require(client.request()["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                            "Rate source changed; no media command sent.")
                    require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                            "Native rate source changed; no media command sent.")
                    return value

                state = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                 and s["media"].get("supportsPlaybackSpeed"), "Actual advertised rates did not reach the app.", 25)
                def rate(speed, expected=200, target=None):
                    target = target or client.request()["media"]
                    require(target["sourceBundleIdentifier"] == FIXTURE_ID, "Rate target is not our fixture.")
                    return client.command("media.speed", speed=speed, source=target["sourceBundleIdentifier"],
                                          item=target["contentItemIdentifier"], expected=expected)
                require(state["media"]["supportedPlaybackSpeeds"] == [0.75, 1, 1.25, 1.5, 2],
                        "App did not use the real source's advertised rates.")
                owned_rate()
                for invalid in (0, -1, 1.1, 17):
                    rate(invalid, expected=400)
                require(owned_rate()["rate"] == 1, "Rejected rate changed actual playback.")
                rate(1.5)
                wait_for(fixture_rate, lambda s: s["rate"] == 1.5, "Rate command did not change actual AVAudioPlayer rate.")
                wait_for(client.request, lambda s: s["media"].get("playbackSpeed") == 1.5,
                         "App did not report the actual changed rate.")
                client.command("selectTab", tab="media")
                write_private(directory / "speed-1.5.png", client.request("/render?surface=notch"))
                before = owned_rate()["elapsed"]
                time.sleep(1)
                require(1 < owned_rate()["elapsed"] - before < 3, "Actual player time did not advance at the chosen rate.")
                client.command("media.playPause")
                wait_for(fixture_rate, lambda s: not s["playing"], "Own rate fixture did not pause.")
                owned_rate()
                rate(0.75)
                wait_for(fixture_rate, lambda s: not s["playing"] and s["rate"] == 0.75,
                         "Changing paused speed started playback or lost the selected rate.")
                wait_for(client.request, lambda s: not s["media"]["isPlaying"] and s["media"].get("playbackSpeed") == 0.75,
                         "Paused source default rate did not reach the app.")
                native = wait_for(lambda: read_adapter("--read")[1], lambda p: p.get("bundleID") == FIXTURE_ID
                                  and bool(p.get("info", {}).get("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")),
                                  "Own native item did not settle before the rate transition.")
                old_item = native["info"]["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]
                old_target = wait_for(client.request, lambda s:
                    s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("contentItemIdentifier") == old_item
                    and s["media"].get("supportedPlaybackSpeeds") == [0.75, 1, 1.25, 1.5, 2],
                    "App and native item did not agree before the rate transition.", 15)["media"]
                owned_rate()
                client.command("media.next")
                # A successful command means submission. Native source/item
                # caches can be temporarily empty during the real transition.
                # Observe our fixture without issuing any further command;
                # repeat strict native ownership checks after it settles.
                wait_for(fixture_rate, lambda s: s["track"] == 2, "Own rate fixture did not change track.")
                wait_for(client.request, lambda s: s["media"].get("supportedPlaybackSpeeds") == [1, 2],
                         "New item's supported rates did not replace old capabilities.")
                new_native = wait_for(lambda: read_adapter("--read")[1], lambda p: p.get("bundleID") == FIXTURE_ID and
                         p.get("info", {}).get("kMRMediaRemoteNowPlayingInfoContentItemIdentifier") not in (None, "", old_item),
                         "Actual new native item did not publish before stale-rate check.", 15)
                # Supported commands can refresh before the watcher's cached
                # item. HTTP 200 means submission, so test HTTP stale rejection
                # only after this app has actually adopted the new native item.
                current = wait_for(client.request, lambda s:
                    s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("contentItemIdentifier") == new_native["info"]["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]
                    and s["media"].get("supportedPlaybackSpeeds") == [1, 2],
                    "App did not adopt the actual changed native item before stale-rate check.", 15)
                write_private(directory / "rate-identity-observation.json", json_bytes({
                    "oldAppMatchedNative": old_target["contentItemIdentifier"] == old_item,
                    "newAppMatchedNative": current["media"]["contentItemIdentifier"] == new_native["info"]["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"],
                    "appItemChanged": current["media"]["contentItemIdentifier"] != old_target["contentItemIdentifier"]}))
                rate(1.5, expected=400)
                rate(2, expected=409, target=old_target)
                owned_rate()
                code, _ = read_adapter("--rate", "2", "--source", FIXTURE_ID, "--item", old_item)
                require(code != 0 and owned_rate()["rate"] == 1, "Stale item rate command was not rejected.")
                self.record("media: actual advertised rates, real speed/paused change, capability refresh and stale-item refusal",
                            metadataBackend=state["media"]["metadataBackend"], rates=[0.75, 1, 1.25, 1.5, 2])
        finally:
            stop(child)

        if pathological:
            fixture_state, child = session("finite-extreme", 1e300)
            try:
                wait_for(lambda: fixture_state.exists(), bool, "Extreme finite fixture did not start.")
                directory = self.directory("media-finite-render", preferences={**SAFE, "enableMedia": True, "enablePrivateAPIs": True})
                with self.app(directory) as client:
                    state = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                     and s["media"].get("duration", 0) > 1e250,
                                     "Extreme finite duration did not reach the actual app snapshot.", 25)
                    require(math.isfinite(state["media"]["duration"]), "Native duration was not finite.")
                    client.command("selectTab", tab="media")
                    for surface in ("notch", "lock"):
                        png = client.request("/render?surface=" + surface)
                        write_private(directory / (surface + ".png"), png)
                    require(client.request()["pid"] > 0, "Actual renderer terminated on finite duration.")
                self.record("media: actual native expanded-notch/lock renderer survives extreme finite duration metadata",
                            publishedDuration=state["media"]["duration"])
            finally:
                stop(child)

        fixture_state, child = session("long-text", style="long")
        try:
            wait_for(lambda: fixture_state.exists(), bool, "Long-text fixture did not start.")
            directory = self.directory("media-text", preferences={**SAFE, "enableMedia": True,
                                       "enablePrivateAPIs": True, "reduceMotion": False,
                                       "expandOnHover": False, "collapseDelay": 5, "enableCalendar": True})
            # Real damaged policy exercises the empty combined layout while
            # ActivityController pauses before any EventKit authorization/read.
            write_private(directory / "calendar-settings.json", b'{"excludedCalendarIdentifiers":"damaged"}')
            with self.app(directory) as client:
                require(client.request()["calendarAuthorization"] == "Saved calendar settings need review",
                        "Combined-layout calendar reads were not paused by the damaged private policy.")
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                         and "long original title" in s["media"].get("title", ""),
                         "Actual long fixture metadata did not reach the app.", 25)
                client.command("selectTab", tab="media")
                state = wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2
                                 and all(row["viewportWidth"] > 1 and row["overflowPoints"] > 1
                                         for row in s["mediaTextMotion"]),
                                 "Long titles/artists did not overflow real native media labels.")
                observed_movement = False
                if not state["systemReduceMotion"]:
                    wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2 and
                             all(row["animating"] for row in s["mediaTextMotion"]),
                             "Visible long media labels did not start their native animations.")
                    moved = wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2 and
                                     all(abs(row["offsetPoints"]) > 2 for row in s["mediaTextMotion"]),
                                     "Native presentation layers did not move for overflowing media text.", 8)
                    observed_movement = True
                    write_private(directory / "moving-layer-state.json", json_bytes(moved["mediaTextMotion"]))
                    state = moved
                initial_width = min(row["viewportWidth"] for row in state["mediaTextMotion"])
                client.command("preferences", values={"expandedLayout": "duo"})
                wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2 and
                         all(0 < row["viewportWidth"] < initial_width - 40 for row in s["mediaTextMotion"]),
                         "Native text viewport did not follow the actual combined layout.")
                write_private(directory / "duo.png", client.request("/render?surface=notch"))
                client.command("preferences", values={"expandedLayout": "media"})
                wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2 and
                         all(abs(row["viewportWidth"] - initial_width) < 1 for row in s["mediaTextMotion"]),
                         "Native text viewport did not restore after leaving the combined layout.")
                client.command("preferences", values={"reduceMotion": True})
                reduced = wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2
                                   and all(not row["animating"] and abs(row["offsetPoints"]) < 0.1
                                           for row in s["mediaTextMotion"]),
                                   "Reduced motion did not stop and reset real native text layers.")
                require("long original title" in reduced["media"]["title"],
                        "Reduced motion changed the actual source title.")
                write_private(directory / "reduced-motion.png", client.request("/render?surface=notch"))
                client.command("selectTab", tab="files")
                wait_for(client.request, lambda s: not s.get("mediaTextMotion"),
                         "Departed media section retained native text views/animations.")
                client.command("preferences", values={"reduceMotion": False})
                client.command("selectTab", tab="media")
                wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2,
                         "Native media labels did not return after section navigation.")
                client.command("collapse")
                wait_for(client.request, lambda s: not s.get("mediaTextMotion"),
                         "Compact panel retained an unused expanded text animation.")
                self.record("media: real long text/native layer movement, reduced-motion reset, section/collapse cleanup",
                            nativeMovementObserved=observed_movement,
                            systemReduceMotion=state["systemReduceMotion"])
        finally:
            stop(child)

        fixture_state, child = session("oversized-text", style="oversized")
        try:
            wait_for(lambda: fixture_state.exists(), bool, "Oversized-text fixture did not start.")
            directory = self.directory("media-text-bounds", preferences={**SAFE, "enableMedia": True,
                                       "enablePrivateAPIs": True, "reduceMotion": False})
            with self.app(directory) as client:
                source = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                  and s["media"].get("title", "").startswith("OpenCove oversized verification"),
                                  "Actual oversized source metadata did not reach the app.", 25)
                require(len(source["media"]["title"]) > 10_000,
                        "The real source did not supply oversized metadata for this check.")
                source_lengths = {len(source["media"][key].encode("utf-16-le")) // 2 for key in ("title", "artist")}
                client.command("selectTab", tab="media")
                bounded = wait_for(client.request, lambda s: len(s.get("mediaTextMotion", [])) >= 2 and
                         all(not row["animating"] and row["displayUTF16Units"] <= 1_025
                             and 0 < row["layerPixelWidth"] <= 4_096 for row in s["mediaTextMotion"])
                         and {row["accessibilityUTF16Units"] for row in s["mediaTextMotion"]} == source_lengths,
                         "Oversized native text exceeded its display/layer bound or lost its accessible source.")
                write_private(directory / "native-text-bounds.json", json_bytes(bounded["mediaTextMotion"]))
                write_private(directory / "bounded.png", client.request("/render?surface=notch"))
                self.record("media: real oversized metadata keeps native text/layers bounded and accessible source intact",
                            sourceUTF16Lengths=sorted(source_lengths),
                            maximumLayerPixelWidth=max(row["layerPixelWidth"] for row in bounded["mediaTextMotion"]))
        finally:
            stop(child)


        fixture_state, child = session("live-metadata", live=True, rates=True)
        try:
            wait_for(fixture_state.exists, bool, "Own live-metadata fixture did not start.")
            directory = self.directory("media-live", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True})
            with self.app(directory) as client:
                def owned_live():
                    require(child.poll() is None, "Own live fixture stopped; no command sent.")
                    own = json.loads(fixture_state.read_bytes())
                    require(own["pid"] == child.pid, "Own live fixture PID changed.")
                    state = client.request()
                    require(state["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                            "Live app source changed; no command sent.")
                    return state

                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                         s["media"].get("isLive") is True and s["media"]["duration"] == 0,
                         "The app did not map the real source's public live-stream flag.")
                raw = read_adapter("--read")[1]
                require(raw.get("bundleID") == FIXTURE_ID and
                        raw.get("info", {}).get("kMRMediaRemoteNowPlayingInfoIsAlwaysLive") is True,
                        "Native current source did not supply the real live flag.")
                client.command("selectTab", tab="media")
                state = owned_live()
                require(not state["media"]["supportsSeek"], "Unknown-duration live metadata exposed seeking.")
                client.command("media.seek", seconds=10, expected=409)
                write_private(directory / "live.png", client.request("/render?surface=notch"))
                write_private(directory / "live-mounted.png", client.request("/render?surface=live-notch"))
                owned_live()
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native live source changed; no next command sent.")
                client.command("media.next")
                wait_for(lambda: json.loads(fixture_state.read_bytes()), lambda s: s["track"] == 2,
                         "Own live-metadata fixture did not advance.")
                normal = wait_for(owned_live, lambda s: s["media"].get("isLive") is False and
                    s["media"]["duration"] > 0 and s["media"]["title"] == "OpenCove verification 2",
                    "Live status or duration did not follow the actual next item.")
                require(normal["media"]["supportsSeek"], "A real timed seekable item did not restore seek support.")
                write_private(directory / "timed-first.png", client.request("/render?surface=live-notch"))
                initial = normal["media"]["elapsed"]
                time.sleep(2.2)
                advanced = owned_live()
                require(advanced["media"]["elapsed"] > initial + 1,
                        "The API clock stopped advancing after leaving unknown-duration media.")
                write_private(directory / "timed-later.png", client.request("/render?surface=live-notch"))
                owned_live()
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native timed source changed; no previous command sent.")
                client.command("media.previous")
                returned = wait_for(owned_live, lambda s: s["media"].get("isLive") is True and
                    s["media"]["duration"] == 0 and s["media"]["title"] == "OpenCove verification 1",
                    "Returning to the live item did not restore live/unavailable-timing state.")
                require(not returned["media"]["supportsSeek"], "Returning live item retained timed seek support.")
                write_private(directory / "live-returned.png", client.request("/render?surface=live-notch"))
            self.record("media: real public live flag, unknown duration, rejected seek and timed-item transition")
        finally:
            stop(child)

        fixture_state, child = session("explicit", metadata=125, style="identical", explicit=True)
        try:
            wait_for(fixture_state.exists, bool, "Owned explicit-metadata source did not start.")
            directory = self.directory("media-explicit", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "enableCalendar": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True})
            write_private(directory / "calendar-settings.json", b'{"excludedCalendarIdentifiers":"damaged"}')
            with self.app(directory) as client:
                native_observations = []

                def explicit_sample():
                    require(child.poll() is None, "Own explicit source stopped; no command sent.")
                    actual = json.loads(fixture_state.read_bytes())
                    require(actual["pid"] == child.pid, "Own explicit source PID changed; no command sent.")
                    state = client.request()
                    code, native = read_adapter("--read")
                    native_owned = code == 0 and native.get("bundleID") == FIXTURE_ID
                    native_observations.append({"fixtureTrack": actual["track"], "exit": code,
                        "appOwned": state["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                        "nativeOwned": native_owned, "nativeInfoPresent": bool(native.get("info")),
                        "nativeErrorPresent": bool(native.get("error")),
                        "nativeExplicit": native.get("info", {}).get("kMRMediaRemoteNowPlayingInfoIsExplicitTrack")
                            if native_owned else None,
                        "sourceItemChangedDuringRead": native.get("error") ==
                            "The current media source or item changed during the read."})
                    observation_path = directory / "native-observations.json"
                    observation_path.write_bytes(json_bytes(native_observations))
                    observation_path.chmod(0o600)
                    return state, actual, native

                def owned_explicit():
                    value = explicit_sample()
                    require(value[0]["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                            "Explicit-metadata app source changed; no command sent.")
                    require(native_observations[-1]["nativeOwned"] and value[2].get("bundleID") == FIXTURE_ID,
                            "Native explicit source changed; no command sent.")
                    return value

                def coherent(value):
                    return (native_observations[-1]["nativeOwned"]
                        and value[0]["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                        and value[2].get("bundleID") == FIXTURE_ID
                        and isinstance(value[2].get("info"), dict) and bool(value[2]["info"])
                        and not value[2].get("error"))

                def marked(value):
                    state, actual, native = value
                    return (coherent(value) and actual.get("publishedExplicit") is True
                        and native.get("info", {}).get("kMRMediaRemoteNowPlayingInfoIsExplicitTrack") is True
                        and state["media"].get("isExplicit") is True)

                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                         "Own explicit source did not reach the app.", 25)
                initial = wait_for(explicit_sample, marked, "Actual native explicit flag did not reach shared media state.")
                require(initial[0]["calendarAuthorization"] == "Saved calendar settings need review",
                        "Explicit Duo render must pause real calendar queries; actual status: " + initial[0]["calendarAuthorization"])
                title = initial[0]["media"]["title"]
                client.command("selectTab", tab="media")
                write_private(directory / "explicit-notch.png", client.request("/render?surface=notch"))
                write_private(directory / "explicit-lock.png", client.request("/render?surface=lock"))
                client.command("preferences", values={"expandedLayout": "duo"})
                write_private(directory / "explicit-duo.png", client.request("/render?surface=notch"))
                client.command("preferences", values={"expandedLayout": "media"})
                owned_explicit()
                client.command("media.next")
                # A read during the actual item transition can legitimately
                # return an incoherent snapshot. Settling only reads; commands
                # still require the separate fresh owned_explicit guard.
                unmarked = wait_for(explicit_sample, lambda v: coherent(v) and v[1]["track"] == 2
                    and v[1].get("publishedExplicit") is False
                    and v[2].get("info", {}).get("kMRMediaRemoteNowPlayingInfoIsExplicitTrack") is False
                    and v[0]["media"].get("isExplicit") is False,
                    "Explicit false did not replace the old true flag.")
                require(unmarked[0]["media"]["title"] == title,
                        "Explicit transition verification must retain identical visible metadata.")
                write_private(directory / "false-notch.png", client.request("/render?surface=notch"))
                write_private(directory / "false-lock.png", client.request("/render?surface=lock"))
                client.command("preferences", values={"expandedLayout": "duo"})
                write_private(directory / "false-duo.png", client.request("/render?surface=notch"))
                client.command("preferences", values={"expandedLayout": "media"})
                owned_explicit()
                client.command("media.previous")
                wait_for(explicit_sample, marked, "Returning to the actual explicit item lost its flag.")
                client.command("preferences", values={"enableMedia": False})
                cleared = client.request()
                require(not cleared["media"]["available"] and cleared["media"].get("isExplicit") is None,
                        "Disabling media retained explicit metadata.")
                write_private(directory / "disabled.png", client.request("/render?surface=notch"))
                client.command("preferences", values={"enableMedia": True})
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("isExplicit") is True, "Restored own media lost its actual explicit flag.", 25)
            with self.app(directory) as client:
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("isExplicit") is True, "Restart did not recover the real native explicit flag.", 25)
                app_pid = client.request()["pid"]
                stop(child)
                fixture_state, child = session("explicit-to-unmarked", metadata=125, style="identical", rates=True)
                wait_for(fixture_state.exists, bool, "Own unmarked replacement source did not start.")
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                         "Own unmarked source did not reach the running app.", 25)
                absent = wait_for(explicit_sample, lambda v: coherent(v) and
                    "kMRMediaRemoteNowPlayingInfoIsExplicitTrack" not in v[2].get("info", {})
                    and v[0]["media"]["available"] and v[0]["media"].get("isExplicit") is None,
                    "The running app retained an explicit flag absent from its actual new source.", 25)
                require(absent[0]["pid"] == app_pid and absent[0]["media"]["title"] == title,
                        "Unmarked transition must preserve the app process and identical visible title.")
                client.command("selectTab", tab="media")
                write_private(directory / "unmarked-notch.png", client.request("/render?surface=notch"))
                write_private(directory / "unmarked-lock.png", client.request("/render?surface=lock"))
            self.record("media: real own native explicit publisher, marked/false/absent identical-title transitions in one app, shared captures, opt-out and restart")
        finally:
            stop(child)

        fixture_state, child = session("song-peek", metadata=125, style="identical", rates=True)
        try:
            wait_for(fixture_state.exists, bool, "Own song-peek fixture did not start.")
            directory = self.directory("media-song-peek", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True, "enableNotifications": True,
                "hudDuration": 0.5, "compactActivity": "timer"})
            observations = []

            def peek_state(client):
                require(child.poll() is None and json.loads(fixture_state.read_bytes())["pid"] == child.pid,
                        "Own peek fixture stopped or changed PID; no command sent.")
                return client.request()

            def own_peek(client):
                state = peek_state(client)
                require(state["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                        "Peek app source changed; no command sent.")
                return state

            def wait_peek(client, predicate, message, timeout=12):
                # A submitted item transition can temporarily clear metadata.
                # Read only while waiting; commands still use own_peek and the
                # fresh independent native-source guard below.
                return wait_for(lambda: peek_state(client), lambda s:
                    s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and predicate(s), message, timeout)

            def change_item(client, action):
                before = own_peek(client)
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native peek source changed; no transport command sent.")
                item = before["media"].get("contentItemIdentifier")
                require(item, "Own peek source has no opaque item identity.")
                client.command(action)
                return wait_peek(client, lambda s: bool(s["media"].get("contentItemIdentifier"))
                    and s["media"]["contentItemIdentifier"] != item,
                    "Own identical-metadata source did not change its actual item.")

            def peek(client, visible):
                state = wait_peek(client, lambda s: s["mediaPeekVisible"] is visible,
                                 "Song-change peek did not reach its expected real state.")
                observations.append({"visible": state["mediaPeekVisible"], "expanded": state["expanded"],
                    "compact": state["compactActivity"], "tab": state["visibleTab"],
                    "observedAt": time.monotonic(), "remaining": state["mediaPeekRemaining"],
                    "item": state["media"].get("contentItemIdentifier"), "panels": [w for w in state["nativeWindows"]
                        if w["title"] == "OpenCove"]})
                progress = directory / "observations-progress.json"
                progress.write_bytes(json_bytes(observations))
                progress.chmod(0o600)
                return state

            with self.app(directory) as client:
                first = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("supportsNext") and bool(s["media"].get("contentItemIdentifier")),
                    "Own song-peek source did not become available.", 25)
                code, native_unmarked = read_adapter("--read")
                require(code == 0 and native_unmarked.get("bundleID") == FIXTURE_ID
                    and isinstance(native_unmarked.get("info"), dict) and bool(native_unmarked["info"])
                    and not native_unmarked.get("error")
                    and "kMRMediaRemoteNowPlayingInfoIsExplicitTrack" not in native_unmarked.get("info", {})
                    and first["media"].get("isExplicit") is None,
                    "The next independent unmarked source inherited explicit metadata.")
                require(not first["preferences"]["peekOnSongChange"] and not first["mediaPeekVisible"],
                        "Legacy preferences enabled automatic song peeks.")
                client.command("preferences", values={"mediaPeekDuration": 0}, expected=400)
                client.command("timer.start", seconds=180)
                client.command("timer.pause")
                client.command("preferences", values={"peekOnSongChange": True, "mediaPeekDuration": 3})
                client.command("collapse")
                base = peek(client, False)
                require(base["compactActivity"] == "timer", "Peek verification did not preserve its underlying timer.")
                changed = change_item(client, "media.next")
                require(changed["media"]["title"] == first["media"]["title"] and
                    changed["media"]["duration"] == first["media"]["duration"],
                    "Peek identity flow must use truly identical displayed metadata/duration.")
                visible = peek(client, True)
                require(not visible["expanded"] and visible["compactActivity"] == "timer",
                        "Peek replaced expanded state or the user's compact choice.")
                write_private(directory / "peek.png", client.request("/render?surface=notch"))
                write_private(directory / "peek-mounted.png", client.request("/render?surface=live-notch"))
                client.command("compact.open")
                opened = peek(client, False)
                require(opened["expanded"] and opened["visibleTab"] == "media",
                        "Opening a media peek did not show playback controls.")
                client.command("collapse")
                change_item(client, "media.previous")
                active = peek(client, True)
                initial_remaining = active["mediaPeekRemaining"]
                observed_at = time.monotonic()
                time.sleep(min(1.3, initial_remaining / 2))
                client.command("preferences", values={"accent": "blue", "mediaPeekDuration": 10})
                saved = own_peek(client)
                elapsed = time.monotonic() - observed_at
                require((saved["mediaPeekRemaining"] or 0) <= max(0, initial_remaining - elapsed) + 0.35,
                        "A preference update extended the actual monotonic peek deadline.")
                if elapsed < initial_remaining - 0.35:
                    require(saved["mediaPeekVisible"], "Unrelated save dismissed the active peek before its deadline.")
                wait_peek(client, lambda s: not s["mediaPeekVisible"],
                         "Metadata or preference updates extended the original peek deadline.", max(0.5, initial_remaining - elapsed + 0.75))
                client.command("preferences", values={"mediaPeekDuration": 6})
                change_item(client, "media.next")
                old = peek(client, True)
                old_deadline = time.monotonic() + old["mediaPeekRemaining"]
                time.sleep(1.4)
                change_item(client, "media.previous")
                replacement = peek(client, True)
                replacement_at = time.monotonic()
                require(old_deadline > replacement_at + 0.1 and
                        replacement_at + replacement["mediaPeekRemaining"] > old_deadline + 0.5,
                        "Actual command latency prevented observing overlapping peek deadlines.")
                client.command("preferences", values={"showPlaybackIndicator": False})
                off_peek = wait_peek(client, lambda s: not s["playbackIndicatorMotion"],
                                    "Indicator off retained native layers in the actual song peek.")
                require(off_peek["mediaPeekVisible"], "Indicator opt-out changed the active peek.")
                write_private(directory / "peek-indicator-off.png", client.request("/render?surface=live-notch"))
                time.sleep(max(0, old_deadline + 0.15 - time.monotonic()))
                retained = own_peek(client)
                require(retained["mediaPeekVisible"] and
                        retained["media"]["contentItemIdentifier"] == replacement["media"]["contentItemIdentifier"],
                        "An older item deadline dismissed or replaced its replacement peek.")
                require(retained["mediaPeekRemaining"] <= replacement["mediaPeekRemaining"] -
                        (time.monotonic() - replacement_at) + 0.35,
                        "Repeated metadata restarted the replacement's actual deadline.")
                write_private(directory / "deadline-observations.json", json_bytes({"firstRemaining": initial_remaining,
                    "afterSaveRemaining": saved["mediaPeekRemaining"], "oldDeadline": old_deadline,
                    "replacementObservedAt": replacement_at, "replacementRemaining": replacement["mediaPeekRemaining"],
                    "retainedRemaining": retained["mediaPeekRemaining"], "overlapObserved": True}))
                wait_peek(client, lambda s: not s["mediaPeekVisible"],
                         "Replacement peek did not retire.", retained["mediaPeekRemaining"] + 0.75)
                client.command("preferences", values={"mediaPeekDuration": 3, "showPlaybackIndicator": True})
                wait_for(client.request, lambda s: not s["playbackIndicatorMotion"],
                         "Expired peek retained native decorative playback layers over the timer.")
                observed_motion = not client.request()["systemReduceMotion"]
                motion = []
                if observed_motion:
                    client.command("preferences", values={"reduceMotion": False, "animationSpeed": 0.25,
                                                         "mediaPeekDuration": 5})
                    change_item(client, "media.next")
                    peek(client, True)
                    until = time.monotonic() + 1.05
                    while time.monotonic() < until:
                        state = own_peek(client)
                        motion.append([w for w in state["nativeWindows"] if w["title"] == "OpenCove"])
                        time.sleep(0.025)
                    ordinary = {w["displayID"]: w for w in base["nativeWindows"] if w["title"] == "OpenCove"}
                    target_height = max(base["preferences"]["notchHeight"], base["physicalNotch"]["height"] + 56)
                    require(any(ordinary[w["displayID"]]["height"] + 1 < w["height"] < target_height - 1
                                for frame in motion for w in frame), "A real song peek did not show intermediate native geometry.")
                    require(all(abs((w["y"] + w["height"]) -
                        (ordinary[w["displayID"]]["y"] + ordinary[w["displayID"]]["height"])) <= 1
                        for frame in motion for w in frame), "Song peek motion moved away from the native top edge.")
                    client.command("preferences", values={"reduceMotion": True})
                    wait_for(client.request, lambda s: s["playbackIndicatorMotion"] and
                        all(row["animationCount"] == 0 for row in s["playbackIndicatorMotion"]),
                        "Reduce Motion did not stop the real peek's decorative native layers.")
                    client.command("collapse")
                    peek(client, False)
                    client.command("preferences", values={"animationSpeed": 1, "mediaPeekDuration": 3})
                write_private(directory / "motion-frames.json", json_bytes({"observedMotion": observed_motion,
                                                                            "frames": motion}))
                change_item(client, "media.next")
                peek(client, True)
                client.command("notification.post", title="Owned peek interruption", body="Local HUD priority")
                require(client.request()["hud"] is not None and not client.request()["mediaPeekVisible"],
                        "A real local HUD did not dismiss the media peek.")
                wait_for(client.request, lambda s: s["hud"] is None, "Owned interrupting HUD did not retire.")
                require(not own_peek(client)["mediaPeekVisible"], "The HUD queued an obsolete media peek.")
                client.command("selectTab", tab="files")
                change_item(client, "media.previous")
                require(not own_peek(client)["mediaPeekVisible"], "Expanded controls were replaced by a peek.")
                client.command("collapse")
                peek(client, False)
                change_item(client, "media.next")
                peek(client, True)
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native source changed; no pause command sent.")
                client.command("media.playPause")
                wait_peek(client, lambda s: not s["media"]["isPlaying"]
                    and not s["mediaPeekVisible"], "Pause did not dismiss the actual peek.")
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native source changed; no resume command sent.")
                client.command("media.playPause")
                wait_peek(client, lambda s: s["media"]["isPlaying"], "Own source did not resume.")
                peek(client, False)
                change_item(client, "media.previous")
                peek(client, True)
                client.command("preferences", values={"peekOnSongChange": False})
                peek(client, False)
                time.sleep(3.2)
                client.command("preferences", values={"peekOnSongChange": True})
                peek(client, False)
                change_item(client, "media.next")
                peek(client, True)
                client.command("preferences", values={"enableMedia": False})
                require(not client.request()["mediaPeekVisible"], "Media opt-out retained a peek.")
                client.command("preferences", values={"enableMedia": True})
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                         "Own source did not return after media re-enable.", 25)
                peek(client, False)
                write_private(directory / "settings-media.png", client.request("/render?surface=settings-media"))
            with self.app(directory) as client:
                restarted = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                                     "Own peek source did not return on restart.", 25)
                require(restarted["preferences"]["peekOnSongChange"] and
                    restarted["preferences"]["mediaPeekDuration"] == 3 and not restarted["mediaPeekVisible"]
                    and restarted["compactActivity"] == "timer",
                    "Peek settings did not persist or initial rediscovery created a peek.")
                client.command("timer.cancel")
            write_private(directory / "observations.json", json_bytes(observations))
            self.record("media: identical-metadata item peek, bounded expiry/replacement, opening/HUD/pause/opt-out and restart",
                        observedNativeMotion=observed_motion)
        finally:
            stop(child)

        fixture_state, child = session("bound-seek", metadata=125, style="identical")
        try:
            wait_for(fixture_state.exists, bool, "Own bound-seek fixture did not start.")
            directory = self.directory("media-bound-seek", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True})
            observations = []

            def source(client):
                require(child.poll() is None and json.loads(fixture_state.read_bytes())["pid"] == child.pid,
                        "Owned bound-seek fixture stopped or changed PID; no command sent.")
                value = client.request()
                require(value["media"].get("sourceBundleIdentifier") == FIXTURE_ID,
                        "Bound-seek app source changed; no command sent.")
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native source changed; no command sent.")
                return value

            def position(expected):
                wait_for(lambda: json.loads(fixture_state.read_bytes()), lambda s: not s["playing"]
                         and abs(s["elapsed"] - expected) < 0.25, "The real paused source has the wrong seek position.")

            def ready(client):
                return wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("supportsSeek") and bool(s["media"].get("seekTarget")),
                    "The real source did not expose an item-bound seek target.", 25)

            with self.app(directory) as client:
                first = ready(client)
                target = first["media"]["seekTarget"]
                wait_for(client.request, lambda s: s["playbackClock"]["receivedSamples"] >=
                    first["playbackClock"]["receivedSamples"] + 2, "Real source samples did not arrive.")
                require(source(client)["media"]["seekTarget"] == target, "Unchanged metadata samples rotated the seek target.")
                client.command("media.playPause")
                wait_for(client.request, lambda s: not s["media"]["isPlaying"], "Own bound-seek source did not pause.")
                require(source(client)["media"]["seekTarget"] == target, "Pause changed the same item's seek target.")
                client.command("media.seek", seconds=17, target=target)
                position(17)
                for invalid in ("", 7, None, "x" * 129):
                    client.command("media.seek", seconds=40, target=invalid, expected=400)
                client.command("media.seek", seconds=40, target="unrecognized-target", expected=409)
                client.command("media.seek", seconds=126, target=target, expected=400)
                position(17)
                old_item = source(client)["media"]["contentItemIdentifier"]
                client.command("media.next")
                changed = wait_for(client.request, lambda s: s["media"].get("contentItemIdentifier") != old_item
                    and s["media"].get("seekTarget") != target, "An actual new item did not replace the seek target.")
                for key in ("sourceBundleIdentifier", "title", "artist", "album", "duration"):
                    require(changed["media"][key] == first["media"][key],
                            "Bound-seek regression must use identical source/text/duration metadata.")
                source(client)
                position(0)
                client.command("media.seek", seconds=41, target=target, expected=409)
                time.sleep(0.3)
                position(0)
                current = source(client)["media"]["seekTarget"]
                client.command("media.seek", seconds=23, target=current)
                position(23)
                client.command("selectTab", tab="media")
                write_private(directory / "bound-notch.png", client.request("/render?surface=notch"))
                write_private(directory / "bound-lock.png", client.request("/render?surface=lock"))
                source(client)
                client.command("media.previous")
                returned = wait_for(client.request, lambda s: s["media"].get("seekTarget") not in (target, current),
                                    "Returning to an earlier item reused a retired seek target.")
                require(returned["media"]["title"] == first["media"]["title"], "Own identical metadata changed unexpectedly.")
                source(client)
                client.command("media.seek", seconds=45, target=target, expected=409)
                position(0)
                # Immediate callers retain the documented legacy semantics.
                client.command("media.seek", seconds=5)
                position(5)
                retired = source(client)["media"]["seekTarget"]
                client.command("preferences", values={"enableMedia": False})
                client.command("preferences", values={"enableMedia": True})
                renewed = ready(client)["media"]["seekTarget"]
                require(renewed != retired, "Media restart reused an earlier seek target.")
                source(client)
                client.command("media.seek", seconds=42, target=retired, expected=409)
                position(5)
                observations.append({"first": target, "next": current, "renewed": renewed,
                                     "identicalMetadata": True, "staleRejected": True})
            with self.app(directory) as client:
                fresh = ready(client)["media"]["seekTarget"]
                require(fresh != renewed, "Process restart reused an earlier seek target.")
                source(client)
                client.command("media.seek", seconds=43, target=renewed, expected=409)
                position(5)
                client.command("media.seek", seconds=11, target=fresh)
                position(11)
                observations.append({"restarted": fresh, "staleRestartRejected": True})
            write_private(directory / "observations.json", json_bytes(observations))
            self.record("media: identical-metadata seek targets, stale/malformed rejection, current seek and media/process restart")
        finally:
            stop(child)

        fixture_state, child = session("compact-activity")
        try:
            wait_for(fixture_state.exists, bool, "Own compact media fixture did not start.")
            directory = self.directory("media-compact-activity", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True})
            observations = []

            def owned_compact(client, expected):
                require(child.poll() is None and json.loads(fixture_state.read_bytes())["pid"] == child.pid,
                        "Own compact fixture stopped or changed PID.")
                state = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["compactActivity"] == expected, "Actual compact media/timer selection did not settle.")
                observations.append({"choice": state["preferences"]["compactActivity"],
                                     "resolved": state["compactActivity"], "expanded": state["expanded"],
                                     "tab": state["visibleTab"]})
                return state

            with self.app(directory) as client:
                owned_compact(client, "media")
                client.command("timer.start", seconds=180)
                client.command("timer.pause")
                owned_compact(client, "media")
                client.command("preferences", values={"compactActivity": "timer"})
                timer = owned_compact(client, "timer")
                elapsed = timer["media"]["elapsed"]
                write_private(directory / "preferred-timer.png", client.request("/render?surface=notch"))
                client.command("compact.open")
                require(owned_compact(client, "timer")["visibleTab"] == "timer",
                        "Preferred compact timer opened the media section.")
                client.command("collapse")
                client.command("preferences", values={"compactActivity": "calendar"})
                owned_compact(client, "media")
                client.command("preferences", values={"compactActivity": "media"})
                client.command("compact.open")
                require(owned_compact(client, "media")["visibleTab"] == "media",
                        "Preferred compact media did not open its section.")
                client.command("collapse")
                write_private(directory / "preferred-media.png", client.request("/render?surface=notch"))
                client.command("preferences", values={"compactActivity": "timer", "enableTimer": False})
                owned_compact(client, "media")
                client.command("preferences", values={"enableTimer": True})
                owned_compact(client, "timer")
                time.sleep(1.2)
                current = owned_compact(client, "timer")
                require(current["media"]["elapsed"] > elapsed + 0.5 and current["media"]["isPlaying"],
                        "Compact choice interrupted the actual source or its playback clock.")
                client.command("preferences", values={"compactActivity": "automatic"})
                state = owned_compact(client, "media")
                timer_remaining = state["timer"]["remaining"]
                media_target = state["compactDismissTarget"]
                client.command("compact.dismiss", target=media_target)
                state = owned_compact(client, "timer")
                require(state["dismissedCompactActivities"] == ["media"] and state["media"]["isPlaying"],
                        "Media dismissal stopped playback or did not reveal the concurrent timer.")
                media_restore = state["compactRestoreTarget"]
                client.command("compact.dismiss", target=state["compactDismissTarget"])
                state = owned_compact(client, "clock")
                require(state["compactActivities"] == [] and state["dismissedCompactActivities"] == ["media", "timer"],
                        "Two dismissed real activities did not yield the clock.")
                timer_restore = state["compactRestoreTarget"]
                client.command("compact.restore", target=timer_restore)
                owned_compact(client, "timer")
                client.command("compact.restore", target=media_restore)
                owned_compact(client, "media")
                client.command("compact.restore", target=timer_restore, expected=409)
                client.command("compact.dismiss", target=media_target, expected=409)

                client.command("preferences", values={"compactActivity": "timer"})
                state = owned_compact(client, "timer")
                client.command("compact.dismiss", target=state["compactDismissTarget"])
                state = owned_compact(client, "media")
                require(state["compactActivities"] == ["media"] and not state["timer"]["running"]
                        and abs(state["timer"]["remaining"] - timer_remaining) < 0.25,
                        "Dismissing the preferred timer changed its persisted pause or leaked its secondary presentation.")
                write_private(directory / "dismissed-timer-media.png", client.request("/render?surface=live-notch"))
                client.command("compact.restore", target=state["compactRestoreTarget"])
                owned_compact(client, "timer")
                client.command("preferences", values={"compactActivity": "automatic"})
                state = owned_compact(client, "media")
                old_item = state["media"]["contentItemIdentifier"]
                client.command("compact.dismiss", target=state["compactDismissTarget"])
                state = owned_compact(client, "timer")
                retired_restore = state["compactRestoreTarget"]
                require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                        "Native source changed; no next-item command sent.")
                client.command("media.next")
                changed = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                    and s["media"].get("contentItemIdentifier") not in (None, "", old_item)
                    and s["compactActivity"] == "media", "A new real item inherited the previous dismissal.", 25)
                require(changed["dismissedCompactActivities"] == [] and changed["media"]["isPlaying"],
                        "New-item restoration changed playback or retained a stale dismissal.")
                client.command("compact.restore", target=retired_restore, expected=409)
                client.command("preferences", values={"compactActivity": "timer"})
                state = owned_compact(client, "timer")
                client.command("compact.dismiss", target=state["compactDismissTarget"])
                state = owned_compact(client, "media")
                client.command("compact.dismiss", target=state["compactDismissTarget"])
                owned_compact(client, "clock")
            with self.app(directory) as client:
                restarted = owned_compact(client, "timer")
                require(restarted["preferences"]["compactActivity"] == "timer" and not restarted["dismissedCompactActivities"],
                        "Preferred timer did not survive restart while media stayed active.")
                client.command("timer.cancel")
                owned_compact(client, "media")
            write_private(directory / "observations.json", json_bytes(observations))
            self.record("compact: real concurrent media/timer preference, opening, disabled fallback and restart")
            self.record("compact dismissal: concurrent real media/timer, bounded restore order, stale targets, new item and restart")
        finally:
            stop(child)

        fixture_state, child = session("unknown-duration", metadata=0)
        try:
            wait_for(fixture_state.exists, bool, "Own zero-duration fixture did not start.")
            directory = self.directory("media-unknown-duration", preferences={**SAFE, "enableMedia": True,
                "enablePrivateAPIs": True, "hideWhenIdle": False, "expandOnHover": False,
                "hideInFullscreen": False, "reduceMotion": True})
            with self.app(directory) as client:
                state = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID and
                    s["media"]["available"] and s["media"]["duration"] == 0,
                    "Own unknown-duration metadata was not read.")
                require(state["media"].get("isLive") is not True and not state["media"]["supportsSeek"],
                        "Unknown duration alone became a live or seekable source.")
                client.command("selectTab", tab="media")
                write_private(directory / "unknown-duration.png", client.request("/render?surface=live-notch"))
            self.record("media: zero duration remains unavailable timing rather than inferred live content")
        finally:
            stop(child)

        fixture_state, child = session("paused-idle", rates=True)
        try:
            wait_for(fixture_state.exists, bool, "Idle fixture did not start.")
            directory = self.directory("media-idle", preferences={**SAFE, "enableMedia": True,
                                       "enablePrivateAPIs": True, "hidePausedMedia": True, "pausedMediaDelay": 3,
                                       "hideWhenIdle": True, "expandOnHover": False, "reduceMotion": True,
                                       "enableNotifications": True, "hudDuration": 0.5})
            with self.app(directory) as client:
                def own_idle():
                    require(child.poll() is None, "Own idle fixture stopped; no command sent.")
                    own = json.loads(fixture_state.read_bytes())
                    require(own["pid"] == child.pid, "Idle fixture PID changed; no command sent.")
                    media = client.request()["media"]
                    require(media.get("sourceBundleIdentifier") == FIXTURE_ID,
                            "App idle source is not our fixture; no command sent.")
                    require(read_adapter("--read")[1].get("bundleID") == FIXTURE_ID,
                            "Native idle source is not our fixture; no command sent.")
                    return media

                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                         and s["media"]["title"] == "OpenCove verification 1" and s["media"]["isPlaying"]
                         and s["compactMediaVisible"], "Playing idle fixture did not appear.", 25)
                client.command("collapse")
                own_idle()
                client.command("media.playPause")
                wait_for(client.request, lambda s: not s["media"]["isPlaying"] and s["compactMediaVisible"],
                         "Paused media skipped its compact grace interval.")
                time.sleep(0.5)
                require(client.request()["compactMediaVisible"], "Compact pause grace expired too early.")
                hidden = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                  and s["media"]["available"] and not s["media"]["isPlaying"]
                                  and not s["compactMediaVisible"], "Paused compact media never hid.", 6)
                def panels(state):
                    return [w for w in state["nativeWindows"] if w["title"] == "OpenCove"]

                wait_for(client.request, lambda s: panels(s) and
                         all(w["height"] <= 3 and w["contentHidden"] for w in panels(s)),
                         "Idle-hidden native panel did not reduce to its edge target.")
                client.request("/render?surface=live-notch", expected=409)
                client.command("selectTab", tab="media")
                expanded = client.request()
                require(expanded["expanded"] and expanded["media"]["supportsPlayPause"]
                        and expanded["media"]["title"] == hidden["media"]["title"],
                        "Hiding compact media discarded full playback controls or metadata.")
                write_private(directory / "paused-expanded.png", client.request("/render?surface=notch"))
                write_private(directory / "media-settings.png", client.request("/render?surface=settings-media"))
                client.command("collapse")
                client.command("timer.start", seconds=2)
                wait_for(client.request, lambda s: s["timer"]["running"] and not s["compactMediaVisible"]
                         and any(w["height"] > 3 for w in s["nativeWindows"] if w["title"] == "OpenCove"),
                         "Hiding paused media also hid the real active timer.")
                wait_for(client.request, lambda s: s.get("hud", {}).get("title") == "Timer finished" if s.get("hud") else False,
                         "Real timer completion HUD did not override compact idle hiding.", 5)
                wait_for(client.request, lambda s: s.get("hud") is None and not s["timer"]["running"],
                         "Completed timer HUD did not retire.")
                own_idle()
                client.command("media.playPause")
                wait_for(client.request, lambda s: s["media"]["isPlaying"] and s["compactMediaVisible"],
                         "Resuming did not restore compact media.")
                own_idle()
                client.command("media.playPause")
                wait_for(client.request, lambda s: not s["media"]["isPlaying"] and s["compactMediaVisible"],
                         "Second pause did not begin its grace.")
                own_idle()
                client.command("media.playPause")
                wait_for(client.request, lambda s: s["media"]["isPlaying"] and s["compactMediaVisible"],
                         "Quick resume did not cancel the old deadline.")
                time.sleep(3.3)
                require(client.request()["compactMediaVisible"], "An old pause deadline hid resumed playback.")
                own_idle()
                client.command("media.playPause")
                wait_for(client.request, lambda s: not s["media"]["isPlaying"] and s["compactMediaVisible"],
                         "New pause did not start.")
                own_idle()
                client.command("media.next")
                next_state = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                      and s["media"]["title"] == "OpenCove verification 2"
                                      and not s["media"]["isPlaying"] and s["compactMediaVisible"],
                                      "New paused item did not receive a fresh compact grace.")
                started = time.monotonic()
                time.sleep(0.5)
                target = own_idle()
                client.command("media.speed", speed=2, source=FIXTURE_ID, item=target["contentItemIdentifier"])
                wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                         and not s["compactMediaVisible"], "Paused rate updates kept resetting compact grace.", 5)
                require(time.monotonic() - started < 3.8, "A paused metadata update extended the original grace.")
                wait_for(client.request, lambda s: s["media"].get("playbackSpeed") == 2 and not s["compactMediaVisible"],
                         "Paused rate update restored hidden compact media.")
                client.command("preferences", values={"accent": "orange"})
                require(not client.request()["compactMediaVisible"], "Unrelated preferences restarted compact grace.")
                client.command("preferences", values={"hidePausedMedia": False})
                wait_for(client.request, lambda s: s["compactMediaVisible"], "Disabling idle hiding did not restore media.")
                client.command("preferences", values={"hidePausedMedia": True, "pausedMediaDelay": 3})
                wait_for(client.request, lambda s: not s["compactMediaVisible"], "Re-enabling did not honor the observed pause.")
                animated_reversal = not client.request()["systemReduceMotion"]
                if animated_reversal:
                    client.command("preferences", values={"hidePausedMedia": False, "reduceMotion": False,
                                                         "animationSpeed": 0.25})
                    visible = wait_for(client.request, lambda s: panels(s) and s["compactMediaVisible"] and
                                       all(w["height"] > 3 and not w["contentHidden"] for w in panels(s)),
                                       "Native content did not restore before expanding.")
                    top_edges = sorted(w["y"] + w["height"] for w in panels(visible))
                    time.sleep(1.0)
                    client.command("preferences", values={"hidePausedMedia": True})
                    wait_for(client.request, lambda s: panels(s) and not s["compactMediaVisible"] and
                             all(not w["contentHidden"] for w in panels(s)),
                             "Native content retired before its shrink animation completed.", 2)
                    client.command("preferences", values={"hidePausedMedia": False})
                    time.sleep(1.05)
                    restored = client.request()
                    require(restored["compactMediaVisible"] and panels(restored) and
                            all(w["height"] > 3 and not w["contentHidden"] for w in panels(restored)),
                            "An interrupted shrink callback hid restored native content.")
                    require(all(abs(a - b) <= 1 for a, b in zip(top_edges,
                                sorted(w["y"] + w["height"] for w in panels(restored))))
                            and len(top_edges) == len(panels(restored)),
                            "Idle animation moved the panel away from its top edge.")
                    client.command("preferences", values={"hidePausedMedia": True})
                    wait_for(client.request, lambda s: panels(s) and not s["compactMediaVisible"] and
                             all(w["height"] <= 3 and w["contentHidden"] for w in panels(s)),
                             "Native hosting content did not retire after the completed shrink.", 3)
                    client.command("preferences", values={"reduceMotion": True, "animationSpeed": 1})
            with self.app(directory) as client:
                restarted = wait_for(client.request, lambda s: s["media"].get("sourceBundleIdentifier") == FIXTURE_ID
                                     and s["media"]["available"] and not s["media"]["isPlaying"]
                                     and s["compactMediaVisible"], "Restart did not begin a grace for the observed paused item.", 25)
                require(restarted["preferences"]["hidePausedMedia"] and restarted["preferences"]["pausedMediaDelay"] == 3,
                        "Idle preferences did not survive restart.")
                wait_for(client.request, lambda s: not s["compactMediaVisible"] and s["media"]["available"],
                         "Paused media did not hide after restarted observation.", 6)
            self.record("media: paused compact grace, resume cancellation, new item/rate, timer HUD and preference restart",
                        nativeAnimationReversal=animated_reversal)
        finally:
            stop(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence-dir", type=Path, help="Fresh private evidence path; defaults to a unique .local directory")
    parser.add_argument("--media-fixture", action="store_true", help="Explicitly play/control only our own temporary silent MediaPlayer fixture")
    parser.add_argument("--pathological-duration", action="store_true", help="With --media-fixture, render its extreme finite duration metadata")
    parser.add_argument("--weather-service", action="store_true", help="Contact real Open-Meteo for public Vancouver/Berlin and polar coordinates; no device location")
    parser.add_argument("--only", choices=("storage", "indicators", "startup", "storage-alias", "media", "compact-motion", "media-refresh", "weather", "motion", "hud-timing", "displays", "activities", "compact", "dismissal", "shape", "outline", "preferences", "timers", "timer-presentation", "timer-corruption", "calendar", "files"),
                        help="Run one real flow group for targeted follow-up")
    args = parser.parse_args()
    if args.pathological_duration and not args.media_fixture:
        parser.error("--pathological-duration requires --media-fixture")
    if args.only in ("media", "compact-motion", "media-refresh") and not args.media_fixture:
        parser.error("--only " + args.only + " requires --media-fixture")
    if args.only == "weather" and not args.weather_service:
        parser.error("--only weather requires --weather-service")
    os.umask(0o077)
    runtime = None
    try:
        if args.evidence_dir:
            evidence = args.evidence_dir.expanduser().absolute()
            evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
        else:
            parent = ROOT / ".local/verification/public"
            parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            evidence = Path(tempfile.mkdtemp(prefix="runtime-", dir=parent))
        runtime = Runtime(args.app, evidence)
        groups = [("startup", runtime.startup_port_collision), ("temp", runtime.temp_alias), ("storage-alias", runtime.storage_alias), ("preferences", runtime.preferences), ("indicators", runtime.indicators),
                  ("timers", runtime.timers), ("timer-corruption", runtime.timer_corruption),
                  ("calendar", runtime.calendar), ("files", runtime.files)]
        if args.only != "storage":
            groups.append(("hud-timing", runtime.hud_timing))
            groups.append(("timer-presentation", runtime.timer_presentation))
            groups.append(("motion", runtime.motion))
            groups.append(("displays", runtime.displays))
            groups.append(("activities", runtime.activity_selection))
            groups.append(("compact", runtime.compact_activity))
            groups.append(("dismissal", runtime.compact_dismissal))
            groups.append(("shape", runtime.shape))
            groups.append(("outline", runtime.outline))
        if args.media_fixture and args.only != "storage":
            groups.append(("compact-motion", runtime.compact_motion))
            groups.append(("media-refresh", runtime.media_refresh))
            groups.append(("media", lambda: runtime.media(args.pathological_duration)))
        if args.weather_service and args.only != "storage":
            groups.append(("weather", runtime.weather))
        for name, operation in groups:
            if args.only not in (None, "storage", name):
                continue
            try:
                operation()
            except (OSError, ValueError, KeyError, ControlFailure, urllib.error.URLError, subprocess.SubprocessError) as error:
                runtime.results.append({"flow": name, "passed": False, "error": str(error)})
                runtime.flush()
                print("FAIL " + name + ": " + str(error), flush=True)
        runtime.flush()
        print("Private evidence: " + str(evidence))
        return int(any(not result["passed"] for result in runtime.results))
    except (OSError, ValueError, KeyError, ControlFailure, urllib.error.URLError, subprocess.SubprocessError) as error:
        if runtime:
            runtime.results.append({"passed": False, "error": str(error)})
            runtime.flush()
        print("Runtime verification failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
