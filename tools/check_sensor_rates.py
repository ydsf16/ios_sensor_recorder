#!/usr/bin/env python3
"""Report actual sensor sample rates from capture CSV files."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
from statistics import mean, median, pstdev


DEFAULT_FILES = [
    "wide_info.csv",
    "ultra_info.csv",
    "audio_info.csv",
    "accelerometer.csv",
    "gyroscope.csv",
    "imu.csv",
    "device_motion.csv",
    "magnetometer.csv",
    "barometer.csv",
    "geo_location.csv",
]


def read_sensor_times(path: Path) -> list[float]:
    times: list[float] = []
    sensor_sec_index: int | None = None
    with path.open("r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split(",")
            if not fields:
                continue
            if sensor_sec_index is None:
                if "sensor_sec" not in fields:
                    continue
                sensor_sec_index = fields.index("sensor_sec")
                continue
            if sensor_sec_index >= len(fields):
                continue
            try:
                sensor_sec = float(fields[sensor_sec_index])
            except ValueError:
                continue
            if math.isfinite(sensor_sec):
                times.append(sensor_sec)
    return times


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return float("nan")
    index = (len(values) - 1) * pct / 100.0
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return values[int(index)]
    ratio = index - lower
    return values[lower] * (1.0 - ratio) + values[upper] * ratio


def print_stats(path: Path, times: list[float]) -> None:
    print(f"\n{path.name}")
    print(f"samples: {len(times)}")
    if len(times) < 2:
        return

    times = sorted(times)
    deltas = [b - a for a, b in zip(times, times[1:]) if b > a]
    if not deltas:
        return

    deltas_ms = sorted(delta * 1000.0 for delta in deltas)
    duration = times[-1] - times[0]
    rate = (len(times) - 1) / duration if duration > 0 else float("nan")

    print(f"duration_sec: {duration:.6f}")
    print(f"rate_hz: {rate:.3f}")
    print(f"dt_ms_mean: {mean(deltas_ms):.6f}")
    print(f"dt_ms_median: {median(deltas_ms):.6f}")
    print(f"dt_ms_std: {pstdev(deltas_ms):.6f}")
    print(f"dt_ms_min: {deltas_ms[0]:.6f}")
    print(f"dt_ms_max: {deltas_ms[-1]:.6f}")
    print(f"dt_ms_p90: {percentile(deltas_ms, 90):.6f}")
    print(f"dt_ms_p99: {percentile(deltas_ms, 99):.6f}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    parser.add_argument("--files", nargs="*", default=DEFAULT_FILES)
    args = parser.parse_args()

    for name in args.files:
        path = args.capture_dir / name
        if not path.exists():
            print(f"\n{name}")
            print("missing")
            continue
        print_stats(path, read_sensor_times(path))


if __name__ == "__main__":
    main()
