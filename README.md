# iOS Sensor Recorder

An iOS data capture app for VIO, embodied AI, robotics experiments, and sensor enthusiasts.

The app records synchronized multi-sensor data from iPhone hardware using a shared monotonic sensor time base plus UTC timestamps for offline alignment.

## Recorded Data

- `wide.mp4`: wide camera video.
- `ultrawide.mp4`: ultra-wide camera video.
- `wide_info.csv` / `ultra_info.csv`: per-frame timestamps, exposure, ISO, image size, and camera intrinsics.
- `audio.m4a`: standalone microphone audio, requesting stereo when available.
- `audio_info.csv`: per-audio-buffer timestamps, duration, sample count, sample rate, and channel count.
- `accelerometer.csv`: raw accelerometer samples.
- `gyroscope.csv`: raw gyroscope samples.
- `imu.csv`: gyro-keyed raw IMU rows with the latest accelerometer sample attached.
- `device_motion.csv`: CoreMotion fused device motion, including attitude, gravity, user acceleration, rotation rate, magnetic field estimate, and heading.
- `magnetometer.csv`: raw magnetometer samples.
- `barometer.csv`: pressure and relative altitude.
- `geo_location.csv`: CoreLocation fused geographic location.
- `meta.json`: capture manifest describing files, schemas, codecs, and timestamp semantics.

## Time Model

Each stream records:

- `sensor_sec`: monotonic host-clock seconds, suitable for sensor fusion and interpolation.
- `utc_sec`: Unix UTC seconds, suitable for wall-clock and geographic correlation.

Use `sensor_sec` for camera, IMU, audio, and location alignment. Use `utc_sec` when correlating with external systems.

## Build And Run

1. Open `SensorRecorder.xcodeproj` in Xcode.
2. Set your signing team in `Project -> Signing & Capabilities`.
3. Connect an iPhone that supports MultiCam capture.
4. Build and run on device.

The current capture pipeline targets iOS 15.4+.

## Post-processing

Check capture stream rates:

```bash
python3 tools/check_sensor_rates.py /path/to/capture_dir
```

Check dual-camera timestamp alignment:

```bash
python3 tools/check_dual_timestamps.py /path/to/capture_dir
```

Convert a completed capture to a Rerun recording:

```bash
python3 -m pip install rerun-sdk numpy
python3 tools/convert_recording.py /path/to/SR_yyyy-MM-dd_HH-mm-ss -o recording.rrd
rerun recording.rrd
```

The Rerun converter is the primary offline visualization path. It requires
local `ffmpeg` and uses `wide_info.csv` / `ultra_info.csv` as the source of
truth for camera frame time. MP4 frames are decoded locally and logged as Rerun
images, so playback does not depend on Rerun's bundled video decoder.

Each logged video frame is restored onto the Rerun `sensor_time` timeline from
the recorded `sensor_sec`, with `utc_time` logged when available. Sensor CSV
streams keep their original `sensor_sec` / `utc_sec` timelines.

By default the converter writes video images at up to 5fps to keep long
recordings manageable. Use `--video-fps 0` to write every video frame.

The `.rrd` includes a saved Rerun layout:

- top: ultra-wide and wide image streams side by side
- lower left: IMU acceleration XYZ, gyro XYZ, and raw audio sample waveform decoded from `audio.m4a`
- lower right: attitude roll/pitch/yaw and Geo ENU curves in meters

Rerun entity paths:

- `/camera/wide` and `/camera/ultrawide`: decoded video images with restored frame timestamps.
- `/audio_m4a/waveform`: raw audio sample waveform decoded from `audio.m4a`.
- `/sensors/imu/*`: gyro-keyed acceleration and gyroscope values.
- `/sensors/device_motion/*`: fused CoreMotion attitude and motion values.
- `/sensors/geo_raw/*`: original CoreLocation samples with original timestamps.
- `/sensors/geo/*`: Geo samples inside the recording sensor-time window.
- `/sensors/geo_relative/*`: filtered Geo samples converted to relative east/north/up meters for readable plots.

Release branches use the standard `release/v<major>.<minor>.<patch>` naming,
for example `release/v1.0.0`.
