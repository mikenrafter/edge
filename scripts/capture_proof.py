#!/usr/bin/env python3
"""Capture reproducible headless evidence and report every command's status."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--native', action='store_true', help='also run Android JVM tests')
    parser.add_argument('--direct', action='store_true', help='use an already installed pinned CI SDK')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = {}
    for line in subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0'):
        path = ROOT / line
        if line and path.is_file():
            sources[line] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / 'source-sha256.json').write_text(json.dumps(sources, indent=2) + '\n')
    (output / 'working-tree.patch').write_text(git('diff', 'HEAD', '--binary') + '\n')
    manifest = {'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'commit': git('rev-parse', 'HEAD'), 'status': git('status', '--short'),
                'sourceHashes': 'source-sha256.json', 'commands': [],
                'limitations': [
                    'Headless widget captures do not establish native permission or service behavior.',
                    'No real-band alarm firing, haptic waveform, or background survival is established.',
                    'iOS, WidgetKit, and watch builds require macOS/Xcode.',
                ]}
    commands = [
        ('proof-tools', ['python3', '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_proof_tools.py']),
        ('toolchain', ['flutter', '--version']),
        ('pins', ['bash', '.github/scripts/check_sibling_pins.sh']),
        ('analyze', ['flutter', 'analyze']),
        ('tests', ['flutter', 'test', '--concurrency=1', '--reporter=json']),
        ('screenshots', ['flutter', 'test', '--concurrency=1', 'test/proof', '--reporter=json']),
    ]
    if args.native:
        commands.append(('android-jvm', ['bash', '-c', 'cd android && ./gradlew testDebugUnitTest']))
    else:
        manifest['limitations'].append('Android JVM tests were not requested in this capture.')
    env = dict(os.environ, EDGE_PROOF_DIR=str(output / 'screenshots'))
    failures = []
    for name, command in commands:
        print(f"Capturing {name}", flush=True)
        start = time.monotonic()
        full = command if args.direct else ['nix', 'develop', '--command', 'edge-fhs', *command]
        logfile = output / f'{name}.log'
        with logfile.open('w') as log:
            try:
                result = subprocess.run(full, cwd=ROOT, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=1800)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
                log.write('\nCapture command timed out after 1800 seconds.\n')
        row = {'name': name, 'argv': full, 'exitCode': code,
               'durationSeconds': round(time.monotonic() - start, 2), 'log': logfile.name,
               'sha256': hashlib.sha256(logfile.read_bytes()).hexdigest()}
        if name in ('tests', 'screenshots'):
            events = []
            for line in logfile.read_text().splitlines():
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict):
                    events.append(event)
            row['testDone'] = sum(e.get('type') == 'testDone' for e in events)
            row['failedTests'] = [e for e in events if e.get('type') == 'testDone' and e.get('result') in ('failure', 'error')]
            row['skippedTests'] = [e for e in events if e.get('type') == 'testDone' and e.get('skipped')]
            row['done'] = [e for e in events if e.get('type') == 'done']
        manifest['commands'].append(row)
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if code:
            failures.append(name)
    artifacts = {}
    for path in output.rglob('*'):
        if path.is_file() and path.name not in ('manifest.json', 'artifacts-sha256.json'):
            artifacts[str(path.relative_to(output))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / 'artifacts-sha256.json').write_text(json.dumps(artifacts, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'failedCommands': failures}, indent=2))
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
