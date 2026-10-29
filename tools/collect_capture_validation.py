#!/usr/bin/env python3
"""Copy completed traversal recordings without changing any files on the device."""
import argparse
import json
import subprocess
import time
from pathlib import Path
from validate_capture import validate

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True)
parser.add_argument('--manifest', required=True)
parser.add_argument('--destination', required=True, type=Path)
parser.add_argument('--ffprobe', required=True, type=Path)
parser.add_argument('--watch', action='store_true')
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
report_path = args.destination / 'file-validation.json'
report = json.loads(report_path.read_text()) if report_path.exists() else []
seen = {r['index'] for r in report}


def copy(source, destination):
    subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                    '--domain-type', 'appDataContainer', '--domain-identifier', 'com.grape.SensorRecorder',
                    '--source', 'Documents/' + source, '--destination', str(destination), '--timeout', '60'],
                   check=True, capture_output=True, text=True, timeout=70)


while True:
    manifest_path = args.destination / args.manifest
    copy(args.manifest, manifest_path)
    manifest = json.loads(manifest_path.read_text())
    for item in manifest['results']:
        if item['index'] in seen:
            continue
        result = dict(index=item['index'], directory=item['directory'], combination=item['combination'])
        try:
            directory = args.destination / item['directory'] if item['directory'] else None
            if directory is not None: copy(item['directory'], directory)
            if item['error']: raise ValueError(item['error'])
            if directory is None: raise ValueError('No recording directory was produced')
            result.update(result='PASS', **validate(directory, args.ffprobe.resolve()))
        except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
            result.update(result='FAIL', error=str(error))
        report.append(result)
        seen.add(item['index'])
        report_path.write_text(json.dumps(report, indent=2))
        print(json.dumps(result), flush=True)
    if not args.watch or len(manifest['results']) >= manifest['total_profiles']:
        break
    time.sleep(10)
