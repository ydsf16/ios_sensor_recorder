#!/usr/bin/env python3
"""Convert a SensorRecorder capture directory to Rerun RRD.

Camera timing comes from `*_info.csv`: each decoded frame is placed on the
`sensor_time` timeline using the recorded `sensor_sec`.
"""

from __future__ import annotations

import argparse
import csv
import math
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


CAMERA_STREAMS = {
    "ultrawide": ("ultrawide.mp4", "ultra_info.csv"),
    "wide": ("wide.mp4", "wide_info.csv"),
    "telephoto": ("telephoto.mp4", "tele_info.csv"),
    "front": ("front.mp4", "front_info.csv"),
}

SENSOR_FILES: dict[str, list[str]] = {
    "accelerometer.csv": ["ax_m_s2", "ay_m_s2", "az_m_s2"],
    "gyroscope.csv": ["gx_rad_s", "gy_rad_s", "gz_rad_s"],
    "imu.csv": ["ax_m_s2", "ay_m_s2", "az_m_s2", "gx_rad_s", "gy_rad_s", "gz_rad_s"],
    "device_motion.csv": [
        "qw",
        "qx",
        "qy",
        "qz",
        "roll",
        "pitch",
        "yaw",
        "gravity_x_m_s2",
        "gravity_y_m_s2",
        "gravity_z_m_s2",
        "user_accel_x_m_s2",
        "user_accel_y_m_s2",
        "user_accel_z_m_s2",
        "rotation_rate_x_rad_s",
        "rotation_rate_y_rad_s",
        "rotation_rate_z_rad_s",
        "heading_deg",
    ],
    "magnetometer.csv": ["mx_uT", "my_uT", "mz_uT"],
    "barometer.csv": ["pressure_kpa", "relative_altitude_m"],
    "geo_location.csv": [
        "latitude",
        "longitude",
        "altitude",
        "horizontal_accuracy_m",
        "vertical_accuracy_m",
        "speed_m_s",
        "course_deg",
    ],
    "audio_info.csv": ["duration_sec", "sample_count", "sample_rate_hz", "channels"],
}

SENSOR_ENTITY_NAMES = {
    "geo_location.csv": "geo",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a SensorRecorder SR_* directory to Rerun .rrd."
    )
    parser.add_argument("capture_dir", type=Path, help="Path to an SR_yyyy-MM-dd_HH-mm-ss directory.")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output .rrd file. Defaults to <capture_dir>.rrd.",
    )
    parser.add_argument(
        "--app-id",
        default="sensor_recorder",
        help="Rerun application id.",
    )
    parser.add_argument(
        "--drop-nonfinite",
        action="store_true",
        help="Skip NaN/inf scalar values instead of logging them.",
    )
    parser.add_argument(
        "--jpeg-quality",
        type=int,
        default=90,
        help="JPEG quality for decoded video frames logged into Rerun.",
    )
    parser.add_argument(
        "--video-fps",
        type=float,
        default=5.0,
        help="Maximum video image rate written to Rerun. Use 0 to write every frame.",
    )
    parser.add_argument(
        "--depth-pixel-stride",
        type=int,
        default=2,
        help="Pixel stride for LiDAR point clouds. Use 1 for full-resolution points.",
    )
    return parser.parse_args()


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    header_index = next(
        (i for i, line in enumerate(lines) if line.strip() and not line.startswith("#")),
        None,
    )
    if header_index is None:
        return []

    reader = csv.DictReader(lines[header_index:])
    return [row for row in reader if row and row.get("sensor_sec")]


def parse_float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result


def seconds_to_ns(seconds: float) -> int:
    return int(round(seconds * 1_000_000_000))


def numeric_rows(rows: Iterable[dict[str, str]], fields: Iterable[str]) -> dict[str, list[tuple[float, float, float]]]:
    values: dict[str, list[tuple[float, float, float]]] = {field: [] for field in fields}
    for row in rows:
        sensor_sec = parse_float(row.get("sensor_sec"))
        utc_sec = parse_float(row.get("utc_sec"))
        if sensor_sec is None:
            continue
        if utc_sec is None:
            utc_sec = math.nan
        for field in fields:
            value = parse_float(row.get(field))
            if value is not None:
                values[field].append((sensor_sec, utc_sec, value))
    return values


def default_output_path(capture_dir: Path) -> Path:
    return capture_dir.with_suffix(".rrd")


def convert_to_rerun(
    capture_dir: Path,
    output_path: Path,
    app_id: str,
    drop_nonfinite: bool,
    jpeg_quality: int,
    video_fps: float,
    depth_pixel_stride: int,
) -> None:
    try:
        import numpy as np
        import rerun as rr
    except ImportError as exc:
        raise SystemExit(
            "Missing dependency. Install with: python3 -m pip install rerun-sdk numpy"
        ) from exc

    rr.init(app_id)
    rr.save(str(output_path))
    send_default_blueprint(rr)
    recording_window = recording_sensor_window(capture_dir)

    meta_path = capture_dir / "meta.json"
    if meta_path.exists():
        rr.log("metadata/meta_json", rr.TextDocument(meta_path.read_text(encoding="utf-8")), static=True)
    audio_path = capture_dir / "audio.m4a"
    if audio_path.exists():
        rr.log(
            "metadata/audio_m4a",
            rr.TextDocument(
                f"source_file: {audio_path}\n"
                "waveform: /audio_m4a/waveform\n"
                "note: Rerun has no native audio player in this SDK; the waveform is decoded from audio.m4a."
            ),
            static=True,
        )
    log_lidar_depth_metadata(rr=rr, capture_dir=capture_dir)

    for camera_name, (video_name, info_name) in CAMERA_STREAMS.items():
        video_path = capture_dir / video_name
        info_path = capture_dir / info_name
        rows = read_csv_rows(info_path)
        if not video_path.exists() or not rows:
            continue

        entity = f"camera/{camera_name}"
        logged_rows = log_video_frames(
            rr=rr,
            np=np,
            video_path=video_path,
            rows=rows,
            entity=entity,
            jpeg_quality=jpeg_quality,
            video_fps=video_fps,
        )

        log_scalar_columns(
            rr=rr,
            np=np,
            rows=logged_rows,
            base_path=f"{entity}/frame_info",
            fields=["record_slot", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"],
            drop_nonfinite=drop_nonfinite,
        )

    log_lidar_depth(rr=rr, np=np, capture_dir=capture_dir, pixel_stride=depth_pixel_stride)

    for file_name, fields in SENSOR_FILES.items():
        rows = read_csv_rows(capture_dir / file_name)
        if not rows:
            continue

        if file_name == "geo_location.csv":
            log_scalar_columns(
                rr=rr,
                np=np,
                rows=rows,
                base_path="sensors/geo_raw",
                fields=fields,
                drop_nonfinite=drop_nonfinite,
            )
            if recording_window is not None:
                rows = filter_rows_to_sensor_window(rows, recording_window)
                if not rows:
                    continue
            log_geo_relative_columns(rr=rr, np=np, rows=rows, base_path="sensors/geo_relative")

        entity_name = SENSOR_ENTITY_NAMES.get(file_name, Path(file_name).stem)
        base_path = f"sensors/{entity_name}"
        log_scalar_columns(
            rr=rr,
            np=np,
            rows=rows,
            base_path=base_path,
            fields=fields,
            drop_nonfinite=drop_nonfinite,
        )

    log_audio_waveform(rr=rr, np=np, capture_dir=capture_dir)


def send_default_blueprint(rr: Any) -> None:
    try:
        import rerun.blueprint as rrb
    except ImportError:
        return

    rr.send_blueprint(
        rrb.Blueprint(
            rrb.Vertical(
                rrb.Horizontal(
                    rrb.Spatial2DView(name="Ultra Wide", origin="/camera/ultrawide"),
                    rrb.Spatial2DView(name="Wide", origin="/camera/wide"),
                    rrb.Spatial2DView(name="Telephoto", origin="/camera/telephoto"),
                    rrb.Spatial2DView(name="Front", origin="/camera/front"),
                    rrb.Spatial2DView(name="Depth", origin="/lidar/depth/image"),
                    column_shares=[1, 1, 1, 1, 1],
                ),
                rrb.Spatial3DView(name="LiDAR Point Cloud", origin="/lidar/depth/points"),
                rrb.Horizontal(
                    rrb.Vertical(
                        rrb.TimeSeriesView(
                            name="IMU accel XYZ",
                            origin="/sensors/imu",
                            contents=[
                                "/sensors/imu/ax_m_s2",
                                "/sensors/imu/ay_m_s2",
                                "/sensors/imu/az_m_s2",
                            ],
                        ),
                        rrb.TimeSeriesView(
                            name="IMU gyro XYZ",
                            origin="/sensors/imu",
                            contents=[
                                "/sensors/imu/gx_rad_s",
                                "/sensors/imu/gy_rad_s",
                                "/sensors/imu/gz_rad_s",
                            ],
                        ),
                        rrb.TimeSeriesView(
                            name="audio.m4a waveform",
                            origin="/audio_m4a",
                            contents="/audio_m4a/waveform",
                        ),
                        row_shares=[1, 1, 1],
                    ),
                    rrb.Vertical(
                        rrb.TimeSeriesView(
                            name="Attitude RPY",
                            origin="/sensors/device_motion",
                            contents=[
                                "/sensors/device_motion/roll",
                                "/sensors/device_motion/pitch",
                                "/sensors/device_motion/yaw",
                            ],
                        ),
                        rrb.TimeSeriesView(
                            name="Geo ENU",
                            origin="/sensors/geo_relative",
                            contents=[
                                "/sensors/geo_relative/east_m",
                                "/sensors/geo_relative/north_m",
                                "/sensors/geo_relative/up_m",
                                "/sensors/geo_relative/horizontal_accuracy_m",
                            ],
                        ),
                        row_shares=[1, 1],
                    ),
                    column_shares=[1, 1],
                ),
                row_shares=[3, 3, 5],
            ),
            collapse_panels=True,
        )
    )


def log_video_frames(rr: Any, np: Any, video_path: Path, rows: list[dict[str, str]], entity: str, jpeg_quality: int, video_fps: float) -> list[dict[str, str]]:
    width = int(float(rows[0].get("width_px", "0") or 0))
    height = int(float(rows[0].get("height_px", "0") or 0))
    if width <= 0 or height <= 0:
        raise SystemExit(f"Missing width_px/height_px in frame CSV for {video_path}")

    frame_bytes = width * height * 3
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(video_path),
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    assert process.stdout is not None

    decoded_count = 0
    logged_rows: list[dict[str, str]] = []
    min_frame_interval = 1.0 / video_fps if video_fps and video_fps > 0 else 0.0
    next_log_sensor_sec: float | None = None
    try:
        for row in rows:
            payload = process.stdout.read(frame_bytes)
            if len(payload) != frame_bytes:
                break

            sensor_sec = parse_float(row.get("sensor_sec"))
            utc_sec = parse_float(row.get("utc_sec"))
            if sensor_sec is None:
                continue

            should_log = next_log_sensor_sec is None or sensor_sec + 1e-9 >= next_log_sensor_sec
            if should_log:
                frame = np.frombuffer(payload, dtype=np.uint8).reshape((height, width, 3))
                rr.set_time("sensor_time", duration=sensor_sec)
                if utc_sec is not None and math.isfinite(utc_sec):
                    rr.set_time("utc_time", timestamp=utc_sec)
                rr.log(entity, rr.Image(frame).compress(jpeg_quality=jpeg_quality))
                logged_rows.append(row)
                next_log_sensor_sec = sensor_sec + min_frame_interval if min_frame_interval > 0 else sensor_sec
            decoded_count += 1

        while process.stdout.read(1024 * 1024):
            pass
    finally:
        process.stdout.close()
        return_code = process.wait()

    if return_code != 0:
        raise SystemExit(f"ffmpeg failed while decoding {video_path}")
    if decoded_count != len(rows):
        print(
            f"warning: {video_path.name} decoded frames ({decoded_count}) != CSV rows ({len(rows)})",
            file=sys.stderr,
        )
    if len(logged_rows) != decoded_count:
        print(
            f"info: logged {len(logged_rows)} of {decoded_count} decoded frames for {video_path.name}",
            file=sys.stderr,
        )
    return logged_rows


def recording_sensor_window(capture_dir: Path) -> tuple[float, float] | None:
    starts: list[float] = []
    ends: list[float] = []
    for file_name in [
        "wide_info.csv",
        "ultra_info.csv",
        "tele_info.csv",
        "front_info.csv",
        "lidar_depth_info.csv",
        "audio_info.csv",
        "imu.csv",
        "device_motion.csv",
        "accelerometer.csv",
        "gyroscope.csv",
    ]:
        rows = read_csv_rows(capture_dir / file_name)
        values = [value for value in (parse_float(row.get("sensor_sec")) for row in rows) if value is not None]
        if values:
            starts.append(min(values))
            ends.append(max(values))
    if not starts or not ends:
        return None
    return min(starts), max(ends)


def log_lidar_depth_metadata(rr: Any, capture_dir: Path) -> None:
    info_path = capture_dir / "lidar_depth_info.csv"
    depth_dir = capture_dir / "lidar_depth"
    rows = read_csv_rows(info_path)
    if not rows:
        return

    png_count = len(list(depth_dir.glob("depth_*.png"))) if depth_dir.exists() else 0
    first = rows[0]
    last = rows[-1]
    rr.log(
        "metadata/lidar_depth",
        rr.TextDocument(
            "\n".join(
                [
                    f"directory: {depth_dir}",
                    f"index_file: {info_path}",
                    "raw_depth: 16-bit PNG depth in millimeters, one PNG per frame",
                    f"csv_rows: {len(rows)}",
                    f"png_files: {png_count}",
                    f"first_sensor_sec: {first.get('sensor_sec', '')}",
                    f"last_sensor_sec: {last.get('sensor_sec', '')}",
                    f"resolution: {first.get('width_px', '')}x{first.get('height_px', '')}",
                    "note: Rerun conversion logs depth images and reconstructed per-frame point clouds.",
                ]
            )
        ),
        static=True,
    )


def log_lidar_depth(rr: Any, np: Any, capture_dir: Path, pixel_stride: int) -> None:
    rows = read_csv_rows(capture_dir / "lidar_depth_info.csv")
    depth_dir = capture_dir / "lidar_depth"
    if not rows or not depth_dir.exists():
        return

    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit("Missing dependency for LiDAR depth. Install with: python3 -m pip install pillow") from exc

    pixel_stride = max(int(pixel_stride), 1)
    for row in rows:
        sensor_sec = parse_float(row.get("sensor_sec"))
        utc_sec = parse_float(row.get("utc_sec"))
        if sensor_sec is None:
            continue

        file_name = row.get("file_name") or f"depth_{int(float(row.get('frame_index', '0'))):06d}.png"
        png_path = depth_dir / file_name
        if not png_path.exists():
            continue

        depth_raw = np.asarray(Image.open(png_path), dtype=np.uint16)
        if depth_raw.ndim != 2:
            continue

        depth_scale = parse_float(row.get("depth_scale")) or 1000.0
        depth_m = depth_raw.astype(np.float32) / float(depth_scale)
        valid = depth_raw > 0

        rr.set_time("sensor_time", duration=sensor_sec)
        if utc_sec is not None and math.isfinite(utc_sec):
            rr.set_time("utc_time", timestamp=utc_sec)

        if hasattr(rr, "DepthImage"):
            rr.log("/lidar/depth/image", rr.DepthImage(depth_raw, meter=float(depth_scale)))
        else:
            rr.log("/lidar/depth/image", rr.Image(depth_colormap(np=np, depth_m=depth_m, valid=valid)))

        points = depth_points_from_intrinsics(np=np, depth_m=depth_m, valid=valid, row=row, pixel_stride=pixel_stride)
        if len(points):
            rr.log("/lidar/depth/points", rr.Points3D(points))


def depth_points_from_intrinsics(np: Any, depth_m: Any, valid: Any, row: dict[str, str], pixel_stride: int) -> Any:
    fx = parse_float(row.get("fx_px"))
    fy = parse_float(row.get("fy_px"))
    cx = parse_float(row.get("cx_px"))
    cy = parse_float(row.get("cy_px"))
    if not all(value is not None and math.isfinite(value) and value > 0 for value in [fx, fy]):
        return np.empty((0, 3), dtype=np.float32)

    sampled_depth = depth_m[::pixel_stride, ::pixel_stride]
    sampled_valid = valid[::pixel_stride, ::pixel_stride]
    vv, uu = np.indices(sampled_depth.shape, dtype=np.float32)
    uu *= pixel_stride
    vv *= pixel_stride

    z = sampled_depth[sampled_valid]
    x = (uu[sampled_valid] - float(cx)) * z / float(fx)
    y = (vv[sampled_valid] - float(cy)) * z / float(fy)
    return np.stack([x, y, z], axis=1).astype(np.float32)


def depth_colormap(np: Any, depth_m: Any, valid: Any) -> Any:
    if not valid.any():
        return np.zeros((*depth_m.shape, 3), dtype=np.uint8)
    valid_depth = depth_m[valid]
    lo = float(np.nanpercentile(valid_depth, 2))
    hi = float(np.nanpercentile(valid_depth, 98))
    scale = max(hi - lo, 1e-6)
    t = np.clip((depth_m - lo) / scale, 0, 1)
    near = 1.0 - t
    rgb = np.zeros((*depth_m.shape, 3), dtype=np.uint8)
    rgb[..., 0] = (255 * near).astype(np.uint8)
    rgb[..., 1] = (255 * (1.0 - np.abs(near - 0.5) * 2.0)).astype(np.uint8)
    rgb[..., 2] = (255 * (1.0 - near)).astype(np.uint8)
    rgb[~valid] = 0
    return rgb


def filter_rows_to_sensor_window(rows: list[dict[str, str]], window: tuple[float, float]) -> list[dict[str, str]]:
    start_sec, end_sec = window
    filtered = []
    for row in rows:
        sensor_sec = parse_float(row.get("sensor_sec"))
        if sensor_sec is not None and start_sec <= sensor_sec <= end_sec:
            filtered.append(row)
    dropped = len(rows) - len(filtered)
    if dropped:
        print(f"warning: dropped {dropped} geo samples outside recording sensor window", file=sys.stderr)
    return filtered


def log_geo_relative_columns(rr: Any, np: Any, rows: list[dict[str, str]], base_path: str) -> None:
    if not rows:
        return

    origin = next(
        (
            row
            for row in rows
            if parse_float(row.get("latitude")) is not None
            and parse_float(row.get("longitude")) is not None
            and parse_float(row.get("altitude")) is not None
        ),
        None,
    )
    if origin is None:
        return

    earth_radius_m = 6_378_137.0
    lat0 = math.radians(float(origin["latitude"]))
    lon0 = math.radians(float(origin["longitude"]))
    alt0 = float(origin["altitude"])
    relative_rows: list[dict[str, str]] = []

    for row in rows:
        sensor_sec = parse_float(row.get("sensor_sec"))
        utc_sec = parse_float(row.get("utc_sec"))
        latitude = parse_float(row.get("latitude"))
        longitude = parse_float(row.get("longitude"))
        altitude = parse_float(row.get("altitude"))
        horizontal_accuracy = parse_float(row.get("horizontal_accuracy_m"))
        if sensor_sec is None or latitude is None or longitude is None or altitude is None:
            continue

        lat = math.radians(latitude)
        lon = math.radians(longitude)
        east_m = (lon - lon0) * math.cos(lat0) * earth_radius_m
        north_m = (lat - lat0) * earth_radius_m
        up_m = altitude - alt0
        relative_rows.append(
            {
                "sensor_sec": f"{sensor_sec:.9f}",
                "utc_sec": f"{utc_sec:.9f}" if utc_sec is not None else "",
                "east_m": f"{east_m:.9f}",
                "north_m": f"{north_m:.9f}",
                "up_m": f"{up_m:.9f}",
                "horizontal_accuracy_m": f"{horizontal_accuracy:.9f}" if horizontal_accuracy is not None else "",
            }
        )

    log_scalar_columns(
        rr=rr,
        np=np,
        rows=relative_rows,
        base_path=base_path,
        fields=["east_m", "north_m", "up_m", "horizontal_accuracy_m"],
        drop_nonfinite=True,
    )


def log_scalar_columns(rr: Any, np: Any, rows: list[dict[str, str]], base_path: str, fields: list[str], drop_nonfinite: bool) -> None:
    values = numeric_rows(rows, fields)
    for field, triples in values.items():
        if not triples:
            continue

        if drop_nonfinite:
            triples = [triple for triple in triples if math.isfinite(triple[2])]
        if not triples:
            continue

        sensor_ns = np.array([seconds_to_ns(item[0]) for item in triples], dtype="timedelta64[ns]")
        scalars = np.array([item[2] for item in triples], dtype=np.float64)

        indexes: list[Any] = [rr.TimeColumn("sensor_time", duration=sensor_ns)]
        if all(math.isfinite(item[1]) for item in triples):
            utc_ns = np.array([seconds_to_ns(item[1]) for item in triples], dtype="datetime64[ns]")
            indexes.append(rr.TimeColumn("utc_time", timestamp=utc_ns))

        rr.send_columns(f"{base_path}/{field}", indexes=indexes, columns=rr.Scalars.columns(scalars=scalars))


def log_audio_waveform(rr: Any, np: Any, capture_dir: Path) -> None:
    audio_path = capture_dir / "audio.m4a"
    audio_rows = read_csv_rows(capture_dir / "audio_info.csv")
    if not audio_path.exists() or not audio_rows:
        return

    first_sensor_sec = parse_float(audio_rows[0].get("sensor_sec"))
    first_utc_sec = parse_float(audio_rows[0].get("utc_sec"))
    if first_sensor_sec is None:
        return

    sample_rate = int(parse_float(audio_rows[0].get("sample_rate_hz")) or 44_100)
    channel_count = int(parse_float(audio_rows[0].get("channels")) or 1)
    channel_count = max(channel_count, 1)
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(audio_path),
        "-ac",
        str(channel_count),
        "-ar",
        str(sample_rate),
        "-f",
        "f32le",
        "-",
    ]
    payload = subprocess.check_output(command)
    if not payload:
        return

    samples = np.frombuffer(payload, dtype=np.float32)
    frame_count = len(samples) // channel_count
    if frame_count == 0:
        return

    samples = samples[: frame_count * channel_count].reshape(frame_count, channel_count)
    sensor_times, utc_times = audio_sample_times(np=np, audio_rows=audio_rows, frame_count=frame_count, sample_rate=sample_rate)
    sensor_ns = np.array([seconds_to_ns(value) for value in sensor_times], dtype="timedelta64[ns]")

    indexes: list[Any] = [rr.TimeColumn("sensor_time", duration=sensor_ns)]
    if first_utc_sec is not None and math.isfinite(first_utc_sec) and len(utc_times) == len(sensor_times):
        utc_ns = np.array([seconds_to_ns(value) for value in utc_times], dtype="datetime64[ns]")
        indexes.append(rr.TimeColumn("utc_time", timestamp=utc_ns))

    for channel_index in range(channel_count):
        entity = "/audio_m4a/waveform" if channel_count == 1 else f"/audio_m4a/channel_{channel_index}"
        rr.send_columns(
            entity,
            indexes=indexes,
            columns=rr.Scalars.columns(scalars=samples[:, channel_index]),
        )


def audio_sample_times(np: Any, audio_rows: list[dict[str, str]], frame_count: int, sample_rate: int) -> tuple[Any, Any]:
    sensor_segments = []
    utc_segments = []
    remaining = frame_count

    for row in audio_rows:
        if remaining <= 0:
            break

        sensor_sec = parse_float(row.get("sensor_sec"))
        utc_sec = parse_float(row.get("utc_sec"))
        sample_count = int(parse_float(row.get("sample_count")) or 0)
        duration_sec = parse_float(row.get("duration_sec"))
        if sensor_sec is None or sample_count <= 0:
            continue

        count = min(sample_count, remaining)
        step = duration_sec / sample_count if duration_sec and duration_sec > 0 else 1.0 / sample_rate
        offsets = np.arange(count, dtype=np.float64) * step
        sensor_segments.append(sensor_sec + offsets)
        if utc_sec is not None and math.isfinite(utc_sec):
            utc_segments.append(utc_sec + offsets)
        remaining -= count

    if remaining > 0:
        last_sensor = sensor_segments[-1][-1] if sensor_segments else parse_float(audio_rows[0].get("sensor_sec")) or 0.0
        tail_offsets = np.arange(1, remaining + 1, dtype=np.float64) / sample_rate
        sensor_segments.append(last_sensor + tail_offsets)
        if utc_segments:
            last_utc = utc_segments[-1][-1]
            utc_segments.append(last_utc + tail_offsets)

    sensor_times = np.concatenate(sensor_segments) if sensor_segments else np.array([], dtype=np.float64)
    utc_times = np.concatenate(utc_segments) if utc_segments else np.array([], dtype=np.float64)
    return sensor_times[:frame_count], utc_times[:frame_count]


def main() -> int:
    args = parse_args()
    capture_dir = args.capture_dir.expanduser().resolve()
    if not capture_dir.is_dir():
        print(f"error: capture directory not found: {capture_dir}", file=sys.stderr)
        return 2

    output_path = (args.output or default_output_path(capture_dir)).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    convert_to_rerun(
        capture_dir,
        output_path,
        args.app_id,
        args.drop_nonfinite,
        args.jpeg_quality,
        args.video_fps,
        args.depth_pixel_stride,
    )

    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
