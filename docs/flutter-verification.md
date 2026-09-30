# Flutter verification on the Linux host

Implementers and reviewers run the app's checks in their own worktree. The reviewer
opens the flow screenshots, assesses the screen against the acceptance criteria,
and writes the verdict. Harness stores evidence; it does not judge pixels.

The reference runner is `scripts/flutter-verify.py` (Python 3 standard library).
Flutter/Dart is the client stack because this verification contract covers Linux
and Android using Flutter's own test tools. Consumers copy the runner and adapt
the fixture's `test_driver/evidence.dart` and `integration_test/app_test.dart` to
exercise their actual flows. Linux screenshots use `RenderRepaintBoundary.toImage`
and travel through integration_test report data to the host driver; they do not
rely on the Android-only surface conversion API. The screenshots show app content,
not desktop window decorations. Flutter's driver reports test failures through its
exit status.

## Host prerequisites

Install a Flutter SDK on PATH, the Flutter Linux build dependencies (clang, CMake,
Ninja, pkg-config, GTK development libraries), Xvfb with `xvfb-run` and `xauth`,
Java, and the Android SDK command-line tools, platform-tools and emulator. The
runner never installs system packages, accepts licenses, or changes KVM permissions.
The executing account needs read/write access to `/dev/kvm`.

Set the SDK location and an **installed** emulator image identifier, for example:

```sh
export ANDROID_SDK_ROOT=/path/to/android-sdk
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"
export HARNESS_ANDROID_IMAGE='system-images;android-35;google_apis;x86_64'
```

Provision the chosen image with Android's `sdkmanager`, with licenses accepted by
the host operator. Missing SDK, image, KVM access and commands produce named failed
checks, not skips. Build tools report any additional missing packages in retained logs.
See [Flutter installation](https://docs.flutter.dev/install) and
[Flutter integration tests](https://docs.flutter.dev/testing/integration-tests).

## Per-run command and evidence

From the run worktree:

```sh
python3 scripts/flutter-verify.py --app . --attempt implementer-1 --timeout 900
python3 scripts/flutter-verify.py --app . --attempt reviewer-1 --timeout 900
```

For a nested app pass `--app clients/flutter --worktree "$PWD"`. Each invocation
requires a fresh attempt directory so old screenshots cannot satisfy a new check.
The per-command budget includes cold dependency fetches (`flutter pub get`) and
builds. Set the harness run and reviewer timeouts to cover all stages plus agent
review time; a cold Android build may exceed the 900-second command default.

The runner executes analyze, widget/golden tests, Linux integration via a private
Xvfb display, and Android integration via a private AVD and ADB server. It creates
AVD state inside the evidence attempt directory, waits for boot, and removes only
its own runtime state. The runner terminates its process groups on success, failure,
timeout or SIGTERM/SIGINT. It never attaches to an operator's emulator or ADB server.

The integration driver must write screenshots to `HARNESS_SCREENSHOT_DIR`.
The fixture illustrates two flow states and a host-side report callback supported by
[Flutter's integrationDriver](https://api.flutter.dev/flutter/package-integration_test_integration_test_driver/integrationDriver.html).
Golden baselines live in `test/goldens/`; Flutter's failure diffs are copied into
the evidence directory. Do not update baselines simply to clear a red test.

The runner writes `checks.json` with command outcomes and exact evidence paths.
The reviewer incorporates those entries into `.harness/review.json`:

```json
{
  "verdict": "reject",
  "run_id": "<HARNESS_RUN_ID>",
  "review_attempt": "<HARNESS_REVIEW_ATTEMPT>",
  "report": "Android UI verification blocked by inaccessible KVM",
  "checks": {
    "integration_test android": {
      "passed": false,
      "output": "Missing prerequisite: readable/writable /dev/kvm (KVM)",
      "evidence": [".harness/evidence/reviewer-1/checks.json"]
    }
  }
}
```

Required UI checks or screenshots missing means reject, even if compile passes.
This acceptance judgment belongs to the reviewer. The reader also rejects an
approve artifact with unavailable referenced files or evidence collection errors;
it does not infer UI requirements from task text. A rejected review retains the
errors and available files.

Files under `.harness/evidence/` are snapshotted into the run record's
`review_evidence` map (base64 bytes, MIME type, byte count, SHA-256 and path), before
worktree cleanup. Apply the `20260930090000` database migration before deploying.
Memory and Postgres result stores preserve the snapshot across later bookkeeping
updates. The run detail page displays PNG/JPEG screenshots and download links for
reports and diffs. The storage bounds are 100 files, 4 MB per file, 16 MB total and
12 directory levels; exceeding them produces explicit collection errors. Symlinks
and nonregular files are refused. Keep evidence relevant and free of credentials.
Evidence remains excluded from delivery commits, even if an agent stages it.

## Focused verification

```sh
python3 -m unittest discover -s test/scripts -p test_flutter_verify.py
mix test test/harness/run/evidence_test.exs test/harness/run/review_test.exs test/harness/dashboard/live_test.exs
mix test test/harness/flutter_verification_test.exs --include integration
export HARNESS_LIVE_REVIEWER_MODEL='<available Claude model>'
# Authenticate codex and claude before this real, paid two-agent dispatch.
mix test test/harness/flutter_live_agent_test.exs --include integration --include live_agent
```

The live toolchain tests create disposable Linux/Android projects from
`test/fixtures/flutter_app`. One changes the golden's color deliberately and
requires Flutter to fail and emit diffs. The live-agent test dispatches a title
change through a real Codex implementer and Claude reviewer, requires screenshots
for both targets referenced by the persisted checks, and verifies commit exclusion.
These live tests fail explicitly when prerequisites are absent; the default unit
suite excludes integration tests using the repository's existing tag policy.
