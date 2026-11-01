# iPhone 12 targeted validation — 2026-11-01

Device: iPhone 12 (`00008101-000A31621EE1001E`). The iPhone 16 was not used.

## Results

| Area | Result | Evidence |
| --- | --- | --- |
| Previously failing Standard configurations, all sensors enabled | 61/61 recordings pass media, timestamps, audio, and IMU validation. One device-to-Mac copy failed once and passed after retry. | `.codex-baseline/resolution-follows-rate-validation/failed61-rerun/file-validation.json` |
| Wide settings UI traversal | XCTest passed 145 resolution/frame-rate selections across 14 resolutions, with a short recording after each resolution. | `/tmp/SensorRecorder-ui-wide-rerun9.xcresult` |
| ARKit 1920x1440 30→60 and 1280x720 20→60 | After allowing the old ARKit session to release the camera before starting the next session, all four sequential 10-second recordings passed strict frame-slot validation. | `/tmp/arkit4-delay1-result.json` |
| Original five ARKit anomalies, optimized Release test build | Four pass strict validation. 1920x1080@60 has one isolated missing slot in 10 seconds while the average remains 59.89 fps. | `.codex-baseline/resolution-follows-rate-validation/arkit-rerun5/release-final-validation.json` |
| ARKit 1920x1080@60, 60 seconds, all sensors | 3 missing frame slots in 3642 recorded frames; 59.96 fps measured. No thermal pressure; physical footprint about 141–160 MB. | `/tmp/arkit16-60s-gap.json` |
| ARKit 1920x1080@60, 60 seconds, camera only | 8 missing frame slots in 3605 recorded frames; 59.87 fps measured. This does not support blaming the other sensor writers for the isolated source gaps. | `/tmp/arkit16-camera-only-validation.json` |

The user accepted occasional isolated ARKit frame gaps. The sustained 60→30 fps transition is fixed in the targeted tests; zero frame loss over long ARKit recordings is **not** established.

## Changes made during validation

- ARKit recorder detaches only the pixel buffer before enqueueing; recording preview reuses that buffer.
- ARKit session transitions wait one second after teardown before starting a new session. This removed the repeatable 60→30 fps transition in the tested configurations.
- Settings capability scanning suspends preview and waits until both verified menus are ready before enabling Save.
- The UI test reads verified options and taps menu rows away from the device's floating AssistiveTouch control.
- The DEBUG matrix runner now marks an ARKit profile failed if its metadata records missing target frame slots, rather than reporting a false success.

## Remaining validation

- LiDAR Depth cannot be tested on this iPhone 12. A connected LiDAR-equipped iPhone is needed for physical Depth validation.
- The UI test here fully traversed Wide. Other camera combinations were covered by the 61 previously failing Standard recordings, but not by a complete UI option traversal in this run.

A normal Release build was installed and launched on the iPhone 12 after testing.
