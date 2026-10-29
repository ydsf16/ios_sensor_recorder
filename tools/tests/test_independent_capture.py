import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("independent_capture", Path(__file__).parents[1] / "validate_independent_capture.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class IndependentCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.session = Path(self.temp.name)
        self.cameras = {"wide": 15, "ultrawide": 30, "front": 24}
        self.probes = {}
        settings = {}
        for camera, fps in self.cameras.items():
            settings[camera] = dict(enabled=True, resolution="640x480", target_frame_rate=fps)
            name = "ultra" if camera == "ultrawide" else camera
            with (self.session / f"{name}_info.csv").open("w") as handle:
                writer = csv.writer(handle)
                writer.writerow(["frame_index", "record_slot", "sensor_sec", "width_px", "height_px"])
                writer.writerows([[i, i, 100 + i / fps, 640, 480] for i in range(8)])
            self.probes[f"{camera}.mp4"] = dict(
                streams=[dict(width=640, height=480, nb_read_frames="8")],
                frames=[dict(best_effort_timestamp_time=i / fps) for i in range(8)])
        (self.session / "meta.json").write_text(json.dumps(dict(
            state="finished", recording_start=dict(sampling_rule="no shared time-grid filtering"), recording_settings=settings)))

    def tearDown(self):
        self.temp.cleanup()

    def run_validator(self):
        with patch.object(validator.subprocess, "check_output", side_effect=lambda command, **_: json.dumps(self.probes[Path(command[-1]).name])):
            return validator.validate(self.session, Path("ffprobe"))

    def test_distinct_camera_rates_pass(self):
        self.assertEqual([15, 30, 24], [row["measured_fps"] for row in self.run_validator()])

    def test_resampled_video_timestamps_fail(self):
        self.probes["wide.mp4"]["frames"][3]["best_effort_timestamp_time"] += 0.01
        with self.assertRaisesRegex(AssertionError, "resampled"):
            self.run_validator()

    def test_encoder_frame_loss_fails(self):
        self.probes["wide.mp4"]["streams"][0]["nb_read_frames"] = "7"
        with self.assertRaisesRegex(AssertionError, "frame count"):
            self.run_validator()

    def test_wrong_resolution_fails(self):
        self.probes["wide.mp4"]["streams"][0]["width"] = 1280
        with self.assertRaisesRegex(AssertionError, "resolution mismatch"):
            self.run_validator()


if __name__ == "__main__":
    unittest.main()
