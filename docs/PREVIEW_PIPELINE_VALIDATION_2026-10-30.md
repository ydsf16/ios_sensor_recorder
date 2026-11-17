# 预览与独立写入管线验证（2026-10-30）

本轮只使用 iPhone 12（iPhone13,2，iOS 18.6.1）。用户要求后未再对 iPhone 16 运行测试。本报告随本轮代码改动一并提交；原始录制、截图和 xcresult 保留在本地验证目录，未纳入 Git。

验收结论：Standard 三组持续用例、独立传感器写入及模式切换已通过。ARKit 仍观察到源帧时间戳缺口，不能认定整体达到“持续无缺帧”；最终实现保留真实数据并明确记录/提示质量问题，不能把本报告作为所有模式均无缺帧的发布依据。

## 修复内容

- 每路 RGB/ARKit 预览使用独立的最新帧邮箱；iOS 17 以上使用后台 `sampleBufferRenderer` 队列。预览不用等待录制编码或磁盘，也不再经过“主线程显示 → 采集队列确认”的往返。
- 预览先复制到自己拥有的像素缓冲，再返回 SDK 采集回调。显示使用新的 sample wrapper，保留源时间戳，仅给预览设置 DisplayImmediately；录制样本及时间戳不被修改。邮箱满时只替换过时预览帧。
- 主线程不再递归扫描录制目录大小。目录统计和剩余空间查询移至后台，界面读取缓存。
- 加速度、陀螺仪、配对 IMU、Device Motion、磁力计、气压计、定位 CSV 各有独立串行写入队列。音频、ARKit 视频/位姿、Depth 也各有自己的写入通道；Standard 视频保留逐相机独立编码及写入队列。
- 通道按字节和条目限制积压，入队不等待磁盘。CSV 默认 4MiB/4096 条，音频 8MiB/512 包，ARKit 128MiB/60 帧，Depth 16MiB/64 帧，任一限制先到即报错。实际总内存还包括编码器、像素池及系统分配，不能把这些限制相加当作进程内存上限。
- 某通道写入失败或积压超限时，按用户选择停止整个录制，保留已写数据并完成已接收任务的收尾。结束操作等待所有通道完成关闭后才恢复设置/录制按钮并写最终状态。
- 屏幕分别显示采集 FPS 和预览 FPS。iOS 17.4 以上使用公开渲染器指标估计显示帧率（英文 `Disp~`，中文 `显≈`）；无指标时显示入队 FPS（`Send`/`送`）。它们不是对物理面板刷新率的测量。
- 单相机帧率标签与红色录制统计分行显示，ARKit 同样布局采集/预览帧率标签。
- 每段新增 `performance.csv`，约每秒记录采集、预览入队、渲染估计帧率、渲染器累计丢帧、预览复制失败、最大入队延迟、系统热状态及进程 physical footprint。最终 meta.json 保留预览统计。
- ARKit 写入队列仅接收相机参数的值拷贝，逐帧 autorelease pool 及时释放临时对象。ARKit 源帧缺口记录在 `recording_start.arkit_frame_integrity`，保留缺口前后原始时间戳，结束时提示录制质量；不复制帧或重写时间轴来伪造连续性。它与磁盘失败/缓冲满的致命写入错误分开处理。
- 修复 ARKit → Standard 时旧 ARSession 回调报错的问题；设置期间暂停 ARSession，隔离格式探测，恢复/切换时校验会话身份。当前有效 ARSession 录制失败仍会停止并报告。

## 测试方法与范围

真机测试先安装 App 和 XCTest runner，再以 `UseDestinationArtifacts` 运行，不让测试安装流程重建 App 数据容器。保留原录制文件；测试结束恢复本轮开始前的设置。

持续用例选择三摄/高分辨率极限和双摄中间配置，不遍历所有机型/格式。每段约 90 秒，保留免费版 120 秒限制及付费逻辑。文件检查完整解码视频，核对 CSV 帧数、配置分辨率、真实帧率、连续帧间隔、源 PTS、后摄同步组及前摄时间对应；同时检查音频解码、传感器时间戳和原始加速度负号。

预览性能以 `performance.csv` 稳态样本（去掉前 5 个采样点）的中位数及范围报告。渲染器累计计数可能包含录制前预览，不等同于录制文件帧数。实际视频帧率由文件时间戳独立核算。

## 实测结果

| 用例 | 视频帧数 / 实际 FPS | 预览显示估计中位数 | 稳态内存中位数 | 热状态 |
|---|---|---|---|---|
| Wide + Ultra + Front，1080p60，约 93 秒，含音频/IMU/Motion | 后置各 5600 / 59.957；前置 5596 / 59.905 | 三路 59.92～59.94fps | 136.77MiB | nominal |
| Wide，4K60，约 93 秒，含 IMU/Motion | 5571 / 59.942 | 59.95fps | 185.91MiB | fair |
| Wide + Ultra，4K30，约 93 秒，含 IMU/Motion | 各 2794 / 29.994 | 两路 29.98～29.99fps | 297.97MiB | fair |
| Wide，1080p30，约 28 秒，音频及全部可用运动/定位传感器 | 841 / 30.002 | 30.01fps | 54.74MiB | nominal |
| ARKit 初次短测，1920×1440@30，约 18 秒 | 545 / 29.996，位姿行数一致 | 29.99fps | 153.34MiB | nominal |
| ARKit 最终内部自测，1920×1440@30，约 60 秒 | 1807 / 29.979，**1 个源缺口** | 29.98fps | 150.12MiB | nominal |

以上三组 Standard 长视频全部完整解码通过；配置尺寸、视频/索引帧数、连续索引及 PTS 一致，最大帧间隔均小于目标周期的 1.5 倍。三摄前后传感器的时钟存在微小速率差，前摄帧数不要求等于后摄；每路自身均连续。三摄后置同步组 5600 组、最大偏差约 0.074ms；双路 4K 2794 组、最大偏差约 0.021ms。前后摄最大时间对应误差约 8.4ms，没有宣称前摄硬件同步。

三组长测的预览复制失败、渲染器不就绪、预览邮箱替换、渲染器丢帧/损坏计数均为 0。最大“收到源帧至预览入队”延迟分别约 8.14ms、4.07ms、18.40ms；这不是光子到屏幕的完整端到端延迟。稳态内存范围分别约 135.80～137.17、185.55～186.20、297.61～298.72MiB，未观察到随时间持续增长。4K 用例热状态为 fair，未达到 serious/critical，录制未改变配置。

全传感器用例输出：加速度 2813 行，陀螺仪/配对 IMU/Device Motion 各 2812 行，磁力计 1393 行，气压计 26 行，定位 11 行，音频索引 1317 包。数据有限且时间戳有序；AAC 完整解码通过，实际 44.1kHz 单声道、约 28.17 秒。定位更新频率由系统决定，不承诺固定频率。原始加速度负号与 Device Motion 对照检查通过。ARKit 545 个姿态均为 normal，变换数值有限，视频和姿态时间一致。

主机受控阻塞测试通过：一个通道被阻塞时另一通道仍能执行；超限立即拒绝并报告；已接收任务保持 FIFO，关闭等待其完成，抛出的磁盘错误带通道标识回传。另有 22 个采集/文件校验 Python 测试通过。

真机 XCTest：独立音频/传感器、ARKit 独立写入、三组持续测试及收尾锁定均通过。最终版本还对音频/传感器、ARKit ↔ Standard 两轮切换及收尾锁定进行回归，三项全部通过。持续用例之后调整 performance.csv 观测通道的队列所有权，并修正单相机帧率 HUD 与录制统计重叠及 ARKit HUD 布局。录制和预览算法未再变化；HUD 二进制的 ARKit 和 4K60 短测界面测试也通过，原生截图确认统计文字互不遮挡。前 11 项真机 XCTest 均通过；其后文件审查发现 ARKit 短测有一个时间槽缺口，不能据此认定无丢帧，处理与复测见下节。所有新测试数据另行保留。最终内部自测结束后已再次恢复原设置并回读 JSON，内容与测试前完全一致，App 已正常重新打开，保留原有录制目录。

本轮证据位于 `.codex-baseline/preview-isolation-validation/`：

- `independent-writers.xcresult`、`sustained-pipeline.xcresult`、`final-pipeline-regression.xcresult`、`final-hud-verification.xcresult`。
- `pipeline-short-validation.json`、`triple-sustained-validation.json`、`wide4k-sustained-validation.json`、`rear4k-sustained-validation.json`、`pipeline-recordings/arkit-file-validation.json`、`final-regression-file-validation.json`、`final-hud-file-validation.json`。
- `sustained-performance-summary.json`、`pipeline-evidence-index.json` 和各录制目录中的 `performance.csv` / `meta.json`。
- `final-arkit-strict-validation.json` 与 `final-arkit-format-validation.json` 分别记录最终 ARKit 连续性未达标、保留数据格式通过的结果。
- 最终 HUD 原生截图 `final-wide4k-hud.png`、`final-arkit-hud.png`；恢复原设置后的中文界面截图 `restored-final-preview.png`。
- 原生截图 `triple-sustained-preview.png` 显示录制 1分19秒时三路仍约 60fps；`wide4k-sustained-preview.png` 为 4K60 录制观察截图。

没有保留改动前同环境的严格 A/B 性能基准，因此不报告百分比提速，也不把这些选定用例扩大为所有设备/环境的保证。

## 过程中发现并修正的回归

第一版预览邮箱保留 SDK 原始像素缓冲，三摄 60fps 实测出现 `OutOfBuffers`（同步输出 reason=2），安全停止录制。该方案已删除，改为在采集回调返回前复制像素。修复后先通过 4K60 和三摄 1080p60 短测，再进行本报告的持续测试。没有把这个失败当作通过，也没有忽略采集丢帧错误。

失败证据：`.codex-baseline/preview-isolation-validation/recordings.xcresult`；`failed-evidence/initial-preview-meta.json` 中 `state=failed`，`recording_start.failure` 保存缺失相机及 reason=2。

### ARKit 连续性与质量边界

HUD 短测文件 `SR_2026-10-30_08-07-28` 虽通过界面测试，但严格审查发现 slot 421 → 423，间隔 66.675ms，零缺帧结果为 FAIL。初次 ARKit 独立写入 545 帧用例没有该缺口。新增 `tools/validate_arkit_capture.py`，默认检查连续目标槽、完整解码、位姿有限值/四元数、配置尺寸、PTS 及性能 CSV；使用 `--allow-source-gaps` 时仅认证保留数据的格式/对应关系，明确输出缺口数量，不代表无缺帧通过。

曾用“遇源缺口即停止”的试验策略定位问题：全传感器用例约 14.4 秒出现缺口，前 432 帧完整解码、索引连续，15 行性能 CSV 及传感器/音频文件保留（`arkit-safe-stop-validation.json`）。单相机内部自测同样出现约 66.676ms 的源时间戳缺口，预览复制/渲染丢帧计数为 0。相机参数值拷贝和逐帧临时对象释放之后仍观测到缺口，不能声称根因已修复，也不能断言是某一路传感器、磁盘或 Apple SDK 的问题。

该“源缺口即停止”试验策略未作为最终行为保留。用户选择的全局停止策略针对写入失败/缓冲满；最终对 ARKit 源时间戳缺口保留全部可用帧，并将数量与前 32 个事件写入 meta.json、结束时显示中英文质量提示，免费录制到时的提示保留升级/恢复购买入口并附带质量信息。写入失败/缓冲满仍停止整个录制，ARSession 真正报错仍停止。零缺帧校验继续把有源缺口的样本判为未达标。

后续 XCTest 要求重新输入自动化密码，该次未运行测试。已扩展现有 DEBUG 内部自测入口，直接以 SDK 查询的 ARKit 格式运行真实录制、预览和收尾流程，不调用系统 UI 自动化服务。最终纯相机内部自测 `SR_2026-10-30_08-33-08` 完成约 60 秒录制与收尾，1807 帧/位姿完整解码且一一对应，实测 29.979fps，61 行性能 CSV，所有姿态 normal。出现 1 个源目标槽缺口（727 → 729，缺少 728），最大间隔 66.676ms；meta 计数与 CSV 一致，未重采样时间戳。预览显示估计中位数约 29.98fps、内存约 150.12MiB、热状态 nominal。

严格零缺帧结果为 FAIL（`final-arkit-strict-validation.json`）；保留数据的格式/位姿对应检查为 PASS_FORMAT_WITH_SOURCE_GAPS（`final-arkit-format-validation.json`）。最终质量策略、性能 CSV 和写入收尾已在该二进制中实测，不能把原始源缺口描述成已经消失。

复现命令：

```sh
python3 tools/validate_arkit_capture.py SESSION --ffprobe .tools/bin/ffprobe --output strict.json
python3 tools/validate_arkit_capture.py SESSION --allow-source-gaps --ffprobe .tools/bin/ffprobe --output format.json
```

## 已知验证边界

- 当前 iPhone 12 没有 LiDAR：Depth 仅调整写入隔离与缓冲所有权，保留采样及文件格式策略；已编译，未进行 LiDAR 真机验证。
- iOS 15/16 保留主线程显示 API 加有界邮箱的兼容路径，本轮未在这些系统运行。
- 已做受控阻塞/抛错/缓冲超限的主机测试，未破坏性填满手机存储，也未进行数小时热机或后台长时录制测试。
- 前后摄混合组合仍只保证后置子集硬件同步，前摄采用时间戳对应；未扩大硬件同步承诺。
- 预览线程、传感器队列仍共享 CPU、内存带宽和物理存储。隔离队列可以避免直接串行等待，无法保证资源耗尽时各流永不受影响；此时按失败策略停止。

## Apple 公开 API 依据

- [sampleBufferRenderer：支持后台入队](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)
- [enqueue：预览立即显示附件](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))
- [AVVideoPerformanceMetrics：渲染性能指标](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics)
- [ARFrame：通过 ARSession delegate 接收帧](https://developer.apple.com/documentation/arkit/arframe)
