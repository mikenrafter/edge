#!/usr/bin/env python3
"""Send corpus batches to Claude Sonnet 5.5 and save rows, transcripts and session IDs."""
import argparse
import concurrent.futures
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = 'claude-sonnet-5-5'
SCHEMA = {
    'type': 'object',
    'required': ['rows'],
    'properties': {'rows': {'type': 'array', 'items': {
        'type': 'object',
        'required': ['id', 'action', 'comment', 'lineComments'],
        'properties': {
            'id': {'type': 'string'},
            'action': {'enum': ['keep', 'rephrase', 'remove', 'source', 'noncopy']},
            'comment': {'type': 'string'},
            'lineComments': {'type': 'array', 'items': {'type': 'string'}},
            'replacement': {'type': 'string'},
        }}}},
}


def review(batch_path, out_dir, review_dir):
    name = batch_path.stem
    rows = [json.loads(l) for l in batch_path.read_text().splitlines()]
    sent = [{k: r[k] for k in ('id', 'file', 'location', 'text', 'kind', 'line') if k in r}
            for r in rows]
    prompt = ('Review these rows.\n' + ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in sent))
    system = (review_dir / 'prompt.md').read_text() + '\n\n# Writing rules\n\n' + (review_dir / 'skills.txt').read_text()
    done = out_dir / f'{name}.result.json'
    if done.exists():
        return name, 'cached'
    proc = subprocess.run(
        ['claude', '-p', '--model', MODEL, '--output-format', 'json',
         '--json-schema', json.dumps(SCHEMA), '--append-system-prompt', system,
         '--allowedTools', 'Read,Grep,Glob', '--permission-mode', 'dontAsk'],
        input=prompt, text=True, capture_output=True, cwd=ROOT)
    (out_dir / f'{name}.stdout.json').write_text(proc.stdout)
    (out_dir / f'{name}.stderr.txt').write_text(proc.stderr)
    if proc.returncode:
        return name, f'exit {proc.returncode}'
    done.write_text(proc.stdout)
    return name, 'ok'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('batch_dir', type=pathlib.Path)
    ap.add_argument('out_dir', type=pathlib.Path)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--only', nargs='*')
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    review_dir = ROOT / 'docs/copy-review'
    batches = sorted(p for p in args.batch_dir.glob('*.jsonl'))
    if args.only:
        batches = [b for b in batches if b.stem in args.only]
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for name, status in pool.map(lambda b: review(b, args.out_dir, review_dir), batches):
            print(name, status, flush=True)


if __name__ == '__main__':
    main()
