# [PhoneAI] 把手机变成数据采集器：Sensor Recorder Pro

## 摘要

Sensor Recorder Pro 把 iPhone 变成一个低成本的真实世界数据采集器。它可以同步记录双路相机视频、音频、IMU、Motion、GNSS 等多源数据，并导出为结构化 session 文件，用于机器人、XR、具身智能、Physical AI 和科学实验。

核心思路很简单：先让手机稳定记录透明、可复现的原始数据，再把可视化、同步检查和格式转换放到离线工具链里完成，例如 Rerun。

最近做了一个 iPhone 多传感器数据记录 App：Sensor Recorder Pro。目标是把手机变成一个低成本的真实世界数据采集器。

当前支持 iPhone / iOS，可以同步记录两路相机视频、音频、IMU、Motion、GNSS 等多源数据，并导出为规范的数据文件。App 已发布到 App Store。

这篇文章主要想聊三个问题：

- 为什么手机值得被当成一个数据采集平台？
- 为什么具身智能、Physical AI、机器人、XR 和科学实验都需要多传感器数据？
- Sensor Recorder Pro 目前做了什么，后续还想做什么？

App Store：Sensor Recorder Pro  
开源代码：https://github.com/ydsf16/ios_sensor_recorder  
开放数据：链接 https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g 密码 `inv0`

![Sensor Recorder Pro recording UI](docs/images/sensor-recorder-recording-ui.png)

## Rerun 可视化

Sensor Recorder Pro 的一次录制可以离线转换成 Rerun `.rrd`，用于同时查看双目视频、IMU、音频、姿态和 Geo 轨迹。

![Rerun visualization](docs/images/sensor-recorder-rerun-view.png)

## 1. 手机：被低估的真实世界数据入口

手机可能是被低估的多传感器计算平台。它不仅集成了多个摄像头、麦克风、IMU、GNSS、磁力计、气压计，部分高端设备还标配了 LiDAR、深度相机等空间感知硬件。同时，手机拥有不断增强的端侧算力、成熟的操作系统、完善的权限管理、海量存储以及高速网络能力。

相比于从零开始设计、开模、调试一套专用的硬件采集设备，直接利用手机的优势非常直接：保有量巨大，部署极其敏捷，使用门槛极低，传感器与算力持续增强。

在很多真实世界的数据采集任务中，我们并不一定需要先造硬件。把手机里的传感器和算力用起来，就能以极低的成本完成第一轮实验闭环。

Sensor Recorder Pro 就是基于这个想法迈出的第一步：先从 iPhone 平台开始，把手机变成一个开箱即用、数据可导出、实验可复现的多传感器数据采集器。

## 2. 为什么需要多传感器数据？

过去几年，大模型已经证明了数据规模的重要性。但对于具身智能、物理 AI、机器人和 XR 来说，互联网上的文本、图片和视频数据远远不够。

这些方向更需要来自真实世界的、具备强时间同步的多模态数据：视频、声音、空间位置、运动姿态、惯性测量等。这些数据可以服务于几个很有潜力的方向。

### 2.1 具身智能 / Physical AI

具身智能需要理解真实世界中的空间、时间、动作和交互。

在第一人称视角 Ego-centric AI 数据方向上，许多学术工作或大厂研究会尝试通过挂脖或头部支架将手机作为采集终端，记录人类日常行为，再在云端进行数据清洗和基础物理模型训练。例如 AoE: Always-on Egocentric Human Video Collection for Embodied AI。

目前很多团队会开放论文或数据集，但真正易用、开放、可修改的手机原始数据采集工具并不多。Sensor Recorder Pro 希望先补上其中一块：把多传感器原始数据方便地采下来，为后续算法提供燃料。

![Ego-centric data collection reference](docs/images/egocentric-data-collection-reference.png)

### 2.2 机器人

机器人算法需要海量真实场景数据。手机虽然不是机器人本体，但可以作为低成本分布式采集设备。

例如，可以将手机直接固连在低成本移动机器人本体上，比如四足狗、轮式底盘、无人机，让它同时作为传感器源与临时计算平台。

这样可以用极低成本快速验证原型，提升迭代效率。

![Phone robot reference](docs/images/phone-robot-reference.png)

### 2.3 XR / AR / VR

XR 系统天然依赖空间感知、多传感器融合和用户行为建模。

虽然今天的手机普遍标配了 ARKit 或 ARCore 这类高级空间框架，但对于算法研究员来说，高度封装的输出往往是黑盒。

Sensor Recorder Pro 当前阶段更关注底层原始数据的记录。另外，iPhone 的多目相机记录也会和 ARKit 有冲突。直接记录底层数据，对于验证自定义空间计算、场景重建等任务更灵活。

![AR reference](docs/images/ar-reference.png)

### 2.4 AI 眼镜 / Always-on Agent

最近 AI 眼镜、胸针式 AI 设备、Always-on Agent 这类产品层出不穷。它们背后的核心逻辑是设备持续观察并理解真实世界。

手机其实也可以作为这类探索的低成本起点。例如将手机固定在胸前，通过间歇式、占空比约 10% 的采集策略，连续记录低功耗音频 / GPS，并固定间隔唤醒相机录制短视频。

这可以模拟 Always-on 硬件的数据形态，用来探索 Life-long 智能 Agent 系统。

![iPhone head mount concept](docs/images/iphone-head-mount-concept.png)

### 2.5 科学实验与教育

许多物理实验和运动分析，比如加速度、旋转实验、环境记录和高校工程教学，都需要高频次、多源的传感器数据支撑。

手机提供了一个人人皆可获取的实验数据平台。学生和研究者可以用它快速采集数据，再直接导入 Python、Matlab 或 Jupyter Notebook 进行传感器融合教学或工程原型验证。

## 3. Sensor Recorder Pro 是什么？

简单来说，Sensor Recorder Pro 是一个专为算法消费而生的多传感器数据记录 App。

当前版本聚焦于 iPhone 平台，旨在同步记录多源数据，并导出为规范、可复现实验的数据文件。

### 当前核心功能

- 多目视频采集：目前支持 iPhone 两个后置摄像头采集，可以设置摄像头选择、分辨率、帧率、最大曝光时间、是否自动对焦、固定对焦参数。这些设置主要是为了方便算法实验。在 VIO、SLAM 或运动分析中，曝光时间、帧率和对焦策略都会影响数据质量。
- 音频采集：支持同步记录环境声音，后续可以用于声音事件分析、场景理解、多模态记录等任务。
- IMU 数据记录：支持记录加速度计、陀螺仪等惯性测量数据，可用于运动分析、姿态估计等任务。
- 设备 Motion 数据记录：支持记录系统级 Motion 数据，包括设备姿态、旋转、重力方向等信息，便于快速分析设备运动状态。
- GNSS / 地理位置轨迹记录：支持记录经纬度、轨迹和定位相关信息，可用于户外轨迹分析、出行记录、场景标注和空间数据分析。
- 多源时间戳记录：所有数据都会带有两种时间戳，一个是机器的单调递增时间，一个是 UTC 时间，便于后续进行多源数据对齐、分析和算法处理。
- 源代码开放：代码已经开源，可以自行编译、修改和扩展。

Sensor Recorder Pro 要解决的核心问题很简单：让真实世界的多模态传感器数据更容易被采集、导出和使用。

## 数据格式与使用方式

为了对开发者友好，一次采集任务会被保存为一个独立的 Session 文件夹，全部采用通用媒体文件和 CSV：

```text
SR_yyyy-MM-dd_HH-mm-ss/
├── meta.json              # 本次录制的设备信息、采集配置、时间模型与各文件 schema
├── wide.mp4               # 主摄 wide 视频流
├── wide_info.csv          # 主摄逐帧索引：sensor_sec, utc_sec, exposure, ISO, 分辨率, 相机内参
├── ultrawide.mp4          # 超广角视频流
├── ultra_info.csv         # 超广角逐帧索引：sensor_sec, utc_sec, exposure, ISO, 分辨率, 相机内参
├── audio.m4a              # 麦克风环境音频流
├── audio_info.csv         # 音频 buffer 索引：sensor_sec, utc_sec, duration, sample_rate, channels
├── accelerometer.csv      # 原始加速度计数据：sensor_sec, utc_sec, ax, ay, az
├── gyroscope.csv          # 原始陀螺仪数据：sensor_sec, utc_sec, gx, gy, gz
├── imu.csv                # gyro 对齐的 IMU 数据：accel + gyro + 对齐时间戳
├── device_motion.csv      # CoreMotion 姿态融合数据：quaternion, roll/pitch/yaw, gravity, user_accel
├── magnetometer.csv       # 原始磁力计数据：sensor_sec, utc_sec, mx, my, mz
├── barometer.csv          # 气压计数据：sensor_sec, utc_sec, pressure, relative_altitude
└── geo_location.csv       # 定位轨迹数据：sensor_sec, utc_sec, lat, lon, alt, speed, course, accuracy
```

## 4. 开放数据

我用自己的手机采集了一些数据，欢迎大家一起玩一玩。

链接：https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g  
密码：`inv0`

## 5. 后续

- 支持更多传感器：比如前置相机、LiDAR、更多后置相机。
- 完善后处理工具链：提供配套的离线后处理能力，比如将离散文件一键打包成 `.rrd`、`.mcap` 等更适合规模分发复用的格式。
- 探索数据的应用：比如用于基础模型训练、Life-long 智能、具身智能、机器人、XR 等方向。

## 6. 总结

Sensor Recorder Pro 的目标是把每个人手中被低估的手机，变成物理世界 AI 的低成本分布式入口。

先把数据稳定地采下来，再让 AI 真正去理解物理世界。

欢迎体验、拍砖、Star。

App Store：Sensor Recorder Pro  
开源代码：https://github.com/ydsf16/ios_sensor_recorder  
数据链接：https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g 密码：`inv0`
