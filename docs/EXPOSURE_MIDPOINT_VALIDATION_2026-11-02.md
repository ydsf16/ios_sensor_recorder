# Exposure midpoint timing, 2026-11-02

## Device evidence

USB-connected iPhone 12 (iOS 18.6.1), wide 1280×720 at 30 fps: a short diagnostic capture produced 121 frames. All 121 sample buffers contained a per-frame EXIF `ExposureTime` attachment and a pixel-buffer `MetadataDictionary.ExposureTime` value. Switching the torch changed pixel-buffer exposure from about 25 ms to about 11 ms. The EXIF value differed from the pixel-buffer value by at most 0.284 ms in this run. The production implementation reads the public EXIF attachment without copying the image or the attachment dictionary.

Wide + Ultra Wide virtual hardware capture, 1280×720 at 30 fps: 60 frames from each output were inspected. Both outputs had EXIF and pixel-buffer exposure values on every sampled frame. Startup frames began at different times; among the 60 wide frames, 53 had a nearest Ultra Wide timestamp within 1 ms. This diagnostic did not establish the physical exposure anchor of sample PTS.

## New index semantics

`sensor_sec` and movie PTS remain unchanged. Each camera frame index adds `exposure_mid_sensor_sec` and `exposure_mid_utc_sec`, estimated as `sensor_sec + exposure_sec / 2`. `exposure_source` records `frame_exif`, `device_current`, `arkit_frame`, or `unavailable`. Missing exposure yields `nan`, rather than an invented midpoint. For VIO, use the midpoint column for images and the original `sensor_sec` for IMU samples.

The SDK documentation does not guarantee that video PTS or `ARFrame.timestamp` marks exposure start. The added midpoint therefore encodes the requested half-exposure convention, not a calibrated physical exposure center. Rolling-shutter row timing also remains uncalibrated.

## Verification

Debug and Release iPhoneOS builds succeeded, and all 23 Python tests passed. After the iPhone 12 was unlocked, the production recorder's DEBUG validation entry ran three short recordings with all original movie timestamps preserved:

| Capture | Index frames and exposure source | File validation |
| --- | --- | --- |
| Wide 1280×720 at 30 fps | 159, all `frame_exif` | PASS; 159 decoded frames |
| Wide + Ultra Wide 1280×720 at 30 fps | 151 per camera, all `frame_exif` | PASS; 151 synchronized groups, maximum original timestamp skew 0.064 ms |
| ARKit 1920×1440 at 30 fps | 161, all `arkit_frame` | PASS; 161 decoded frames, zero missing target slots |

All new midpoint timestamps increased monotonically. The validators checked `exposure_mid_sensor_sec = sensor_sec + exposure_sec / 2` for each recorded row and checked that the MP4 timelines still matched the original frame timestamps. The recording directories were copied to `/tmp/SRP-exposure-center-device-wide30`, `/tmp/SRP-exposure-center-device-dual30`, and `/tmp/SRP-exposure-center-device-arkit30` on the test Mac.
