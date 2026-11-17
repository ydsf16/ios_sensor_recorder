# iPhone 16 抽样验证 — 2026-10-29

设备：YJJY，iPhone 16（iPhone17,3），USB 真机；SDK 查询和录制采用当前代码的 Debug 包。用户要求采用极限与中间案例，不做全量录制遍历。

## SDK 能力

SDK 目录查询通过，共 668 项配置，最高 60fps。Wide 145、Ultra Wide 145、Front 134、Wide+Ultra Wide 63、Wide+Front 63、Ultra Wide+Front 63、三摄 55。本机无独立 Telephoto，无四摄与 LiDAR 验证条件。

## 文件校验

逐路解码核对尺寸、配置/实测帧率、视频与索引时间戳、帧间隔、硬件同步组、前摄对齐标记及 IMU 加速度取负号。

| 录制 | 流与实际结果 | 校验 |
| --- | --- | --- |
| SR_2026-10-29_22-49-40 | wide 640x480 / 30fps → 29.990fps；front 640x480 / 30fps → 29.997fps | PASS |
| SR_2026-10-29_22-50-10 | ultrawide 640x480 / 30fps → 29.997fps；front 640x480 / 30fps → 29.997fps | PASS |
| SR_2026-10-29_22-51-02 | wide 640x480 / 30fps → 29.990fps；ultrawide 640x480 / 30fps → 29.990fps | PASS |
| SR_2026-10-29_22-51-40 | wide 3840x2160 / 60fps → 59.980fps | PASS |
| SR_2026-10-29_22-52-44 | wide 1920x1080 / 60fps → 59.980fps | PASS |
| SR_2026-10-29_22-55-34 | wide 3840x2160 / 30fps → 29.977fps；ultrawide 3840x2160 / 30fps → 29.977fps | PASS |
| SR_2026-10-29_22-57-34 | wide 1920x1080 / 30fps → 29.990fps；ultrawide 1920x1080 / 30fps → 29.990fps；front 1920x1080 / 30fps → 29.997fps | PASS |

三摄采用 1920×1080@30、持续录制 60 秒（测试辅助操作会增加文件时长）。后置 Wide+Ultra Wide 硬件同步；Front 独立录制，按原始时间戳对齐，并非三路硬件同步。

## XCTest 与限制

相机组合排序、后置双摄基础录制、单摄 1080p60、单摄 4K60、后置双摄 4K30、三摄持续录制均完成验证。首次含前摄组合用例完成两段双摄后，在三摄配置的同步说明大小写断言处误报；已将断言改为不区分大小写并通过测试构建，此断言修改尚未单独重跑。三摄持续用例第一次在打开设置页时超时，单独重试通过（triple-retry.xcresult）。保留原失败证据，不将整批 XCTest 标记为全绿。

没有覆盖全部 668 项录制或其他设备，也没有验证长期热压力与四摄。这些抽样通过不构成所有配置永久无丢帧的保证。

## 数据与证据

证据目录：`.codex-baseline/iphone16-validation/`。SDK：profiles.json、hardware.json；文件校验：recording-validation.json；实际录制：recordings/；XCTest：sdk-discovery.xcresult、recording-smoke.xcresult、limits-and-triple.xcresult、triple-retry.xcresult。

Library 已备份。旧 Documents 复制到 pre-debug-backup/Documents 时发现一个旧目录的 ultra_info.csv 无法读取，故该备份不完整。未删除设备旧数据；测试前后顶层目录清单无缺失。测试新增录制已复制到本机。未提交或推送代码。
