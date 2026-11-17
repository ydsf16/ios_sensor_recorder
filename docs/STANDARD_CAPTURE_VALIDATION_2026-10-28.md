# SensorRecorderPro 设置与采集改造验收记录

日期：2026-10-28 至 2026-10-29。基线：`release` 分支 `f5d94c1`（1.5 build 5）。改动尚未提交或推送。

**状态：本轮开发、真机遍历及最终 Release 安装检查已完成，交由用户验收。673 种配置均取得解码通过的录制样本；首次遍历有两次原生同步组失败，复测通过但首次原因未定位，详见下文风险项。不能把结果表述为“首次遍历零失败”。**

## 本轮要求与实现

- 设置页竖屏，保留原深色样式；采集页横屏。按镜头组合、统一采集参数、对焦、Depth/传感器、账户组织。原 StoreKit 购买、恢复购买和免费 120 秒录制限制保留，不伪造 Premium。
- 本版本设置页最高 60fps。60 是产品上限，不代表所有组合/分辨率均支持 60。已有超过上限或不兼容的配置明确要求重新选择，录制启动时不偷偷降帧、降分辨率或关闭镜头。
- 切换分辨率会同时更新对应 SDK 帧率选项。原帧率仍联合可用就保留；否则在设置阶段选最近的可用较低档，没有较低档时选最低可用档。两个值一并更新到草稿，保存前再次联合检查；这不允许录制启动后改变规格。
- 设备、并发输入集合、视频格式与帧率范围来自 AVFoundation SDK。菜单由真实 SDK 范围与联合配置检查生成，不维护逐机型白名单、黑名单或历史失败隐藏表。SDK 返回连续范围时，界面提供范围内的常用档位与原生端点。
- 联合检查包含输入、物理/虚拟镜头端口、输出连接、格式、固定帧间隔、`hardwareCost`/`systemPressureCost` 不超过 1，以及同时建立所有硬件编码会话的可行性。输出像素格式也从 SDK 列表选择。
- 保存时实际配置预览，等待每路真实样本确认尺寸，再写入设置；录制时复核冻结格式与帧间隔。不重新搜索低规格替代方案。
- 不加高级覆盖。各 RGB 镜头统一分辨率、帧率、曝光策略；单镜头只在 SDK 支持时提供手动 Focus Position。同步组合统一自动对焦或锁定当前焦点，不提供逐镜头手动位置。
- 后置镜头通过虚拟相机组成端口实现硬件同步。前摄独立采集原始帧，并导出最近时间戳对应索引；不承诺前后摄曝光瞬间同步。选择混合组合时弹窗说明范围，取消不修改草稿，设置中持续显示同步方式。
- Standard 录制不使用软件时间网格，不通过补帧、删帧或重新计时制造同步。每路使用独立编码与文件写入队列；后置硬件组保留共同组号，所有多摄电影使用共同时间原点。
- 原始加速度三轴导出为 `-CoreMotionAcceleration × 9.80665`，用于 accelerometer.csv 和 imu.csv；陀螺仪与融合 DeviceMotion 保持原符号。
- LiDAR Depth 不在本轮优化/真机验证范围。保留 Release 自动深度格式与 10Hz 路径，不新增 Depth 分辨率/帧率设置。当前 iPhone 12 无 LiDAR；Depth 与新多摄硬件同步联动不作为已验证能力。

## 关键问题与修复

1. **测试自身占用编码器。** XCTest 默认自动录制手机屏幕，会额外使用编码资源，干扰相机吞吐测试。原先据此推导的机型限制不成立，相关硬编码与失败隐藏逻辑已删除。测试 Scheme 改为 `preferredScreenCaptureFormat="screenshots"`，实际诊断日志已确认使用截图；主线程检查保留默认设置。所有最终吞吐证据均以关闭自动录屏后的结果为准。
2. **测试脚本假阳性。** 原脚本只检查开始、结束状态，提前失败后可能再次启动录制并把测试判为通过。现在每 0.5 秒检查仍在录制且没有错误；验收还必须检查文件最终状态并逐帧解码，不能只看 XCTest 的 PASS。
3. **写入与采集缓冲耦合。** 使用 SDK 硬件编码器及其像素缓冲池，编码队列和磁盘写入队列独立。编码输出后的元数据不再持有原始像素，压缩数据也有有界队列。准备期间积压的旧预览帧不纳入新录制。
4. **电影时间原点精度。** 仅设置视频轨道 1MHz 仍会被默认电影刻度舍入。现电影与轨道均为 1MHz；校验要求多摄共同原点误差小于 5µs。
5. **输入端口的启动状态。** 部分端口启动后 `formatDescription` 仍可能为 nil；改为等待每路真实样本验证尺寸，避免把合法前后摄组合误判为失败。
6. **前摄不能按后置完整同步组处理。** 前摄独立交付，后置 `AVCaptureDataOutputSynchronizer` 只处理真实硬件组；对应索引引用已有帧，不修改视频。校验区分重叠录制区间和首尾边界，保留独立相机合法的不等帧数。
7. **外参单位。** SDK 平移单位为毫米，导出声明为米；已除以 1000。iPhone 12 后置两摄基线实测约 0.014282m。
8. **失败状态与界面竞态。** 写入/编码错误明确传播，录制失败立即保存失败状态。准备、录制和最终写入完成前锁住设置/文件入口；设置关闭完成后才允许再次打开。购买状态更新不会清空设置草稿。
9. **音频时钟转换。** 开启音频后，SDK 同步时钟到 host clock 的相关关系会更新。原先同步索引在采集时转换、镜头索引在异步写入时再次转换，同一帧最多差约 21µs。现在在采集接纳时转换一次并共用该值；镜头 CSV 新增 `capture_pts_sec` 保留转换前的原始 SDK PTS，分别用于媒体时间验证与 host clock 传感器融合。两段新音频录制均解码通过，原始 PTS 与电影误差约 0.5µs。保留旧失败文件作复现证据。
10. **后台防护与测试动作。** 设备忽略了合成 Home 事件，早期“仍在录制”的测试不能证明生产逻辑有错。最终改为启动系统设置并断言采集 App 确实离开前台；真实后台中断测试通过。同时补充 Scene 进入后台时的主动停止、有限后台写入收尾任务及回到前台后的提示，避免仅依赖相机会话通知。

## 当前真机证据

设备：iPhone 12（iPhone13,2），iOS 18.6.1，USB。XCTest 真正安装、操作设置并录制。未执行真实支付交易、未修改账户权益。

证据根目录：`.codex-baseline/standard-automation/iphone12-validation/`。

| 检查 | 当前结果 | 证据 |
|---|---|---|
| SDK 设备与组合查询 | Wide、Ultra、Front 的三种单摄、三种双摄及三摄输入均可建立；支持后置 DualWide 虚拟设备加 Front | hardware-combinations-inspection-2.xcresult、hardware-combinations.json |
| 当前高负载回归 | 4/4 UI 持续检查通过，4/4 实际文件解码通过 | no-video-encoder-regression.xcresult、no-video-regression/file-validation.json |
| Wide 4K60 | 1983 帧，约 59.94151fps，最大帧间隔 16.684ms，PTS 误差约 1µs | no-video-regression/SR_2026-10-28_13-44-57 |
| Wide + Front 4K30 | 各 380 帧，约 30.00223 / 29.99873fps；最近对应最大差 18.934ms，重叠区间最大差 14.396ms | no-video-regression/SR_2026-10-28_13-45-58 |
| Wide + Ultra 4K30 | 386 个完整硬件组，约 29.99435fps，最大后置时间差 21.25µs | no-video-regression/SR_2026-10-28_13-46-28 |
| Wide 1080p60 | 792 帧，约 59.94151fps，PTS 误差约 1µs | no-video-regression/SR_2026-10-28_13-47-19 |
| 全候选遍历 | 初次 671 PASS / 2 FAIL；两项短录及长录复测均通过，673 种配置都有成功样本。去重覆盖 972 路视频、75,858 帧，所有候选不超过 60fps | sdk60-matrix/file-validation.json、sdk60-sync-retry/file-validation.json、sdk60-coverage-summary.json |
| 最终 SDK 目录一致性 | 673 项，与原矩阵配置键完全一致，最高 60fps | sdk60-final-catalogue.json、sdk60-catalogue-parity.json |
| 免费 120 秒 | 后置双路 4K30 自动停止并显示免费时限弹窗，Upgrade / Restore Purchase 入口存在；实际文件 PASS，两路各 3598 帧、约 29.99439fps | sdk60-final-ui-regression.xcresult、sdk60-ui-files/free120-file-validation.json |
| 音频及联动控制 | 两段 AAC 音频和双摄文件均 PASS；自动对焦/5ms 上限及锁定焦点/20ms 上限分别核对，硬件组最大时间差约 80µs | sdk60-ui-files/audio-clock-fix-validation.json |
| 三摄 60 秒、单摄手动对焦、写入期间锁定设置 | UI 与实际文件 PASS，三摄合计 5651 帧；手动位置持久化检查通过 | sdk60-ui-files/remaining-ui-files-validation.json、sdk60-final-ui-regression.xcresult |
| 分辨率与 FPS 自动兼容 | UI 及四段文件全部 PASS：单摄 4032×3024@30 / 1080p60，双摄 4K30 / 1080p60；高分辨率不再错误沿用 60，切回低分辨率保留可用的 30 | sdk60-resolution-dependency.xcresult、sdk60-ui-files/resolution-dependency-file-validation.json |
| 48/50fps 长录复测 | 两种对焦状态共八段 30 秒录像均 UI 与文件 PASS。其中四段明确使用首次遍历的自动对焦与 10ms 曝光上限 | sdk60-ui-files/long-and-high-rate-clock-fix-validation.json、exact-policy-long-validation.json |
| 真实后台中断 | UI PASS；文件标记 failed、原因明确为中断；两路各 127 帧、640×480@30，均可解码且索引和完整硬件组数量相同 | sdk60-verified-background.xcresult、sdk60-ui-files/background-interruption-file-validation.json |
| 同步提示取消 | PASS，取消后保留原组合 | sdk60-overlay-safe-interactions.xcresult、sdk60-background-fix.xcresult 中对应测试 |
| 最终 Release 包 | 签名构建、同 Bundle ID 安装完成；单摄 1080p60、后置双摄 720p30 的 UI 与实际文件检查均 PASS | sdk60-release-install-smoke-2.xcresult、release-installed-ui-summary.json、sdk60-ui-files/release-installed-file-validation.json |
| 本地检查 | 17 项 SDK 帧率/上限/自动兼容检查、17 项文件校验器正反例、像素复制与时间戳保留、时间对应索引检查通过；git diff --check 通过 | tools/tests/ |

遍历入口使用设置页同一候选生成器、联合检查器和实际采集/写入路径；仅在 DEBUG 编译，不持久化矩阵测试配置，也不绕过免费时限。每项至少约 3 秒，低帧率延长至约 8 帧。复制文件后实际解码核对状态、尺寸、帧数、配置/测得 FPS、原始 PTS、间隔、硬件组、共同电影原点、对应索引及 IMU 数值与符号。

旧矩阵与原先有自动录屏的性能失败记录保留作诊断历史，不能作为当前版本的容量边界或最终通过证据。其他机型通过同一 SDK 逻辑发现能力，本轮真机证据仅来自这台 iPhone 12。

## 结果解释与验收风险

- 首次遍历的后置 1920×1440@48/50 各出现一次同步组不完整。App 中止录制并写入失败状态，没有静默降级或把缺组文件标为成功。两次短录、八次 30 秒长录均未复现，包括与首次遍历相同的自动对焦和 10ms 曝光上限。首次没有详细的 SDK 丢弃原因记录，因此不能宣称已查明根因；已补充 droppedReason 和时间戳诊断，保留原失败文件。没有据此隐藏这两个 SDK 可行选项。
- 全候选“都有成功样本”证明这台手机上的配置可录，不等于首次 673 项全部成功，也不等于任何机型或任何运行条件下绝对零丢帧。运行中真实丢帧、队列溢出或系统中断会明确失败，不会改变用户所选规格。
- 最新 SDK 目录仍为 673 项，与原矩阵配置键集合完全一致，最高 60fps。原先 329 项、364 路视频已补查容器平均 FPS，后续文件校验直接包含该检查；全部通过。
- 早期若干 UI 测试在传感器开关步骤失败：辅助触控悬浮按钮拦截中心点击，使 App 返回桌面。测试改为点击开关未被遮挡的前缘，未关闭用户的辅助功能。后台场景另以启动系统设置证明真实后台。对应场景最终通过，不能把旧失败 bundle 整体称为绿色。
- 真机证据仅来自 iPhone 12。其他设备通过相同 SDK 查询与联合配置逻辑发现能力，没有机型名单。LiDAR、Telephoto 真机录制和实际 App Store 付款/恢复交易未在本机验证；付费管理实现与基线一致，购买入口及真实免费时限已验证。

## 交付与手机状态

- 手机安装的是最终签名 Release 包；构建路径 `/tmp/SensorRecorder-release-validation/Build/Products/Release-iphoneos/SensorRecorder.app`。Release 不包含 DEBUG 遍历入口。
- 手机停留在最后验证的 Wide + Ultra Wide、1280×720@30 配置，便于验收。完整测试前设置已保存在证据目录 `settings-before.json`，测试后设置为 `settings-after-release-tests.json`。原设置中的三摄 4K30 不在当前 SDK 联合可行目录中，因此没有重新写回无法录制的配置；这次测试选择已明确列出，不是录制器自动降级。
- 未删除手机已有录制文件；测试文件和失败历史均保留。未卸载应用、未伪造购买权益。
- 主要新增模块为 CaptureRateOptions、MultiCameraCaptureGraph、CaptureSampleStorage、RealtimeVideoEncoder 和 TimestampAlignment；移除 Standard 的软件网格、静默格式降级及废弃 UI 帮助代码。源码和自动化测试均在当前工作区，尚未 commit/push。

## 官方依据与复现

- [Apple：设备允许的多摄集合](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession/supportedmulticamdevicesets)。
- [Apple：多摄硬件预算](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession/hardwarecost)。
- [Apple：Introducing Multi-Camera Capture for iOS](https://developer.apple.com/videos/play/wwdc2019/249/)；虚拟相机组成镜头的硬件同步和联动控制，区别于软件交付同步。
- [Apple：视频输出像素格式](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/availablevideopixelformattypes)。
- [Apple：输出支持的文件编码器](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/availablevideocodectypesforassetwriter(writingto:))。
- [Apple：测试计划及自动屏幕采集选项](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)。

```bash
python3 tools/validate_capture.py /absolute/path/to/SR_session --ffprobe /absolute/path/to/ffprobe
python3 tools/tests/test_capture_validation.py -v
swiftc SensorRecorder/CaptureRateOptions.swift tools/tests/capture_rate_options_tests.swift -o /tmp/sensor-rate-checks
/tmp/sensor-rate-checks
swiftc SensorRecorder/CaptureSampleStorage.swift tools/tests/capture_sample_storage_tests.swift -o /tmp/sensor-storage-checks
/tmp/sensor-storage-checks
```
