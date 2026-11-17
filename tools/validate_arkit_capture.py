#!/usr/bin/env python3
"""Decode ARKit recordings and reject missing target slots, even if UI tests pass."""
import argparse
import json
import math
import subprocess
from pathlib import Path

from validate_capture import rows, require


def validate(session, ffprobe, allow_source_gaps=False):
    meta = json.loads((session / 'meta.json').read_text())
    require(meta['capture_mode'] == 'arkit', 'Not an ARKit recording')
    require(meta['state'] == 'finished', f"Recording failed: {meta['recording_start'].get('failure', meta['state'])}")
    settings = meta['recording_settings']['arkit_camera']
    stream_meta = meta['streams']['arkit_pose']
    data = rows(session / 'arkit_pose.csv')
    require(len(data) >= 3, 'Insufficient pose/video samples')
    require([int(row['frame_index']) for row in data] == list(range(len(data))), 'Discontinuous ARKit frame_index')
    slots = [int(row['record_slot']) for row in data]
    require(slots[0] == 0 and all(b > a for a, b in zip(slots, slots[1:])), 'Non-monotonic ARKit record_slot')
    missing = sum(b - a - 1 for a, b in zip(slots, slots[1:]))
    if not allow_source_gaps:
        require(missing == 0, 'Discontinuous ARKit record_slot')
    integrity = meta['recording_start'].get('arkit_frame_integrity')
    if integrity is not None:
        require(integrity['missing_target_slots'] == missing, 'Metadata gap count differs from recorded timestamps')
    width, height = map(int, settings['resolution'].split('x'))
    require(all((int(r['width_px']), int(r['height_px'])) == (width, height) for r in data), 'Pose index dimensions differ from settings')
    for row in data:
        require(all(math.isfinite(float(row[k])) for k in ['tx_m', 'ty_m', 'tz_m', 'qw', 'qx', 'qy', 'qz']), 'Non-finite pose')
        require(abs(sum(float(row[k]) ** 2 for k in ['qw', 'qx', 'qy', 'qz']) - 1) < .001, 'Non-unit pose quaternion')
        if 'exposure_mid_sensor_sec' in row:
            duration = float(row['exposure_sec'])
            midpoint = float(row['exposure_mid_sensor_sec'])
            require(row['exposure_source'] == 'arkit_frame', 'Unexpected ARKit exposure source')
            if math.isfinite(duration) and duration > 0:
                require(abs(midpoint - (float(row['sensor_sec']) + duration / 2)) < .000002,
                        'ARKit exposure midpoint does not match the frame')
            else:
                require(math.isnan(midpoint), 'ARKit midpoint was invented without exposure data')
    times = [float(r['sensor_sec']) for r in data]
    gaps = [b - a for a, b in zip(times, times[1:])]
    target = float(settings['target_frame_rate'])
    capture = float(stream_meta['capture_fps'])
    actual = (len(times) - 1) / (times[-1] - times[0])
    require(min(gaps) > 0, 'Non-monotonic ARKit timestamps')
    if not allow_source_gaps:
        require(abs(actual / target - 1) < .005, 'Actual frame rate differs from configuration')
    # Downsampling can legitimately alternate source-frame intervals.
    maximum_gap = (math.ceil(capture / target) + .5) / capture
    if not allow_source_gaps:
        require(max(gaps) < maximum_gap, 'Missing ARKit frame interval')
    probe = json.loads(subprocess.check_output([
        str(ffprobe), '-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_streams', '-show_frames',
        '-show_entries', 'stream=codec_name,width,height,nb_read_frames:frame=best_effort_timestamp_time',
        '-of', 'json', str(session / stream_meta['media_file'])], text=True, stderr=subprocess.PIPE))
    require(len(probe['streams']) == 1, 'No readable video stream')
    stream = probe['streams'][0]
    require((stream['width'], stream['height']) == (width, height), 'Encoded dimensions differ from settings')
    require(int(stream['nb_read_frames']) == len(data), 'Decoded/index frame count mismatch')
    codec = {'hvc1': 'hevc', 'avc1': 'h264'}.get(stream_meta['codec'], stream_meta['codec'])
    require(stream['codec_name'] == codec, 'Encoded codec differs from metadata')
    pts = [float(f['best_effort_timestamp_time']) for f in probe['frames']]
    require(len(pts) == len(times) and all(b > a for a, b in zip(pts, pts[1:])), 'Invalid video timestamps')
    error = max(abs((p - pts[0]) - (t - times[0])) for p, t in zip(pts, times))
    require(error < .0002, 'Video and pose timestamps differ')
    trace = rows(session / 'performance.csv')
    require(len(trace) >= 2, 'Missing ARKit performance trace')
    return dict(session=str(session), result='PASS_FORMAT_WITH_SOURCE_GAPS' if missing else 'PASS',
                missing_target_slots=missing, frames=len(data), measured_fps=actual,
                resolution=f'{width}x{height}', max_gap_sec=max(gaps), pts_error_sec=error,
                tracking_states=sorted({r['tracking_state'] for r in data}), performance_rows=len(trace))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sessions', nargs='+', type=Path)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-source-gaps', action='store_true', help='Validate preserved media/poses while reporting source gaps; does not certify uninterrupted capture')
    args = parser.parse_args()
    results = []
    for session in args.sessions:
        try:
            results.append(validate(session, args.ffprobe, args.allow_source_gaps))
        except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
            results.append(dict(session=str(session), result='FAIL', failure=str(error)))
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
    return 1 if any(r['result'] == 'FAIL' for r in results) else 0


if __name__ == '__main__':
    raise SystemExit(main())
