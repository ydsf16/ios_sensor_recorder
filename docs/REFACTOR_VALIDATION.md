# Sensor Recorder Pro — Refactor and Device Validation Plan

Tracking: #1. Target branch: `refactor/recording-robustness` from `main`.

## Before changes
- Build and run current main on both phones. Preserve at least one exported baseline session per mode/device.
- Record exact model, iOS version, app commit, format/FPS, enabled sensors, camera configuration, premium state, and duration.
- Keep original files as byte-for-byte baseline; compare schema headers and units against future recordings.

## Refactor rules
- First move types out of ViewController.swift without changing logic, behavior, coordinate systems, UI, session folder naming or public CSV schemas.
- Make small commits with separate diffs for extraction, writer lifecycle, diagnostics, clock, and validator.
- Every writer must expose a terminal success/failure state. On not-ready / failed append, count the loss instead of silently skipping it.
- Compare timestamps in one host clock domain; document how wall clock was mapped, and avoid implying sub-millisecond cross-sensor synchronization without measurement.
- Make writer shutdown idempotent, and do not mark a recording complete until asynchronous writer completion succeeds.
- No change to purchases, trial limits, license or existing recordings.

## Test matrix
| Case | iPhone 12 | iPhone 16 | Validate |
|---|---|---|---|
| Standard one camera + raw gyro/accel | yes | yes | image index vs decoded frames, positive monotonic PTS, sensor sample rates |
| Multi-camera supported combinations | capability-dependent | capability-dependent | actual active streams, independent camera counters, metadata |
| ARKit RGB + pose | if supported | if supported | pose/video alignment, tracking states, axes |
| LiDAR or sceneDepth | only if supported | only if exact model supports | PNG count and index, calibration, 0-invalid semantics |
| Audio + video | yes | yes | sample counts, PTS interval coverage, decoded files |
| GPS/barometer/magnetometer | capability-dependent | capability-dependent | permissions, monotonic time, sensible units |
| 10+ rapid start/stop cycles | yes | yes | no crash, no leaked writer/session or corrupt tail |
| Interruptions / app background | yes | yes | clear status, recoverable partial session |
| Low-storage / high-temperature | simulate carefully | simulate carefully | clear error, counters, no falsely successful run |
| Export -> Rerun conversion | yes | yes | expected streams and frame counts |
| Free/premium behavior | yes | yes | exact pre-refactor behavior retained |

## Evidence to collect for each run
- Model, iOS version, app commit/build, mode, requested and actual camera format/FPS, sensor switches, duration and temperature/thermal warnings.
- Session directory zip (remove personal location/audio when sharing).
- `meta.json`, *_info.csv, `arkit_pose.csv` if present, run logs, recording error diagnostics and Rerun conversion output.
- Count received/encoded/skipped/failed frames; observe timestamp gaps and estimate actual output FPS.
- Record pass/fail and a minimal reproduction for any regression.

## Exit criteria
- Xcode build passes, behavior preserved on both devices.
- Session validator catches missing file, malformed CSV, non-monotonic timestamps and frame-index mismatch.
- No unreported writer failure, and metrics clearly distinguish capture drops from encoder backpressure.
- No merge until owner reviews real-device evidence.
