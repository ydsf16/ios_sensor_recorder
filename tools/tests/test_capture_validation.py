import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('capture_validation', Path(__file__).parents[1] / 'validate_capture.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class CaptureValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.session = Path(self.temp.name)
        self.probes = {}
        self.meta = dict(state='finished', recording_settings=dict(imu_enabled=False), recording_start=dict(
            hardware_sync={}, synchronized_group_count=8, synchronized_dropped_groups=0),
            camera_extrinsics=dict(T_wide_from_ultrawide=[[1, 0, 0, .014], [0, 1, 0, 0], [0, 0, 1, 0]]))
        for key, _, index in validator.CAMERAS:
            enabled = key in ['wide', 'ultrawide']
            self.meta['recording_settings'][key] = dict(enabled=enabled, resolution='640x480', target_frame_rate=30)
            if not enabled:
                continue
            offset = 0 if key == 'wide' else .00008
            self.write_csv(f'{index}_info.csv', ['frame_index', 'record_slot', 'sensor_sec', 'width_px', 'height_px'],
                           [[i, i, 100 + i / 30 + offset, 640, 480] for i in range(8)])
            self.probes[key + '.mp4'] = dict(streams=[dict(width=640, height=480, nb_read_frames='8')],
                                            frames=[dict(best_effort_timestamp_time=i / 30 + offset) for i in range(8)])
        self.write_csv('synchronization.csv', ['group_index', 'wide_sensor_sec', 'ultra_sensor_sec', 'max_skew_sec'],
                       [[i, 100 + i / 30, 100 + i / 30 + .00008, .00008] for i in range(8)])

    def tearDown(self):
        self.temp.cleanup()

    def write_csv(self, filename, header, data):
        with (self.session / filename).open('w') as handle:
            writer = csv.writer(handle); writer.writerow(header); writer.writerows(data)

    def run_validator(self):
        (self.session / 'meta.json').write_text(json.dumps(self.meta))
        with patch.object(validator.subprocess, 'check_output', side_effect=lambda command, **_: json.dumps(self.probes[Path(command[-1]).name])):
            return validator.validate(self.session, Path('ffprobe'))

    def test_hardware_streams_preserve_epoch(self):
        self.assertEqual(8, self.run_validator()['groups'])

    def test_four_camera_schema_with_three_rear_hardware_streams(self):
        for key, index, offset in [('telephoto', 'tele', .00012), ('front', 'front', .01)]:
            self.meta['recording_settings'][key]['enabled'] = True
            self.write_csv(f'{index}_info.csv', ['frame_index', 'record_slot', 'sensor_sec', 'width_px', 'height_px'],
                           [[i, i, 100 + i / 30 + offset, 640, 480] for i in range(8)])
            self.probes[key + '.mp4'] = dict(streams=[dict(width=640, height=480, nb_read_frames='8')],
                frames=[dict(best_effort_timestamp_time=i / 30 + offset) for i in range(8)])
        start = self.meta['recording_start']
        start.update(hardware_synchronized_cameras=['wide', 'ultraWide', 'telephoto'],
            all_cameras_hardware_synchronized=False,
            timestamp_alignment=dict(reference_camera='wide', rows=8, maximum_skew_sec=.01))
        self.write_csv('synchronization.csv', ['group_index', 'wide_sensor_sec', 'ultra_sensor_sec', 'telephoto_sensor_sec', 'front_sensor_sec', 'max_skew_sec'],
            [[i, 100+i/30, 100+i/30+.00008, 100+i/30+.00012, '', .00012] for i in range(8)])
        columns = ['reference_frame_index', 'reference_sensor_sec']
        for index in ['wide', 'ultra', 'tele', 'front']:
            columns += [index+'_frame_index', index+'_sensor_sec']
        self.write_csv('timestamp_alignment.csv', columns+['max_skew_sec'],
            [[i, 100+i/30, i, 100+i/30, i, 100+i/30+.00008, i, 100+i/30+.00012, i, 100+i/30+.01, .01] for i in range(8)])
        result = self.run_validator()
        self.assertEqual(4, len(result['streams']))
        self.assertEqual(8, result['groups'])

    def test_software_grouping_does_not_qualify(self):
        del self.meta['recording_start']['hardware_sync']
        with self.assertRaisesRegex(ValueError, 'virtual hardware'):
            self.run_validator()

    def make_front_pair(self, front_frames=7):
        self.meta['recording_settings']['ultrawide']['enabled'] = False
        self.meta['recording_settings']['front'] = dict(enabled=True, resolution='640x480', target_frame_rate=30)
        self.meta['recording_start'] = dict(hardware_synchronized_cameras=[], all_cameras_hardware_synchronized=False,
            timestamp_alignment=dict(reference_camera='wide', rows=8, maximum_skew_sec=(8 - front_frames) / 30 - .00008))
        source = validator.rows(self.session / 'ultra_info.csv')[:front_frames]
        self.write_csv('front_info.csv', list(source[0]), [[row[k] for k in source[0]] for row in source])
        self.probes['front.mp4'] = dict(streams=[dict(width=640, height=480, nb_read_frames=str(front_frames))],
            frames=self.probes['ultrawide.mp4']['frames'][:front_frames])
        data = []
        for i in range(8):
            j = min(i, front_frames - 1); reference = 100 + i / 30; front = 100 + j / 30 + .00008
            data.append([i, reference, i, reference, j, front, abs(front - reference)])
        self.write_csv('timestamp_alignment.csv', ['reference_frame_index', 'reference_sensor_sec', 'wide_frame_index',
            'wide_sensor_sec', 'front_frame_index', 'front_sensor_sec', 'max_skew_sec'], data)

    def test_front_pair_preserves_unequal_frame_counts(self):
        self.make_front_pair()
        result = self.run_validator()
        self.assertFalse(result['hardware_sync'])
        self.assertEqual([8, 7], [stream['frames'] for stream in result['streams']])

    def test_independent_stop_edge_does_not_imply_internal_frame_loss(self):
        self.make_front_pair(front_frames=6)
        result = self.run_validator()['timestamp_alignment']
        self.assertGreater(result['maximum_skew_sec'], 1 / 30)
        self.assertLess(result['maximum_overlap_skew_sec'], .001)

    def test_excessive_independent_stop_difference_is_detected(self):
        self.make_front_pair(front_frames=5)
        with self.assertRaisesRegex(ValueError, 'capture boundaries'):
            self.run_validator()

    def test_front_cannot_be_labeled_hardware_synchronized(self):
        self.make_front_pair()
        self.meta['recording_start']['hardware_synchronized_cameras'] = ['wide', 'front']
        with self.assertRaisesRegex(ValueError, 'incorrectly labeled'):
            self.run_validator()

    def test_wrong_timestamp_correspondence_is_detected(self):
        self.make_front_pair()
        path = self.session / 'timestamp_alignment.csv'
        data = validator.rows(path)
        data[2]['front_frame_index'] = '0'
        self.write_csv(path.name, list(data[0]), [[row[k] for k in data[0]] for row in data])
        with self.assertRaisesRegex(ValueError, 'source timestamp'):
            self.run_validator()

    def test_encoder_drops_are_detected(self):
        self.probes['wide.mp4']['streams'][0]['nb_read_frames'] = '7'
        with self.assertRaisesRegex(ValueError, 'frame count'):
            self.run_validator()

    def test_wrong_resolution_is_detected(self):
        self.probes['wide.mp4']['streams'][0]['width'] = 1280
        with self.assertRaisesRegex(ValueError, 'encoded resolution'):
            self.run_validator()

    def test_wrong_container_frame_rate_is_detected(self):
        self.probes['wide.mp4']['streams'][0]['avg_frame_rate'] = '15/1'
        with self.assertRaisesRegex(ValueError, 'container frame rate'):
            self.run_validator()

    def test_rewritten_timestamps_are_detected(self):
        self.probes['wide.mp4']['frames'][3]['best_effort_timestamp_time'] += .01
        with self.assertRaisesRegex(ValueError, 'resampled'):
            self.run_validator()

    def test_exposure_midpoint_corruption_is_detected(self):
        path = self.session / 'wide_info.csv'
        data = validator.rows(path)
        for row in data:
            row['utc_sec'] = row['sensor_sec']
            row['exposure_sec'] = '0.010'
            row['exposure_source'] = 'frame_exif'
            row['exposure_mid_sensor_sec'] = float(row['sensor_sec']) + .005
            row['exposure_mid_utc_sec'] = float(row['utc_sec']) + .005
        data[3]['exposure_mid_sensor_sec'] += .01
        self.write_csv(path.name, list(data[0]), [[row[k] for k in data[0]] for row in data])
        with self.assertRaisesRegex(ValueError, 'exposure midpoint'):
            self.run_validator()

    def add_capture_clock_indices(self):
        # Audio's synchronization clock can acquire a new host correlation while
        # the original media timestamps remain unchanged.
        for camera, index in [('wide', 'wide'), ('ultrawide', 'ultra')]:
            data = validator.rows(self.session / f'{index}_info.csv')
            for i, row in enumerate(data):
                row['capture_pts_sec'] = 100 + float(self.probes[camera + '.mp4']['frames'][i]['best_effort_timestamp_time'])
                row['sensor_sec'] = float(row['sensor_sec']) + (i % 3) * .00002
            self.write_csv(f'{index}_info.csv', list(data[0]), [[r[k] for k in data[0]] for r in data])
        data = validator.rows(self.session / 'synchronization.csv')
        for i, row in enumerate(data):
            for key in ['wide_sensor_sec', 'ultra_sensor_sec']:
                row[key] = float(row[key]) + (i % 3) * .00002
        self.write_csv('synchronization.csv', list(data[0]), [[r[k] for k in data[0]] for r in data])

    def test_native_pts_survives_host_clock_correlation_updates(self):
        self.add_capture_clock_indices()
        self.assertEqual(8, self.run_validator()['groups'])

    def test_native_pts_still_detects_media_retiming(self):
        self.add_capture_clock_indices()
        self.probes['wide.mp4']['frames'][3]['best_effort_timestamp_time'] += .01
        with self.assertRaisesRegex(ValueError, 'resampled'):
            self.run_validator()

    def test_shared_epoch_shift_is_detected(self):
        for frame in self.probes['ultrawide.mp4']['frames']:
            frame['best_effort_timestamp_time'] += .02
        with self.assertRaisesRegex(ValueError, 'shared capture epoch'):
            self.run_validator()

    def test_submillisecond_movie_edit_rounding_is_detected(self):
        for frame in self.probes['ultrawide.mp4']['frames']:
            frame['best_effort_timestamp_time'] -= .00008
        with self.assertRaisesRegex(ValueError, 'shared capture epoch'):
            self.run_validator()

    def test_lost_group_is_detected(self):
        self.meta['recording_start']['synchronized_dropped_groups'] = 1
        with self.assertRaisesRegex(ValueError, 'Dropped synchronization'):
            self.run_validator()

    def test_millimeters_mislabeled_as_meters_are_detected(self):
        self.meta['camera_extrinsics']['T_wide_from_ultrawide'][0][3] = 14
        with self.assertRaisesRegex(ValueError, 'baseline unit'):
            self.run_validator()


if __name__ == '__main__':
    unittest.main()
