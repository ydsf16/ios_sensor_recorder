#!/usr/bin/env python3
"""Check sensor-clock alignment between wide and ultra-wide frame logs."""

from __future__ import annotations

import argparse
import bisect
import math
from pathlib import Path
from statistics import mean, median, pstdev


def read_sensor_times(path: Path) -> list[float]:
    times: list[float] = []
    with path.open("r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split(",") if "," in line else line.split()
            if len(fields) < 3:
                continue
            try:
                sensor_sec = float(fields[1])
            except ValueError:
                continue
            if math.isfinite(sensor_sec):
                times.append(sensor_sec)
    return times


def nearest_deltas(reference: list[float], candidates: list[float]) -> list[float]:
    deltas: list[float] = []
    for value in reference:
        index = bisect.bisect_left(candidates, value)
        nearest: float | None = None
        if index > 0:
            nearest = candidates[index - 1]
        if index < len(candidates):
            right = candidates[index]
            if nearest is None or abs(right - value) < abs(nearest - value):
                nearest = right
        if nearest is not None:
            deltas.append(nearest - value)
    return deltas


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


def print_stats(deltas_sec: list[float]) -> None:
    deltas_ms = sorted(delta * 1000.0 for delta in deltas_sec)
    abs_ms = sorted(abs(delta) for delta in deltas_ms)
    print(f"matched_pairs: {len(deltas_ms)}")
    if not deltas_ms:
        return
    print(f"delta_ms_mean: {mean(deltas_ms):.6f}")
    print(f"delta_ms_median: {median(deltas_ms):.6f}")
    print(f"delta_ms_std: {pstdev(deltas_ms):.6f}")
    print(f"delta_ms_min: {deltas_ms[0]:.6f}")
    print(f"delta_ms_max: {deltas_ms[-1]:.6f}")
    print(f"abs_delta_ms_p50: {percentile(abs_ms, 50):.6f}")
    print(f"abs_delta_ms_p90: {percentile(abs_ms, 90):.6f}")
    print(f"abs_delta_ms_p95: {percentile(abs_ms, 95):.6f}")
    print(f"abs_delta_ms_p99: {percentile(abs_ms, 99):.6f}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    args = parser.parse_args()

    wide_path = args.capture_dir / "wide_info.csv"
    ultra_path = args.capture_dir / "ultra_info.csv"
    if not wide_path.exists():
        wide_path = args.capture_dir / "wide_info.txt"
    if not ultra_path.exists():
        ultra_path = args.capture_dir / "ultra_info.txt"
    wide_times = read_sensor_times(wide_path)
    ultra_times = read_sensor_times(ultra_path)
    ultra_times.sort()

    print(f"wide_frames: {len(wide_times)}")
    print(f"ultra_frames: {len(ultra_times)}")
    print("delta definition: nearest_ultra_sensor_sec - wide_sensor_sec")
    deltas = nearest_deltas(wide_times, ultra_times)
    print_stats(deltas)


if __name__ == "__main__":
    main()
