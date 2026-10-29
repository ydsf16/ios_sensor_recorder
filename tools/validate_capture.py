#!/usr/bin/env python3
"""Validate real Standard recordings, including decoded frames and hardware groups."""
import argparse
import bisect
import csv
import json
import math
import statistics
import subprocess
from fractions import Fraction
from pathlib import Path

CAMERAS = [('wide', 'wide', 'wide'), ('ultrawide', 'ultrawide', 'ultra'),
           ('telephoto', 'telephoto', 'tele'), ('front', 'front', 'front')]


def rows(path):
    return list(csv.DictReader(line for line in path.read_text().splitlines() if not line.startswith('#')))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(session, ffprobe):
    meta = json.loads((session / 'meta.json').read_text())
    require(meta['state'] == 'finished', f"Recording failed: {meta.get('failure', meta['state'])}")
    settings = meta['recording_settings']
    enabled = [(key, file, index) for key, file, index in CAMERAS if settings[key]['enabled']]
    require(enabled, 'No camera enabled')
    multiple = len(enabled) > 1
    start = meta['recording_start']
    enabled_keys = {camera[0] for camera in enabled}
    aliases = {'ultraWide': 'ultrawide', 'wide': 'wide', 'front': 'front', 'telephoto': 'telephoto'}
    hardware_keys = {aliases.get(key, key) for key in start.get('hardware_synchronized_cameras',
                    list(enabled_keys) if 'hardware_sync' in start else [])}
    require('front' not in hardware_keys, 'Front was incorrectly labeled hardware synchronized')
    rear_keys = enabled_keys - {'front'}
    if len(rear_keys) > 1:
        require('hardware_sync' in start and hardware_keys == rear_keys, 'Rear cameras did not use a virtual hardware camera')
    synchronized = len(hardware_keys) > 1
    if synchronized:
        require(start['synchronized_dropped_groups'] == 0, 'Dropped synchronization groups')
    mixed = multiple and 'front' in enabled_keys
    if mixed:
        require(start.get('all_cameras_hardware_synchronized') is False, 'Mixed synchronization scope is not explicit')
        require('timestamp_alignment' in start, 'Missing timestamp correspondence metadata')
    streams, indices, movie_pts, sensor_times = [], {}, {}, {}
    for key, file, index in enabled:
        index_path = session / f'{index}_info.csv'
        errors = [line for line in index_path.read_text().splitlines() if line.startswith('#') and
                  any(token in line.lower() for token in ['failed', 'overflow', 'timeout'])]
        require(not errors, f'{key}: writer errors {errors}')
        data = rows(index_path)
        require(len(data) >= 3, f'{key}: insufficient frames')
        indices[key] = data
        for field in ['frame_index', 'record_slot']:
            require([int(row[field]) for row in data] == list(range(len(data))), f'{key}: discontinuous {field}')
        width, height = map(int, settings[key]['resolution'].split('x'))
        require(all((int(r['width_px']), int(r['height_px'])) == (width, height) for r in data), f'{key}: index dimensions')
        times = [float(r['sensor_sec']) for r in data]
        sensor_times[key] = times
        gaps = [b - a for a, b in zip(times, times[1:])]
        fps = float(settings[key]['target_frame_rate'])
        measured = (len(times) - 1) / (times[-1] - times[0])
        require(min(gaps) > 0, f'{key}: non-monotonic sensor time')
        # Native clocks have small rate error; require the measured cadence within 0.5%.
        require(abs(measured / fps - 1) < .005, f'{key}: configured {fps}, actual {measured} fps')
        require(max(gaps) < 1.5 / fps, f'{key}: missing frame, maximum gap {max(gaps)}')
        probe = json.loads(subprocess.check_output([
            str(ffprobe), '-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_streams',
            '-show_frames', '-show_entries', 'stream=codec_name,width,height,nb_read_frames,avg_frame_rate:frame=best_effort_timestamp_time',
            '-of', 'json', str(session / f'{file}.mp4')], text=True, stderr=subprocess.PIPE))
        require(len(probe['streams']) == 1, f'{key}: no readable video stream')
        stream = probe['streams'][0]
        require((stream['width'], stream['height']) == (width, height), f'{key}: encoded resolution mismatch')
        require(int(stream['nb_read_frames']) == len(data), f'{key}: decoded/index frame count mismatch')
        container_fps = None
        if 'avg_frame_rate' in stream:
            try:
                container_fps = float(Fraction(stream['avg_frame_rate']))
            except (ValueError, ZeroDivisionError):
                raise ValueError(f'{key}: invalid container frame rate')
            require(abs(container_fps / fps - 1) < .005, f'{key}: container frame rate differs from configuration')
        declared_codec = meta.get('streams', {}).get(f'{key}_camera', {}).get('codec')
        if declared_codec:
            require(stream.get('codec_name') == declared_codec, f'{key}: codec differs from metadata')
        pts = [float(f['best_effort_timestamp_time']) for f in probe['frames']]
        require(len(pts) == len(times), f'{key}: movie timestamp count mismatch')
        require(all(b > a for a, b in zip(pts, pts[1:])), f'{key}: non-monotonic movie times')
        # Media retains the SDK synchronization-clock PTS. Host-clock correlation
        # may drift with audio; it is not a media resampling reference.
        capture_times = [float(r.get('capture_pts_sec', r['sensor_sec'])) for r in data]
        pts_error = max(abs((p - pts[0]) - (t - capture_times[0])) for p, t in zip(pts, capture_times))
        require(pts_error < .0002, f'{key}: movie timestamps were resampled ({pts_error})')
        movie_pts[key] = pts
        streams.append(dict(camera=key, resolution=f'{width}x{height}', configured_fps=fps,
                            measured_fps=measured, container_fps=container_fps, frames=len(data), codec=stream.get('codec_name'),
                            max_gap_sec=max(gaps), pts_error_sec=pts_error))
    result = dict(streams=streams, hardware_sync=synchronized)
    if multiple:
        reference = enabled[0][0]
        for key, _, _ in enabled[1:]:
            sensor_delta = float(indices[key][0].get('capture_pts_sec', indices[key][0]['sensor_sec'])) - float(indices[reference][0].get('capture_pts_sec', indices[reference][0]['sensor_sec']))
            movie_delta = movie_pts[key][0] - movie_pts[reference][0]
            require(abs(sensor_delta - movie_delta) < .000005, 'Movies lost their shared capture epoch')
    if synchronized:
        hardware_streams = [camera for camera in enabled if camera[0] in hardware_keys]
        groups = rows(session / 'synchronization.csv')
        require(len(groups) == start['synchronized_group_count'], 'Group metadata count mismatch')
        require(all(len(indices[key]) == len(groups) for key in hardware_keys), 'Unequal hardware stream counts')
        require([int(r['group_index']) for r in groups] == list(range(len(groups))), 'Missing synchronization group')
        max_skew = 0
        for i, group in enumerate(groups):
            times = [float(group[f'{"telephoto" if key == "telephoto" else index}_sensor_sec']) for key, _, index in hardware_streams]
            skew = max(times) - min(times)
            max_skew = max(max_skew, skew)
            require(skew <= .001, f'Group {i}: hardware skew > 1ms')
            require(abs(skew - float(group['max_skew_sec'])) < .000002, f'Group {i}: incorrect skew metadata')
            for key, _, index in hardware_streams:
                field = 'telephoto' if key == 'telephoto' else index
                require(abs(float(group[f'{field}_sensor_sec']) - float(indices[key][i]['sensor_sec'])) < .000002,
                        f'{key}: index/group sample mismatch')
        result.update(groups=len(groups), max_skew_sec=max_skew)
        matrix = meta['camera_extrinsics'].get('T_wide_from_ultrawide')
        if matrix:
            baseline = math.sqrt(sum(row[3] ** 2 for row in matrix))
            require(.001 < baseline < .1, f'Extrinsic baseline unit is wrong: {baseline}m')
            result['camera_baseline_m'] = baseline
    if mixed:
        alignment = rows(session / 'timestamp_alignment.csv')
        reference_index = start['timestamp_alignment']['reference_camera']
        by_index = {index: key for key, _, index in enabled}
        require(reference_index in by_index, 'Invalid timestamp alignment reference')
        reference_key = by_index[reference_index]
        require(len(alignment) == len(indices[reference_key]), 'Alignment index lost reference frames')
        max_skew = 0
        max_overlap_skew = 0
        overlap_start = max(times[0] for times in sensor_times.values())
        overlap_end = min(times[-1] for times in sensor_times.values())
        require(overlap_end > overlap_start, 'Independent camera streams have no overlapping capture interval')
        for i, match in enumerate(alignment):
            require(int(match['reference_frame_index']) == i, 'Discontinuous alignment index')
            reference_time = float(indices[reference_key][i]['sensor_sec'])
            matched_times = []
            for key, _, index in enabled:
                frame = int(match[f'{index}_frame_index'])
                source = indices[key]
                require(0 <= frame < len(source), 'Alignment references an absent media frame')
                t = float(source[frame]['sensor_sec'])
                require(abs(t - float(match[f'{index}_sensor_sec'])) < .000002, 'Alignment changed a source timestamp')
                times = sensor_times[key]
                pos = bisect.bisect_left(times, reference_time)
                nearest = min(range(max(0, pos - 1), min(len(times), pos + 1)), key=lambda p: abs(times[p] - reference_time))
                require(frame == nearest, 'Alignment does not reference the nearest existing frame')
                matched_times.append(t)
            skew = max(matched_times) - min(matched_times)
            require(abs(skew - float(match['max_skew_sec'])) < .000002, 'Wrong alignment skew')
            max_skew = max(max_skew, skew)
            if overlap_start <= reference_time <= overlap_end:
                max_overlap_skew = max(max_overlap_skew, skew)
        fps = float(settings[reference_key]['target_frame_rate'])
        require(max_overlap_skew < 1 / fps + .001, 'Aligned views differ by more than one nominal frame period within their overlap')
        # Independent callbacks can cross the stop boundary with one additional
        # sample in flight. Preserve that real edge frame instead of truncating
        # streams to equal counts; interior cadence/gap checks still apply.
        require(max_skew < 2 / fps + .001, 'Independent camera capture boundaries differ by more than two frame periods')
        require(abs(max_skew - start['timestamp_alignment']['maximum_skew_sec']) < .000002, 'Alignment summary differs from index')
        result['timestamp_alignment'] = dict(rows=len(alignment), maximum_skew_sec=max_skew,
                                             maximum_overlap_skew_sec=max_overlap_skew)
    if settings['imu_enabled']:
        accel, gyro, imu = (rows(session / name) for name in ['accelerometer.csv', 'gyroscope.csv', 'imu.csv'])
        require(accel and gyro and imu, 'Missing raw IMU output')
        accel_by_time = {r['sensor_sec']: r for r in accel}
        gyro_by_time = {r['sensor_sec']: r for r in gyro}
        for sample in imu:
            for table, time, columns in [(accel_by_time, 'accel_sensor_sec', ['ax_m_s2', 'ay_m_s2', 'az_m_s2']),
                                         (gyro_by_time, 'gyro_sensor_sec', ['gx_rad_s', 'gy_rad_s', 'gz_rad_s'])]:
                source = table.get(sample[time])
                require(source is not None, 'IMU references an absent raw sample')
                require(all(sample[c] == source[c] for c in columns), 'IMU/raw values differ')
        result['raw_imu_rows'] = len(imu)
        if settings['device_motion_enabled']:
            motion = rows(session / 'device_motion.csv')
            require(motion, 'Missing fused motion')
            mt = [float(r['sensor_sec']) for r in motion]
            errors = []
            for sample in accel:
                t = float(sample['sensor_sec']); pos = bisect.bisect_left(mt, t)
                nearest = min(range(max(0, pos - 1), min(len(mt), pos + 1)), key=lambda p: abs(mt[p] - t))
                fused = motion[nearest]
                if abs(mt[nearest] - t) < .02:
                    errors.append(math.sqrt(sum((float(sample[f'a{axis}_m_s2']) + float(fused[f'gravity_{axis}_m_s2']) +
                                                 float(fused[f'user_accel_{axis}_m_s2'])) ** 2 for axis in 'xyz')))
            require(errors and statistics.median(errors) < .5, 'Raw acceleration negation differs from fused gravity+user acceleration')
            result['negative_accel_fused_median_error_m_s2'] = statistics.median(errors)
    if settings.get('audio_enabled'):
        audio = rows(session / 'audio_info.csv')
        require(len(audio) > 2, 'Missing audio sample index')
        times = [float(row['sensor_sec']) for row in audio]
        durations = [float(row['duration_sec']) for row in audio]
        require(all(b > a for a, b in zip(times, times[1:])), 'Non-monotonic audio timestamps')
        require(all(0 < b - a < 1.5 * duration for a, b, duration in zip(times, times[1:], durations)), 'Audio sample gap')
        audio_probe = json.loads(subprocess.check_output([
            str(ffprobe), '-v', 'error', '-select_streams', 'a:0', '-count_frames', '-show_streams',
            '-show_entries', 'stream=codec_name,sample_rate,channels,duration,nb_read_frames',
            '-of', 'json', str(session / 'audio.m4a')], text=True, stderr=subprocess.PIPE))
        require(len(audio_probe['streams']) == 1, 'No decodable audio stream')
        stream = audio_probe['streams'][0]
        require(stream['codec_name'] == 'aac', 'Unexpected audio codec')
        require(int(stream['channels']) == int(audio[0]['channels']), 'Wrong audio channel count')
        require(float(stream['sample_rate']) == float(audio[0]['sample_rate_hz']), 'Wrong audio sampling rate')
        indexed_duration = times[-1] + durations[-1] - times[0]
        require(abs(float(stream['duration']) - indexed_duration) < .1, 'Audio duration differs from its index')
        result['audio'] = dict(codec='aac', sample_rate=int(stream['sample_rate']), channels=stream['channels'],
                               decoded_frames=int(stream['nb_read_frames']), duration_sec=float(stream['duration']))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('sessions', nargs='+', type=Path)
    parser.add_argument('--ffprobe', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = []
    for session in args.sessions:
        try:
            report.append(dict(session=str(session), result='PASS', **validate(session, args.ffprobe)))
        except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
            report.append(dict(session=str(session), result='FAIL', error=str(error)))
    payload = json.dumps(report, indent=2)
    if args.output: args.output.write_text(payload)
    print(payload)
    raise SystemExit(any(r['result'] != 'PASS' for r in report))
