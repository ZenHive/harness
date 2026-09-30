#!/usr/bin/env python3
"""Run Flutter UI checks with owned display/emulator processes and durable evidence."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time


class VerificationError(Exception):
    pass


def require(command):
    executable = shutil.which(command)
    if not executable:
        raise VerificationError(f"Missing prerequisite: {command}")
    return executable


def stop(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    finally:
        # The parent can exit while a descendant remains in its owned process group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run(command, cwd, env, log, timeout):
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   stdin=subprocess.DEVNULL)
        try:
            code = process.wait(timeout=timeout)
            if code:
                raise VerificationError(f"Exit {code}: {' '.join(command)}; see {log.name}")
        except subprocess.TimeoutExpired as error:
            raise VerificationError(f"Timeout ({timeout}s): {' '.join(command)}") from error
        finally:
            stop(process)


def free_port(even=False):
    for port in range(5600 if even else 15000, 5680 if even else 15100, 2 if even else 1):
        sockets = []
        try:
            for candidate in [port, port + 1] if even else [port]:
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(("127.0.0.1", candidate))
            return port
        except OSError:
            continue
        finally:
            for sock in sockets:
                sock.close()
    raise VerificationError("Missing prerequisite: free private emulator/ADB ports")


def android(app, env, evidence, timeout):
    for tool in ["adb", "emulator", "avdmanager", "java"]:
        require(tool)
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise VerificationError("Missing prerequisite: readable/writable /dev/kvm (KVM)")
    image = env.get("HARNESS_ANDROID_IMAGE")
    sdk = env.get("ANDROID_SDK_ROOT") or env.get("ANDROID_HOME")
    if not sdk or not image or not (Path(sdk).joinpath(*image.split(";")) / "package.xml").is_file():
        raise VerificationError("Missing prerequisite: installed HARNESS_ANDROID_IMAGE in ANDROID_SDK_ROOT")
    scratch = evidence / "android-runtime"
    scratch.mkdir()
    env = dict(env, ANDROID_AVD_HOME=str(scratch), ANDROID_USER_HOME=str(scratch / "user"))
    adb_port, emulator_port = free_port(), free_port(even=True)
    env.update(ANDROID_ADB_SERVER_PORT=str(adb_port), ADB_SERVER_SOCKET=f"tcp:127.0.0.1:{adb_port}")
    adb = ["adb", "-P", str(adb_port)]
    emulator = None
    server = None
    # The private ADB server and emulator remain children of this runner, including on cancellation.
    try:
        run(["avdmanager", "create", "avd", "--name", "harness", "--package", image,
             "--path", str(scratch / "device"), "--device", "pixel_2"], app, env,
            evidence / "avd.log", timeout)
        with (evidence / "adb.log").open("wb") as output:
            server = subprocess.Popen(adb + ["nodaemon", "server"], env=env, stdout=output,
                                      stderr=subprocess.STDOUT, start_new_session=True)
        with (evidence / "emulator.log").open("wb") as output:
            emulator = subprocess.Popen(["emulator", "-avd", "harness", "-port", str(emulator_port),
                                         "-no-window", "-no-audio", "-no-snapshot", "-no-boot-anim",
                                         "-gpu", "swiftshader_indirect", "-accel", "on"], env=env,
                                        stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        serial = f"emulator-{emulator_port}"
        deadline = time.monotonic() + min(timeout, 240)
        while True:
            if emulator.poll() is not None or server.poll() is not None:
                raise VerificationError("Private emulator/ADB exited; see emulator.log and adb.log")
            result = subprocess.run(adb + ["-s", serial, "shell", "getprop", "sys.boot_completed"],
                                    env=env, capture_output=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip() == b"1":
                break
            if time.monotonic() >= deadline:
                raise VerificationError("Android emulator boot timeout")
            time.sleep(1)
        drive(app, env, evidence, timeout, serial, "android")
    finally:
        stop(emulator)
        stop(server)
        shutil.rmtree(scratch)


def drive(app, env, evidence, timeout, device, target):
    output = evidence / target
    output.mkdir()
    env = dict(env, HARNESS_SCREENSHOT_DIR=str(output))
    command = ["flutter", "drive", "--driver=test_driver/evidence.dart",
               "--target=integration_test/app_test.dart", "-d", device]
    if device == "linux":
        require("xvfb-run")
        command = ["xvfb-run", "--auto-servernum", "--server-args=-screen 0 1280x960x24"] + command
    run(command, app, env, evidence / f"{target}.log", timeout)
    if not list(output.glob("*.png")):
        raise VerificationError(f"Missing {target} screenshots: test_driver/evidence.dart must write HARNESS_SCREENSHOT_DIR")


def verify(args):
    app = args.app.resolve()
    root = args.worktree.resolve()
    app.relative_to(root)
    evidence = root / ".harness" / "evidence" / args.attempt
    evidence.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    checks = {}

    def check(name, action):
        try:
            action()
            checks[name] = {"passed": True}
        except (VerificationError, OSError, subprocess.SubprocessError) as error:
            checks[name] = {"passed": False, "output": str(error)}
        # A report survives failure and names exact prerequisites; reviewer copies checks, then judges.
        (evidence / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        return checks[name]["passed"]

    def prerequisites():
        require("flutter")
        if not (app / "pubspec.yaml").is_file():
            raise VerificationError("Missing prerequisite: Flutter app pubspec.yaml")

    if check("prerequisites", prerequisites):
        fetched = check("flutter pub get", lambda: run(["flutter", "pub", "get"], app, env,
                                                      evidence / "pub-get.log", args.timeout))
        if fetched:
            check("flutter analyze", lambda: run(["flutter", "analyze"], app, env,
                                                evidence / "analyze.log", args.timeout))
            check("flutter test (widget and golden)", lambda: run(["flutter", "test", "--reporter=json"],
                  app, env, evidence / "widget-golden.jsonl", args.timeout))
            # Flutter owns comparison and the failing exit status; retain its diffs unchanged.
            for path in (app / "test").rglob("failures/*.png"):
                destination = evidence / "golden-diffs" / path.relative_to(app / "test")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
            check("integration_test linux", lambda: drive(app, env, evidence, args.timeout, "linux", "linux"))
            check("integration_test android", lambda: android(app, env, evidence, args.timeout))
    files = [str(path.relative_to(root)) for path in sorted(evidence.rglob("*")) if path.is_file()]
    for value in checks.values():
        value["evidence"] = files
    (evidence / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(json.dumps(checks, indent=2))
    return 0 if checks and all(value["passed"] for value in checks.values()) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path.cwd())
    parser.add_argument("--worktree", type=Path, default=Path.cwd())
    parser.add_argument("--attempt", required=True, help="Unique role-attempt directory, e.g. reviewer-1")
    parser.add_argument("--timeout", type=int, default=900, help="Per-command budget including cold dependencies")
    args = parser.parse_args()
    if not args.attempt or Path(args.attempt).name != args.attempt or args.attempt in (".", ".."):
        parser.error("attempt must be a single directory name")
    def cancelled(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, cancelled)
    return verify(args)


if __name__ == "__main__":
    sys.exit(main())
