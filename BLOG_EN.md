# [PhoneAI] Turning a Phone into a Data Recorder: Sensor Recorder Pro

## Summary

Sensor Recorder Pro turns an iPhone into a low-cost real-world data recorder. It synchronously captures dual-camera video, audio, IMU, Motion, GNSS, and other sensor streams, then exports structured session files for robotics, XR, embodied AI, Physical AI, and scientific experiments.

The main idea is simple: use the phone as a reliable data collection platform first, keep raw data transparent and reproducible, and move visualization, synchronization checks, and format conversion to offline tools such as Rerun.

I recently built an iPhone multi-sensor recording app called Sensor Recorder Pro. The goal is to turn a phone into a low-cost real-world data collection device.

The current version supports iPhone / iOS. It can synchronously record multiple data streams, including dual camera video, audio, IMU, Motion, and GNSS, and export them as structured data files. The app has been released on the App Store.

This article covers three questions:

- Why should a phone be treated as a data collection platform?
- Why do embodied AI, Physical AI, robotics, XR, and scientific experiments need multi-sensor data?
- What does Sensor Recorder Pro do today, and what should it support next?

App Store: Sensor Recorder Pro  
Open source code: https://github.com/ydsf16/ios_sensor_recorder  
Open data: https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g password `inv0`

![Sensor Recorder Pro recording UI](docs/images/sensor-recorder-recording-ui.png)

## Rerun visualization

A Sensor Recorder Pro session can be converted offline into a Rerun `.rrd` file, making it possible to inspect camera streams, IMU, audio, attitude, and Geo trajectory together.

![Rerun visualization](docs/images/sensor-recorder-rerun-view.png)

## 1. The phone: an underestimated real-world data interface

The phone may be an underestimated multi-sensor computing platform. It integrates cameras, microphones, IMU, GNSS, magnetometer, barometer, and in some high-end devices, LiDAR and depth-sensing hardware. It also has increasingly strong on-device compute, a mature operating system, permission management, large storage, and fast networking.

Compared with designing, manufacturing, and debugging a dedicated hardware recorder from scratch, using a phone has direct advantages: huge deployment base, fast iteration, low user friction, and continuously improving sensors and compute.

For many real-world data collection tasks, we do not always need to build hardware first. If we fully use the sensors and compute already inside a phone, we can close the first experimental loop at very low cost.

Sensor Recorder Pro is a first step in that direction. It starts with the iPhone platform and turns the phone into an out-of-the-box multi-sensor data recorder with exportable data and reproducible sessions.

## 2. Why multi-sensor data matters

Over the past few years, large models have shown the importance of data scale. But for embodied AI, Physical AI, robotics, and XR, internet text, images, and videos are not enough.

These fields need real-world, time-synchronized multimodal data: video, sound, spatial location, motion attitude, and inertial measurements. Such data can support several promising directions.

### 2.1 Embodied AI / Physical AI

Embodied AI needs to understand space, time, action, and interaction in the physical world.

In egocentric AI research, many academic and industrial efforts use neck-mounted or head-mounted phones as capture devices to record daily human behavior, then clean the data and train physical-world models in the cloud. One example is AoE: Always-on Egocentric Human Video Collection for Embodied AI.

Many teams publish papers or datasets, but there are still few easy-to-use, open, modifiable tools for recording raw phone sensor data. Sensor Recorder Pro aims to fill part of this gap by making multi-sensor raw data easier to capture for downstream algorithms.

![Ego-centric data collection reference](docs/images/egocentric-data-collection-reference.png)

### 2.2 Robotics

Robotics algorithms need large amounts of real-scene data. A phone is not a robot by itself, but it can be an excellent low-cost distributed recorder.

For example, a phone can be rigidly attached to a low-cost mobile robot such as a quadruped, wheeled platform, or drone, and used as both a temporary sensor source and compute device.

This makes it possible to validate prototypes quickly and iterate at low cost.

![Phone robot reference](docs/images/phone-robot-reference.png)

### 2.3 XR / AR / VR

XR systems naturally depend on spatial perception, multi-sensor fusion, and user behavior modeling.

Phones today usually include high-level frameworks such as ARKit or ARCore, but for algorithm researchers, these frameworks often expose highly packaged outputs that behave like black boxes.

Sensor Recorder Pro focuses on recording lower-level raw data. On iPhone, multi-camera recording can also conflict with ARKit, so direct raw data capture can be more flexible for custom spatial computing, scene reconstruction, and experimental pipelines.

![AR reference](docs/images/ar-reference.png)

### 2.4 AI glasses / Always-on Agent

AI glasses, AI pins, and always-on agents are becoming increasingly common. Their core idea is that a device continuously observes and understands the real world.

A phone can also be a low-cost starting point for this exploration. For example, it can be mounted on the chest and use an intermittent recording strategy with roughly 10% duty cycle: continuously record low-power audio / GPS, and wake the camera at fixed intervals to capture short video clips.

This can approximate the data shape of always-on hardware and help explore life-long intelligent agent systems.

![iPhone head mount concept](docs/images/iphone-head-mount-concept.png)

### 2.5 Scientific experiments and education

Many physics experiments and motion-analysis tasks, such as acceleration, rotation, environment logging, and engineering education, need high-rate multi-source sensor data.

The phone provides an experiment platform that almost everyone can access. Students and researchers can collect data quickly and then load it into Python, Matlab, or Jupyter Notebook for sensor fusion education and engineering prototyping.

## 3. What is Sensor Recorder Pro?

Sensor Recorder Pro is a multi-sensor recording app designed for algorithm consumption.

The current version focuses on the iPhone platform. It synchronously records multiple data streams and exports them as structured files for reproducible experiments.

### Core features

- Multi-camera video capture: currently supports two iPhone rear cameras. Users can configure camera selection, resolution, frame rate, maximum exposure duration, autofocus, and fixed focus settings. These controls matter for algorithm experiments, because exposure, frame rate, and focus strategy can affect VIO, SLAM, and motion-analysis data quality.
- Audio recording: synchronously records environmental audio for sound event analysis, scene understanding, and multimodal logs.
- IMU recording: records accelerometer and gyroscope data for motion analysis and attitude estimation.
- Device Motion recording: records system-level Motion data, including attitude, rotation, and gravity direction.
- GNSS / Geo trajectory recording: records latitude, longitude, trajectory, and location metadata for outdoor trajectory analysis, travel logs, scene annotation, and spatial data analysis.
- Multi-source timestamps: all streams include two timestamps: monotonic sensor time and UTC time, supporting later alignment, analysis, and algorithm processing.
- Open source code: the project is open source and can be compiled, modified, and extended.

The core problem is simple: make real-world multimodal sensor data easier to capture, export, and use.

## Data format and usage

For developer friendliness, each capture task is saved as an independent session folder using common media files and CSV:

```text
SR_yyyy-MM-dd_HH-mm-ss/
├── meta.json              # Device metadata, capture settings, time model, and file schemas
├── wide.mp4               # Wide camera video stream
├── wide_info.csv          # Per-frame index: sensor_sec, utc_sec, exposure, ISO, resolution, intrinsics
├── ultrawide.mp4          # Ultra-wide camera video stream
├── ultra_info.csv         # Per-frame index: sensor_sec, utc_sec, exposure, ISO, resolution, intrinsics
├── audio.m4a              # Microphone audio stream
├── audio_info.csv         # Audio buffer index: sensor_sec, utc_sec, duration, sample_rate, channels
├── accelerometer.csv      # Raw accelerometer: sensor_sec, utc_sec, ax, ay, az
├── gyroscope.csv          # Raw gyroscope: sensor_sec, utc_sec, gx, gy, gz
├── imu.csv                # Gyro-keyed IMU rows: accel + gyro + alignment timestamps
├── device_motion.csv      # CoreMotion fused attitude: quaternion, roll/pitch/yaw, gravity, user_accel
├── magnetometer.csv       # Raw magnetometer: sensor_sec, utc_sec, mx, my, mz
├── barometer.csv          # Barometer: sensor_sec, utc_sec, pressure, relative_altitude
└── geo_location.csv       # Geo trajectory: sensor_sec, utc_sec, lat, lon, alt, speed, course, accuracy
```

## 4. Open data

I collected some sample data with my own phone. Everyone is welcome to try it.

Link: https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g  
Password: `inv0`

## 5. What comes next

- Support more sensors, such as front camera, LiDAR, and more rear cameras.
- Improve the post-processing toolchain, including one-click packaging into `.rrd`, `.mcap`, and other formats that are easier to distribute and reuse.
- Explore applications of the data, including foundation model training, life-long intelligence, embodied AI, robotics, and XR.

## 6. Summary

Sensor Recorder Pro aims to turn the underestimated phone in everyone's pocket into a low-cost distributed entry point for physical-world AI.

First, record the data reliably. Then let AI truly understand the physical world.

Feedback, testing, and stars are welcome.

App Store: Sensor Recorder Pro  
Open source code: https://github.com/ydsf16/ios_sensor_recorder  
Open data: https://pan.baidu.com/s/1AkZOUvUq2zS3ihPHkEMs9g password `inv0`
