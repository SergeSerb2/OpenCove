#!/usr/bin/env python3
"""Exercise the real app's HTTP/CLI boundary. No mocks, unit tests, or desktop input.

--data-dir checks an existing explicitly enabled app without changing app state.
--app launches the supplied built bundle in a NEW private temporary data directory
and runs file/timer/preferences flows there. It never builds or replaces a bundle.
Hardware writes require --hardware-volume; no permissions are requested.
"""
import argparse
from datetime import datetime
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import uuid

from verify_control import ControlClient, ControlFailure, bundle_identity, check_bundle

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ControlFailure(message)


def raw_request(client, data, *, half_close=False):
    with socket.create_connection(("127.0.0.1", client.config["port"]), timeout=3) as connection:
        connection.settimeout(5)
        connection.sendall(data)
        if half_close:
            connection.shutdown(socket.SHUT_WR)
        response = bytearray()
        while True:
            try:
                chunk = connection.recv(8192)
            except ConnectionResetError:
                if response:
                    break
                raise
            if not chunk:
                break
            response.extend(chunk)
            require(len(response) <= 2 * 1024 * 1024, "Raw HTTP response exceeded its limit.")
    header, separator, body = bytes(response).partition(b"\r\n\r\n")
    require(bool(separator), "The server closed without a complete HTTP response.")
    lines = header.decode("ascii").split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = dict(line.split(": ", 1) for line in lines[1:])
    require(int(headers["Content-Length"]) == len(body), "HTTP response framing is inconsistent.")
    require(headers.get("Connection") == "close", "The control server must close each connection.")
    require(headers.get("Cache-Control") == "no-store", "Control responses must not be cached.")
    require(headers.get("Referrer-Policy") == "no-referrer", "Control responses need a no-referrer policy.")
    return status, headers, body


def protocol_checks(client, passed):
    state = client.request()
    require(state.get("controlProtocol") == 1, "This running app predates the hardened protocol. Rebuild and launch the intended isolated bundle before this suite.")
    host = f"Host: 127.0.0.1:{client.config['port']}\r\n".encode()
    auth = ("X-OpenCove-Token: " + client.config["token"] + "\r\n").encode()

    def wire(first, headers=b"", body=b"", *, include_host=True, include_auth=True):
        return first + b"\r\n" + (host if include_host else b"") + (auth if include_auth else b"") + headers + b"\r\n" + body

    cases = [
        ("missing token", wire(b"GET /state HTTP/1.1", include_auth=False), 401),
        ("wrong token", wire(b"GET /state HTTP/1.1", b"X-OpenCove-Token: wrong\r\n", include_auth=False), 401),
        ("missing Host", wire(b"GET / HTTP/1.1", include_host=False), 403),
        ("foreign Host", wire(b"GET / HTTP/1.1", b"Host: example.invalid\r\n", include_host=False), 403),
        ("foreign Origin", wire(b"GET /state HTTP/1.1", b"Origin: https://example.invalid\r\n"), 403),
        ("cross-site browser", wire(b"GET /state HTTP/1.1", b"Sec-Fetch-Site: cross-site\r\n"), 403),
        ("duplicate Host", wire(b"GET / HTTP/1.1", host), 400),
        ("duplicate token", wire(b"GET /state HTTP/1.1", auth), 400),
        ("duplicate Content-Length", wire(b"POST /command HTTP/1.1", b"Content-Length: 0\r\nContent-Length: 1\r\n"), 400),
        ("invalid header", wire(b"GET / HTTP/1.1", b"NoColon\r\n"), 400),
        ("folded header", wire(b"GET / HTTP/1.1", b" folded: value\r\n"), 400),
        ("space before colon", wire(b"GET / HTTP/1.1", b"X-Header : value\r\n"), 400),
        ("bare newline", wire(b"GET / HTTP/1.1", b"X-Header: value\nOther: value\r\n"), 400),
        ("NUL header", wire(b"GET / HTTP/1.1", b"X-Header: bad\0value\r\n"), 400),
        ("transfer encoding", wire(b"POST /command HTTP/1.1", b"Transfer-Encoding: chunked\r\n"), 400),
        ("conflicting framing", wire(b"POST /command HTTP/1.1", b"Transfer-Encoding: chunked\r\nContent-Length: 0\r\n"), 400),
        ("signed Content-Length", wire(b"POST /command HTTP/1.1", b"Content-Length: +1\r\n"), 400),
        ("negative Content-Length", wire(b"POST /command HTTP/1.1", b"Content-Length: -1\r\n"), 400),
        ("oversized body declaration", wire(b"POST /command HTTP/1.1", b"Content-Length: 65537\r\n"), 413),
        ("missing Content-Length", wire(b"POST /command HTTP/1.1"), 411),
        ("unsupported Expect", wire(b"POST /command HTTP/1.1", b"Expect: 100-continue\r\nContent-Length: 0\r\n"), 417),
        ("unsupported encoding", wire(b"POST /command HTTP/1.1", b"Content-Encoding: gzip\r\nContent-Length: 0\r\n"), 415),
        ("GET body", wire(b"GET /state HTTP/1.1", b"Content-Length: 1\r\n", b"x"), 400),
        ("unsupported HTTP version", wire(b"GET / HTTP/1.0"), 505),
        ("absolute request target", wire(b"GET http://127.0.0.1/ HTTP/1.1"), 400),
        ("network-path target", wire(b"GET //example.invalid/ HTTP/1.1"), 400),
        ("oversized header", wire(b"GET / HTTP/1.1", b"X-Large: " + b"x" * 16384 + b"\r\n"), 431),
        ("unknown render prefix", wire(b"GET /render-unexpected HTTP/1.1"), 404),
        ("unknown endpoint", wire(b"GET /unknown HTTP/1.1"), 404),
        ("wrong GET method", wire(b"GET /command HTTP/1.1"), 405),
        ("wrong POST method", wire(b"POST /state HTTP/1.1", b"Content-Length: 0\r\n"), 405),
        ("state query", wire(b"GET /state?unexpected=1 HTTP/1.1"), 400),
        ("duplicate render surface", wire(b"GET /render?surface=notch&surface=lock HTTP/1.1"), 400),
        ("unknown render surface", wire(b"GET /render?surface=unknown HTTP/1.1"), 400),
        ("wrong content type", wire(b"POST /command HTTP/1.1", b"Content-Length: 2\r\nContent-Type: text/plain\r\n", b"{}"), 415),
        ("invalid JSON", wire(b"POST /command HTTP/1.1", b"Content-Length: 1\r\nContent-Type: application/json\r\n", b"{"), 400),
        ("non-object JSON", wire(b"POST /command HTTP/1.1", b"Content-Length: 2\r\nContent-Type: application/json\r\n", b"[]"), 400),
    ]
    for name, data, expected in cases:
        code, headers, _ = raw_request(client, data)
        require(code == expected, f"{name}: expected HTTP {expected}, got {code}.")
        if code == 405:
            require(headers.get("Allow") in ("GET", "POST"), "405 response is missing Allow.")
    code, _, _ = raw_request(client, wire(b"POST /command HTTP/1.1", b"Content-Length: 9\r\nContent-Type: application/json\r\n", b"{"), half_close=True)
    require(code == 400, "Truncated request body did not return HTTP 400.")
    # Future bytes may arrive after a complete first request. A single response
    # followed by close is safe; bytes already buffered must instead return 400.
    code, _, _ = raw_request(client, wire(b"GET /state HTTP/1.1") + wire(b"GET /state HTTP/1.1"))
    require(code in (200, 400), "Pipelining was not safely closed/rejected.")
    passed("raw HTTP framing, limits, methods, headers, routes and authorization", cases=len(cases) + 2)

    original = client.request()
    for action, values, expected in [
        ("unknown", {}, 400),
        ("timer.start", {"seconds": -1}, 400),
        ("timer.start", {"seconds": True}, 400),
        ("timer.start", {"seconds": 86401}, 400),
        ("preferences", {"values": {"notchWidth": 1e100}}, 400),
        ("preferences", {"values": {"notchHeight": -1}}, 400),
        ("preferences", {"values": {"enableCalendar": 1}}, 400),
        ("preferences", {"values": {"accent": "invalid"}}, 400),
        ("preferences", {"values": {"unknown": True}}, 400),
        ("files.add", {"paths": ["relative.txt"]}, 400),
        ("files.add", {"paths": ["/tmp/file\0suffix"]}, 400),
        ("files.add", {"paths": [str(client.directory / ("missing-" + uuid.uuid4().hex))]}, 400),
        ("files.add", {"paths": [str(client.directory)]}, 400),
        ("files.add", {"paths": []}, 400),
        ("media.speed", {"speed": 1.5}, 409),
    ]:
        client.command(action, expected=expected, **values)
    after = client.request()
    require(after["preferences"] == original["preferences"], "Invalid commands changed preferences.")
    require(after["files"] == original["files"], "Invalid commands changed the existing tray.")
    before_timer, after_timer = original["timer"], after["timer"]
    naturally_finished = False
    if before_timer["running"] and before_timer.get("endsAt") and not after_timer["running"] and after_timer["remaining"] == 0:
        naturally_finished = datetime.fromisoformat(before_timer["endsAt"].replace("Z", "+00:00")).timestamp() <= time.time()
    require(after_timer["duration"] == before_timer["duration"] and (naturally_finished or (
        after_timer.get("endsAt") == before_timer.get("endsAt") and after_timer["running"] == before_timer["running"]
        and (before_timer["running"] or after_timer["remaining"] == before_timer["remaining"]))), "Invalid commands replaced the existing timer.")
    passed("invalid command rejection preserves existing preferences, tray and timer")


def slow_checks(client, passed):
    connections = []
    started = time.monotonic()
    last_drip = started
    drip = None
    host = f"Host: 127.0.0.1:{client.config['port']}\r\n"
    try:
        for initial in (b"", b"GET / HTTP/1.1\r\n", ("POST /command HTTP/1.1\r\n" + host + "X-OpenCove-Token: " + client.config["token"] + "\r\nContent-Length: 10\r\nContent-Type: application/json\r\n\r\n{").encode()):
            connection = socket.create_connection(("127.0.0.1", client.config["port"]), timeout=2)
            connection.settimeout(0.1)
            if initial:
                connection.sendall(initial)
            connections.append(connection)
        drip = socket.create_connection(("127.0.0.1", client.config["port"]), timeout=2)
        drip.settimeout(0.1)
        drip.sendall(b"GET / HTTP/1.1\r\nX-Drip: ")
        connections.append(drip)
        while connections and time.monotonic() - started < 18:
            if drip in connections and time.monotonic() - last_drip > 0.5:
                try:
                    drip.sendall(b"x")
                except (BrokenPipeError, ConnectionResetError):
                    drip.close()
                    connections.remove(drip)
                last_drip = time.monotonic()
            for connection in list(connections):
                try:
                    if not connection.recv(1024):
                        connection.close()
                        connections.remove(connection)
                except socket.timeout:
                    pass
                except ConnectionResetError:
                    connection.close()
                    connections.remove(connection)
            time.sleep(0.1)
        require(not connections, "A slow or idle client survived the fixed connection deadline.")
        client.request()
        passed("idle, partial and continuously dripping connections close within 18 seconds")
    finally:
        for connection in connections:
            connection.close()


def cli_checks(client, passed, stale_bundle=None):
    arguments = [sys.executable, str(ROOT / "script/opencovectl"), "--data-dir", str(client.directory)]
    # Poison both proxy environments. A real local read must still succeed.
    environment = dict(os.environ, HTTP_PROXY="http://127.0.0.1:1", http_proxy="http://127.0.0.1:1",
                       ALL_PROXY="http://127.0.0.1:1", all_proxy="http://127.0.0.1:1", NO_PROXY="", no_proxy="")
    result = subprocess.run(arguments + ["state"], env=environment, capture_output=True, timeout=10)
    require(result.returncode == 0, "Real CLI state request failed with proxy variables set.")
    require(json.loads(result.stdout)["pid"] == client.config["pid"], "CLI answered from a different app.")
    for invalid in ("[]", "{", '{"value":NaN}'):
        result = subprocess.run(arguments + ["command", invalid], input=b"", capture_output=True, timeout=10)
        require(result.returncode != 0, "CLI accepted an invalid command.")
        require(client.config["token"].encode() not in result.stdout + result.stderr, "CLI error exposed its bearer token.")
    with tempfile.TemporaryDirectory(prefix="opencove-cli-input-") as temporary:
        work = Path(temporary).resolve()
        for name in ("missing", "fifo", "link", "invalid"):
            directory = work / name
            directory.mkdir(mode=0o700)
            if name == "fifo":
                os.mkfifo(directory / "control.json", 0o600)
            elif name == "link":
                (directory / "control.json").symlink_to(client.directory / "control.json")
            elif name == "invalid":
                descriptor = directory / "control.json"
                with descriptor.open("x") as file:
                    file.write("{}")
                descriptor.chmod(0o600)
            result = subprocess.run([*arguments[:2], "--data-dir", str(directory), "state"], capture_output=True, timeout=5)
            require(result.returncode != 0 and b"Traceback" not in result.stderr, "CLI did not safely reject a missing/unsafe descriptor.")
    actual = client.request()
    bundle, info = bundle_identity(actual["bundlePath"])
    result = subprocess.run([sys.executable, str(ROOT / "script/verify_control.py"), str(client.directory), str(info["CFBundleVersion"]), str(bundle), "--timeout", "1"], capture_output=True, timeout=5)
    require(result.returncode == 0, "The actual readiness CLI rejected the correct bundle/source identity.")
    if stale_bundle:
        bundle, info = bundle_identity(stale_bundle)
        require(str(info["CFBundleVersion"]) == str(client.request()["build"]), "--stale-bundle must have the same build to cover the stale-owner regression.")
        require(str(bundle) != client.request().get("bundlePath"), "--stale-bundle must be a different actual bundle path.")
        result = subprocess.run([sys.executable, str(ROOT / "script/verify_control.py"), str(client.directory), str(info["CFBundleVersion"]), str(bundle), "--timeout", "0.5"], capture_output=True, timeout=5)
        require(result.returncode != 0 and b"stale" in result.stderr, "Readiness accepted a same-version owner from another bundle.")
        passed("same-version stale owner rejected by the actual readiness CLI")
    passed("real CLI proxy bypass, caller errors, private descriptor and FIFO/symlink rejection")


@contextmanager
def isolated_app(app):
    bundle, info = bundle_identity(app)
    with tempfile.TemporaryDirectory(prefix="opencove-e2e-") as temporary:
        directory = Path(temporary).resolve()
        # Explicitly disable every integration that can need permission or network.
        preferences = {"enablePrivateAPIs": False, "enableCalendar": False, "enableMedia": False,
                       "allowAppleScript": False, "enableWeather": False, "showLiveWaveform": False,
                       "enableHaptics": False, "enableNotifications": False, "mirrorSystemNotifications": False,
                       "replaceSystemHUDs": False, "launchAtLogin": False, "showOnLockScreen": False,
                       "showLockScreenPrivateContent": False, "completedOnboarding": True}
        path = directory / "preferences.json"
        path.write_text(json.dumps(preferences))
        path.chmod(0o600)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with (directory / "app.log").open("xb") as log:
            child = subprocess.Popen([str(bundle / "Contents/MacOS/OpenCove"), "--control-port", str(port), "--no-onboarding"],
                                     env={**os.environ, "OPENCOVE_DATA_DIR": str(directory)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while True:
                    require(child.poll() is None, "The owned isolated app exited before readiness. No other process was stopped.")
                    try:
                        client = ControlClient(directory)
                        state = client.request(timeout=1)
                        require(state["pid"] == child.pid, "A different process answered for the isolated app.")
                        check_bundle(state, bundle, info, info["CFBundleVersion"])
                        break
                    except (OSError, ControlFailure, urllib.error.URLError):
                        if time.monotonic() >= deadline:
                            raise ControlFailure("The isolated app did not become ready. Inspect the supplied bundle and its startup policy.") from None
                        time.sleep(0.15)
                yield client
            finally:
                # Only the exact Popen child belongs to this script. No process-name kills.
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)


def isolated_flows(client, passed, render=False):
    initial = client.request()
    require(not initial["files"] and initial["timer"]["remaining"] == 0 and not initial["timer"]["running"], "Mutation flows require a fresh tray and timer; existing user state is never replaced.")
    original = initial["preferences"]
    original_bytes = (client.directory / "preferences.json").read_bytes()
    fixture = client.directory / ("tray-" + uuid.uuid4().hex + ".txt")
    fixture.write_text("OpenCove real caller integration file\n")
    file_id = None
    timer_owned = False
    try:
        client.command("preferences", values={"enableTimer": True, "enableFileTray": True, "reduceMotion": True})
        state = client.command("files.add", paths=[str(fixture)])
        file_id = next(file["id"] for file in state["files"] if file["name"] == fixture.name)
        require(len(client.command("files.add", paths=[str(fixture)])["files"]) == len(state["files"]), "File deduplication failed.")
        require(all(file["id"] != file_id for file in client.command("files.remove", id=file_id)["files"]), "Tray removal failed.")
        file_id = None
        require(fixture.read_text().startswith("OpenCove"), "Tray removal changed the source file.")
        passed("isolated real-file add, deduplication and remove preserve the source")
        timer_owned = True
        client.command("timer.start", seconds=3)
        time.sleep(0.2)
        paused = client.command("timer.pause")["timer"]
        time.sleep(0.3)
        state = client.request()
        require(not state["timer"]["running"] and abs(state["timer"]["remaining"] - paused["remaining"]) < 0.05, "Paused timer changed.")
        client.command("timer.resume")
        deadline = time.monotonic() + 6
        while client.request()["timer"]["running"] and time.monotonic() < deadline:
            time.sleep(0.15)
        state = client.request()
        require(state["timer"]["remaining"] == 0 and any(item["title"] == "Timer finished" for item in state["notifications"]), "Timer did not complete through the actual activity path.")
        client.command("timer.cancel")
        timer_owned = False
        passed("isolated real timer start, pause, resume, completion and cancel")
        preferences = client.directory / "preferences.json"
        backup = client.directory / ("preferences-" + uuid.uuid4().hex + ".backup")
        preferences.rename(backup)
        preferences.mkdir(mode=0o700)
        try:
            client.command("preferences", expected=500, values={"reduceMotion": False})
            state = client.request()
            require(not state["preferences"]["reduceMotion"] and any("could not be saved" in message for message in state["errors"]), "Real save failure did not report the applied-but-unsaved state.")
            passed("isolated real persistence failure returns HTTP 500 and retains a truthful state/error")
        finally:
            preferences.rmdir()
            backup.rename(preferences)
        if render:
            for surface in ("notch", "settings", "onboarding", "lock"):
                png = client.request("/render?surface=" + surface)
                require(len(png) > 1000, "Offscreen rendering returned an unexpectedly small PNG.")
            passed("four offscreen native render surfaces")
    finally:
        # Best effort actions are independent: one cleanup failure does not skip another.
        failures = []
        cleanup = []
        if file_id:
            cleanup.append(lambda: client.command("files.remove", id=file_id))
        if timer_owned:
            cleanup.append(lambda: client.command("timer.cancel"))
        cleanup.append(lambda: client.command("preferences", values=original))
        for action in cleanup:
            try:
                action()
            except Exception:
                failures.append("An isolated API cleanup action failed.")
        fixture.unlink(missing_ok=True)
        if not failures:
            final = client.request()
            require(final["preferences"] == original and final["files"] == initial["files"] and final["timer"]["remaining"] == 0, "Isolated state restoration failed.")
            # Keep the exact pre-flow persisted bytes, including legacy omissions.
            (client.directory / "preferences.json").write_bytes(original_bytes)
        require(not failures, " ".join(failures))
    passed("isolated preferences, tray and empty timer restored")


def hardware_volume(client, passed):
    original = client.request()["system"]
    require(original["canSetVolume"] and not original["isMuted"] and original.get("outputDeviceID") is not None and original["outputDeviceUID"], "Explicit volume verification needs an unmuted writable output with a stable identity.")
    device_id, uid, volume = original["outputDeviceID"], original["outputDeviceUID"], original["volume"]
    delta = -0.0625 if volume >= 0.125 else 0.0625
    submitted = False
    try:
        submitted = True  # A transport error can occur after the real write.
        client.command("system.adjustVolume", delta=delta, id=device_id, uid=uid)
        time.sleep(0.3)
        changed = client.request()["system"]
        require(changed.get("outputDeviceID") == device_id and changed["outputDeviceUID"] == uid and abs(changed["volume"] - (volume + delta)) < 0.02, "Volume target/write could not be verified.")
    finally:
        if submitted:
            current = client.request()["system"]
            require(current.get("outputDeviceID") == device_id and current["outputDeviceUID"] == uid and not current["isMuted"], "Output identity/mute changed; restoration was not sent to another device.")
            require(abs(current["volume"] - volume) < 0.02 or abs(current["volume"] - (volume + delta)) < 0.02, "Volume changed externally; restoration would overwrite that change.")
            correction = volume - current["volume"]
            if abs(correction) > 0.001:
                client.command("system.adjustVolume", delta=correction, id=device_id, uid=uid)
                time.sleep(0.3)
            require(abs(client.request()["system"]["volume"] - volume) < 0.02, "Original volume was not restored.")
    passed("explicitly opted-in physical volume write and restoration on the same output")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--data-dir", type=Path, help="Read-only checks against an existing real control endpoint")
    target.add_argument("--app", type=Path, help="Launch this built bundle in a fresh private directory for mutation flows")
    parser.add_argument("--slow", action="store_true", help="Also wait for idle/partial connection teardown (about 15 seconds)")
    parser.add_argument("--render", action="store_true", help="With --app, render four native surfaces offscreen")
    parser.add_argument("--hardware-volume", action="store_true", help="With --app, explicitly change PHYSICAL volume briefly and restore it")
    parser.add_argument("--stale-bundle", type=Path, help="Different real bundle, same build, that readiness must reject as expected owner")
    args = parser.parse_args(argv)
    if (args.render or args.hardware_volume) and not args.app:
        parser.error("--render and --hardware-volume require an owned fresh --app session")
    results = []

    def passed(name, **details):
        results.append({"flow": name, "passed": True, **details})

    def run(client):
        protocol_checks(client, passed)
        cli_checks(client, passed, args.stale_bundle)
        if args.slow:
            slow_checks(client, passed)
        if args.app:
            isolated_flows(client, passed, args.render)
        if args.hardware_volume:
            hardware_volume(client, passed)

    try:
        if args.app:
            with isolated_app(args.app) as client:
                run(client)
        else:
            run(ControlClient(args.data_dir))
    except (OSError, ValueError, ControlFailure, urllib.error.URLError, subprocess.SubprocessError, StopIteration) as error:
        # Error text is from our checks/API, never a raw credential-bearing request.
        results.append({"passed": False, "error": str(error) or type(error).__name__})
        print(json.dumps(results, indent=2))
        return 1
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
