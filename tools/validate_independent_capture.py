#!/usr/bin/env python3
"""Validate Standard independent-camera output against its saved configuration."""
import argparse
import csv
import json
import statistics
import subprocess
from pathlib import Path


def validate(session, ffprobe):
    meta = json.loads((session / "meta.json").read_text())
    assert meta["state"] == "finished", "recording did not finish"
    assert "no shared time-grid" in meta["recording_start"]["sampling_rule"], "unexpected sampling policy"
    settings = meta["recording_settings"]
    results = []
    for key, filename, index_name in [("wide", "wide.mp4", "wide_info.csv"),
                                      ("ultrawide", "ultrawide.mp4", "ultra_info.csv"),
                                      ("front", "front.mp4", "front_info.csv")]:
        camera = settings[key]
        if not camera["enabled"]:
            continue
        lines = (session / index_name).read_text().splitlines()
        errors = [line for line in lines if line.startswith("#") and any(
            token in line for token in ["failed", "overflow", "timeout"])]
        assert not errors, f"{key}: {errors}"
        rows = list(csv.DictReader(line for line in lines if not line.startswith("#")))
        assert len(rows) >= 2, f"{key}: missing samples"
        for column in ["frame_index", "record_slot"]:
            assert [int(row[column]) for row in rows] == list(range(len(rows))), f"{key}: discontinuous {column}"
        width, height = map(int, camera["resolution"].split("x"))
        assert all((int(row["width_px"]), int(row["height_px"])) == (width, height) for row in rows), f"{key}: CSV resolution mismatch"
        times = [float(row["sensor_sec"]) for row in rows]
        intervals = [later - earlier for earlier, later in zip(times, times[1:])]
        assert min(intervals) > 0, f"{key}: non-monotonic capture times"
        requested = float(camera["target_frame_rate"])
        measured = (len(times) - 1) / (times[-1] - times[0])
        assert abs(measured / requested - 1) < 0.1, f"{key}: {measured}fps differs from {requested}fps"
        assert max(intervals) < 1.8 / requested, f"{key}: capture timestamp gap {max(intervals)}s"
        probe = json.loads(subprocess.check_output([
            str(ffprobe), "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_streams",
            "-show_frames", "-show_entries", "stream=width,height,nb_read_frames:frame=best_effort_timestamp_time",
            "-of", "json", str(session / filename)], text=True))
        stream = probe["streams"][0]
        assert (stream["width"], stream["height"]) == (width, height), f"{key}: MP4 resolution mismatch"
        assert int(stream["nb_read_frames"]) == len(rows), f"{key}: encoded/index frame count mismatch"
        pts = [float(frame["best_effort_timestamp_time"]) for frame in probe["frames"]]
        assert len(pts) == len(times), f"{key}: timestamp count mismatch"
        error = max(abs((p - pts[0]) - (t - times[0])) for p, t in zip(pts, times))
        assert error < 0.0002, f"{key}: timestamps were resampled ({error}s)"
        results.append(dict(camera=key, resolution=camera["resolution"], configured_fps=requested,
                            measured_fps=round(measured, 4), frames=len(rows),
                            median_interval_ms=round(statistics.median(intervals) * 1000, 4),
                            max_interval_ms=round(max(intervals) * 1000, 4),
                            timestamp_error_sec=error))
    assert results, "no camera output was enabled"
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("session", type=Path)
    parser.add_argument("--ffprobe", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps({"result": "PASS", "streams": validate(args.session, args.ffprobe)}, indent=2))
