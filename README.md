# iOS Sensor Recorder / Sensor Recorder Pro

An iOS data capture app for VIO, embodied AI, robotics experiments, and sensor enthusiasts.

The app records synchronized multi-sensor data from iPhone hardware using a shared monotonic sensor time base plus UTC timestamps for offline alignment.

一款面向 VIO、具身智能、机器人实验和传感器玩家的 iOS 数据采集 App。

它会从 iPhone 硬件中记录多模态传感器数据，并用统一的单调传感器时间 `sensor_sec` 和 UTC 时间 `utc_sec` 做离线对齐。

![Sensor Recorder Pro recording UI](docs/images/sensor-recorder-recording-ui.png)

中文介绍: Sensor Recorder Pro 把 iPhone 变成低成本、多模态、可复现的数据采集器，用于 VIO、SLAM、机器人、AR/VR、具身智能和个人实验。

English summary: Sensor Recorder Pro turns an iPhone into a reproducible multi-sensor data logger for VIO, SLAM, robotics, AR/VR, embodied AI, and field experiments.

Read the full bilingual article / 阅读完整中英文文章:

- [中文: 把手机变成数据采集器](BLOG.md#把-iphone-变成科研传感器平台一个面向-vio机器人与具身智能的数据采集工具)
- [English: Turn an iPhone into a research sensor platform](BLOG.md#english-summary-turn-an-iphone-into-a-research-sensor-platform)

## Recorded Data / 录制数据

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

每次录制会生成一个 `SR_yyyy-MM-dd_HH-mm-ss/` 目录，里面包含双路视频、音频、IMU、姿态、磁力计、气压计、Geo 位置和 `meta.json`。

## Time Model / 时间模型

Each stream records:

- `sensor_sec`: monotonic host-clock seconds, suitable for sensor fusion and interpolation.
- `utc_sec`: Unix UTC seconds, suitable for wall-clock and geographic correlation.

Use `sensor_sec` for camera, IMU, audio, and location alignment. Use `utc_sec` when correlating with external systems.

每条传感器记录都尽量保留两类时间：

- `sensor_sec`: 单调递增的传感器时间，用于相机、IMU、音频、姿态等流之间的对齐。
- `utc_sec`: Unix UTC 时间，用于和真实世界时间、Geo、外部日志或实验事件关联。

## Build And Run / 编译运行

1. Open `SensorRecorder.xcodeproj` in Xcode.
2. Set your signing team in `Project -> Signing & Capabilities`.
3. Connect an iPhone that supports MultiCam capture.
4. Build and run on device.

The current capture pipeline targets iOS 15.4+.

中文步骤：

1. 用 Xcode 打开 `SensorRecorder.xcodeproj`。
2. 在 `Project -> Signing & Capabilities` 设置自己的签名团队。
3. 连接支持 MultiCam 的 iPhone。
4. 在真机上编译运行。

当前采集链路目标版本是 iOS 15.4+。

## Post-processing / 后处理

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

中文用法：

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

Rerun 转换器是当前主要的离线可视化路径。它依赖本地 `ffmpeg` 解码 MP4，并以 `wide_info.csv` / `ultra_info.csv` 作为视频帧时间戳的真值来源。写入 Rerun 的每一帧都会恢复到原始 `sensor_sec` 时间轴；可用时也会写入 `utc_time`。

默认视频最多按 5fps 写入 Rerun，避免长时间录制生成过大的 `.rrd` 文件。使用 `--video-fps 0` 可以写入每一帧。

The `.rrd` includes a saved Rerun layout:

- top: ultra-wide and wide image streams side by side
- lower left: IMU acceleration XYZ, gyro XYZ, and raw audio sample waveform decoded from `audio.m4a`
- lower right: attitude roll/pitch/yaw and Geo ENU curves in meters

`.rrd` 内置默认 Rerun 界面：

- 上方：ultra-wide 和 wide 双路图像。
- 左下：IMU acceleration XYZ、gyro XYZ、从 `audio.m4a` 解码的原始音频波形。
- 右下：attitude roll/pitch/yaw 和 Geo ENU 米制曲线。

Rerun entity paths:

- `/camera/wide` and `/camera/ultrawide`: decoded video images with restored frame timestamps.
- `/audio_m4a/waveform`: raw audio sample waveform decoded from `audio.m4a`.
- `/sensors/imu/*`: gyro-keyed acceleration and gyroscope values.
- `/sensors/device_motion/*`: fused CoreMotion attitude and motion values.
- `/sensors/geo_raw/*`: original CoreLocation samples with original timestamps.
- `/sensors/geo/*`: Geo samples inside the recording sensor-time window.
- `/sensors/geo_relative/*`: filtered Geo samples converted to relative east/north/up meters for readable plots.

## Release Branches / Release 分支

Release branches use the standard `release/v<major>.<minor>.<patch>` naming, for example `release/v1.0.0`.

Release 分支使用标准版本号命名，例如 `release/v1.0.0`。
