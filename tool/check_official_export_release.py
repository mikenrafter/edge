#!/usr/bin/env python3
"""Build-time gate: the embedded official-export target is still latest stable.

Run before building the fork, after the targeted exporter and pinned receiver
checks. This records target identity; it does not certify APK/device behavior.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    profile_bytes = (root / 'assets/official_export/v0.11.3.json').read_bytes()
    profile = json.loads(profile_bytes)
    target = profile['target']
    source_schema = int(re.search(r'const int schemaVersion\s*=\s*(\d+)',
        (root / 'lib/data/db.dart').read_text()).group(1))
    source_algorithm = int(re.search(r'const int kAlgoVersion\s*=\s*(\d+)',
        (root / 'lib/compute/derivation_engine.dart').read_text()).group(1))
    if (source_schema, source_algorithm) != (profile['source']['schema'], profile['source']['algorithm']):
        raise SystemExit('Fork schema or algorithm changed. Refresh the profile source identity and rerun export checks.')
    request = urllib.request.Request(
        'https://api.github.com/repos/OpenStrap/edge/releases/latest',
        headers={'User-Agent': 'OpenStrap-official-export-certification',
                 'Accept': 'application/vnd.github+json'},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        release = json.load(response)
    if release['draft'] or release['prerelease'] or release['tag_name'] != target['tag']:
        raise SystemExit('Official stable release changed. Update the profile and rerun receiver tests before building.')
    peeled = subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', target['tag'] + '^{}'], text=True,
    ).strip()
    if peeled != target['sha']:
        raise SystemExit('Official tag does not resolve to the tested source SHA.')
    proof = {
        'stage': 'pilot',
        'scope': 'Latest stable release identity only; receiver and device checks are separate gates',
        'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'release_id': release['id'], 'target_tag': target['tag'],
        'target_sha': peeled, 'target_schema': target['schema'],
        'target_algorithm': target['algorithm'],
        'profile_sha256': hashlib.sha256(profile_bytes).hexdigest(),
        'fork_head': subprocess.check_output(
            ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True,
        ).strip(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(proof, indent=2) + '\n')
    print(f"Official export target checked: {target['tag']} at {peeled}")


if __name__ == '__main__':
    main()
