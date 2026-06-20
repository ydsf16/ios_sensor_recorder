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

## Tools

Check capture stream rates:

```bash
python3 tools/check_sensor_rates.py /path/to/capture_dir
```

Check dual-camera timestamp alignment:

```bash
python3 tools/check_dual_timestamps.py /path/to/capture_dir
```
