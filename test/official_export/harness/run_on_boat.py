#!/usr/bin/env python3 -I
"""Run a P1 harness on Boat, recording the local fork identity before sync.

Usage: python3 -I test/official_export/harness/run_on_boat.py \
  --sandbox bx_... --logs /path/to/evidence -- bash test/official_export/harness/run_gate.sh
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sandbox', required=True)
parser.add_argument('--logs', required=True)
parser.add_argument('--name', default='official-export')
parser.add_argument('--shell')
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
command = args.command
if command[:1] == ['--']:
    command = command[1:]
if not command:
    parser.error('supply a harness command after --')
identity = {
    'OFFICIAL_FORK_HEAD': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'OFFICIAL_FORK_STATUS': subprocess.check_output(
        ['git', 'status', '--porcelain'], cwd=root, text=True).rstrip('\n'),
}
remote = 'export ' + ' '.join(k + '=' + shlex.quote(v) for k, v in identity.items())
remote += '; printf "%s\\n" ' + shlex.quote(json.dumps(identity))
remote += '; ' + shlex.join(command)
runner = root.parent.parent / 'edge.research/bin/boat-run'
# Main-checkout and sibling-worktree layouts both share the research helper.
if not runner.exists():
    runner = root.parent / 'edge.research/bin/boat-run'
env = dict(os.environ, BOAT_RUN_LOGS=args.logs)
raise SystemExit(subprocess.call([
    str(runner), '--sandbox', args.sandbox, '--name', args.name,
    *(['--shell',args.shell] if args.shell else []), str(root), '--', remote,
], env=env))
