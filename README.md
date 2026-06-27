# Sensor Recorder Pro

## English

### Summary

Sensor Recorder Pro turns an iPhone into a low-cost, reproducible, multi-sensor data recorder for VIO, SLAM, robotics, XR, embodied AI, Physical AI, and field experiments.

### Downloads

- App Store: [Sensor Recorder Pro](https://apps.apple.com/search?term=Sensor%20Recorder%20Pro)
- Open data: [Baidu Netdisk](https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g), password: `inv0`

The app records synchronized real-world signals from iPhone hardware:

- Up to three selected camera streams from wide, ultra-wide, telephoto, and front cameras. Unsupported MultiCam combinations are automatically trimmed.
- Per-frame camera metadata: timestamp, exposure, ISO, resolution, and intrinsics.
- Audio from `audio.m4a`.
- Raw accelerometer and gyroscope data.
- Gyro-keyed IMU rows.
- CoreMotion device motion, including attitude, gravity, user acceleration, and rotation rate.
- Magnetometer, barometer, and Geo location.
- A `meta.json` manifest with device metadata, capture settings, schemas, codecs, and timestamp semantics.

Each session is saved as a folder named `SR_yyyy-MM-dd_HH-mm-ss/`. The phone keeps recording simple and robust: videos stay as MP4, audio stays as M4A, sensor streams stay as CSV, and offline tools convert the session for visualization and analysis.

### Time model

Every stream carries two timestamps when available:

- `sensor_sec`: monotonic sensor time for camera, IMU, audio, motion, and sensor fusion alignment.
- `utc_sec`: Unix UTC time for wall-clock correlation, Geo data, external logs, and experiment notes.

Use `sensor_sec` for sensor alignment. Use `utc_sec` when correlating with the outside world.

### Build and run

1. Open `SensorRecorder.xcodeproj` in Xcode.
2. Set your signing team in `Project -> Signing & Capabilities`.
3. Connect an iPhone that supports MultiCam capture.
4. Build and run on device.

The current capture pipeline targets iOS 15.4+.

### Post-processing

Convert a completed session to Rerun:

```bash
python3 -m pip install rerun-sdk numpy
python3 tools/convert_recording.py /path/to/SR_yyyy-MM-dd_HH-mm-ss -o recording.rrd
rerun recording.rrd
```

The converter uses `wide_info.csv`, `ultra_info.csv`, optional `tele_info.csv`, and optional `front_info.csv` as the source of truth for camera frame time. It decodes MP4 frames with local `ffmpeg`, logs images into Rerun, and restores every logged frame onto the recorded `sensor_time` timeline from `sensor_sec`. It also logs `utc_time` when available.

By default video is written to Rerun at up to 5fps to keep long recordings manageable. Use `--video-fps 0` to write every frame.

The saved Rerun layout shows:

- Top: ultra-wide, wide, optional telephoto, and optional front image streams.
- Lower left: IMU acceleration, gyro, and raw `audio.m4a` waveform.
- Lower right: attitude roll/pitch/yaw and Geo ENU curves in meters.

![Rerun visualization](docs/images/sensor-recorder-rerun-view.png)

### Articles

- [English blog: Turn an iPhone into a real-world data recorder](BLOG_EN.md)
- [中文文章：把手机变成数据采集器](BLOG_ZH.md)

## 中文

### 摘要

Sensor Recorder Pro 把 iPhone 变成一个低成本、可复现、多模态的真实世界数据采集器，面向 VIO、SLAM、机器人、XR、具身智能、Physical AI 和科学实验。

### 下载与数据

- App Store 下载：[Sensor Recorder Pro](https://apps.apple.com/search?term=Sensor%20Recorder%20Pro)
- 开放数据：[百度网盘](https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g)，密码：`inv0`

这个 App 可以同步记录 iPhone 硬件中的多源传感器数据：

- 从 wide、ultra-wide、telephoto、front 中任选最多三路相机视频。不支持的 MultiCam 组合会自动裁剪。
- 每帧相机信息：时间戳、曝光、ISO、分辨率、相机内参。
- `audio.m4a` 音频。
- 原始加速度计和陀螺仪。
- gyro 对齐的 IMU 数据。
- CoreMotion device motion，包括姿态、重力、用户加速度和旋转速度。
- 磁力计、气压计和 Geo 位置。
- `meta.json`，记录设备信息、采集设置、schema、codec 和时间模型。

每次录制会保存为一个 `SR_yyyy-MM-dd_HH-mm-ss/` 文件夹。手机端只负责稳定记录原始数据：视频保存为 MP4，音频保存为 M4A，传感器保存为 CSV，后处理工具再把 session 转换成适合可视化和分析的格式。

### 时间模型

每条数据尽量保留两种时间：

- `sensor_sec`：单调递增的传感器时间，用于相机、IMU、音频、姿态等多源数据对齐。
- `utc_sec`：Unix UTC 时间，用于和真实世界时间、Geo、外部日志、实验记录关联。

传感器融合和对齐优先使用 `sensor_sec`。需要和外部世界关联时使用 `utc_sec`。

### 编译运行

1. 用 Xcode 打开 `SensorRecorder.xcodeproj`。
2. 在 `Project -> Signing & Capabilities` 设置自己的签名团队。
3. 连接支持 MultiCam 的 iPhone。
4. 在真机上编译运行。

当前采集链路目标版本是 iOS 15.4+。

### 后处理

把一次录制转换成 Rerun：

```bash
python3 -m pip install rerun-sdk numpy
python3 tools/convert_recording.py /path/to/SR_yyyy-MM-dd_HH-mm-ss -o recording.rrd
rerun recording.rrd
```

转换器以 `wide_info.csv`、`ultra_info.csv`、可选的 `tele_info.csv` 和可选的 `front_info.csv` 作为相机帧时间戳的真值来源。它用本地 `ffmpeg` 解码 MP4，把图像写入 Rerun，并把每一帧恢复到原始 `sensor_sec` 对应的 `sensor_time` 时间轴；可用时也会写入 `utc_time`。

默认视频最多按 5fps 写入 Rerun，避免长时间录制生成过大的 `.rrd` 文件。使用 `--video-fps 0` 可以写入每一帧。

Rerun 默认布局包括：

- 上方：ultra-wide、wide、可选 telephoto 和可选 front 图像。
- 左下：IMU acceleration、gyro、从 `audio.m4a` 解码的原始音频波形。
- 右下：attitude roll/pitch/yaw 和 Geo ENU 米制曲线。

### 文章

- [English blog: Turn an iPhone into a real-world data recorder](BLOG_EN.md)
- [中文文章：把手机变成数据采集器](BLOG_ZH.md)
