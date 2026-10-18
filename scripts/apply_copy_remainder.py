#!/usr/bin/env python3
"""Apply the reviewed rows apply_copy_review.py had to skip for mechanical
reasons: literals the collector cut inside an interpolation, ARB rows whose
placeholders repeat, and spans that shifted once other rows were applied.

Offsets in the corpus belong to the pre-rewrite source, so each row is found by
its exact text, which must occur once. Interpolations must survive as the same
multiset. Legal pages and `remove` rows are not touched here.
"""
import argparse
import collections
import json
import pathlib
import re

from apply_copy_review import ARB_PLACEHOLDER, INTERP, ROOT

MECHANICAL = {
    'literal cut inside an interpolation',
    'interpolations differ',
    'placeholders differ',
    'arb entry not found verbatim',
    'dart span moved',
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('corpus', type=pathlib.Path)
    ap.add_argument('review', type=pathlib.Path)
    ap.add_argument('report', type=pathlib.Path, help='apply-report.json from apply_copy_review.py')
    ap.add_argument('out', type=pathlib.Path)
    args = ap.parse_args()
    corpus = {json.loads(l)['id']: json.loads(l) for l in args.corpus.read_text().splitlines()}
    review = {json.loads(l)['id']: json.loads(l) for l in args.review.read_text().splitlines()}
    todo = [s['id'] for s in json.loads(args.report.read_text())['skipped'] if s['why'] in MECHANICAL]
    applied, skipped = [], []
    by_file = collections.defaultdict(list)
    for rid in todo:
        by_file[corpus[rid]['file']].append(rid)
    for name, ids in sorted(by_file.items()):
        path = ROOT / name
        source = path.read_text()
        for rid in ids:
            entry, new = corpus[rid], review[rid]['replacement']
            old = entry['text']
            pattern = ARB_PLACEHOLDER if entry['kind'] == 'arb' else INTERP
            if collections.Counter(pattern.findall(old)) != collections.Counter(pattern.findall(new)):
                skipped.append((rid, 'interpolations or placeholders differ'))
                continue
            if entry['kind'] == 'arb':
                key = entry['location']
                variants = [(f'"{key}": ' + json.dumps(old, ensure_ascii=a)) for a in (False, True)]
                hit = [v for v in variants if source.count(v) == 1]
                if not hit:
                    skipped.append((rid, 'arb entry not found once'))
                    continue
                source = source.replace(hit[0], f'"{key}": ' + json.dumps(new, ensure_ascii=False))
            else:
                # Adjacent literals are joined by a bare newline in the corpus but
                # carry their indentation in the file.
                found = list(re.finditer(r'[ \t]*\n[ \t]*'.join(re.escape(l.strip()) for l in old.split('\n')), source))
                if len(found) != 1:
                    skipped.append((rid, f'text found {len(found)} times'))
                    continue
                at, end = found[0].span()
                # A fragment starts mid-line, so indent by the line it sits on.
                line_start = source.rfind('\n', 0, at) + 1
                indent = re.match(r'[ \t]*', source[line_start:]).group()
                new = ('\n' + indent).join(l.strip() if i else l for i, l in enumerate(new.split('\n')))
                source = source[:at] + new + source[end:]
            applied.append(rid)
        path.write_text(source)
    args.out.write_text(json.dumps({'applied': applied, 'skipped': [{'id': i, 'why': w} for i, w in skipped]}, indent=1) + '\n')
    print(f'applied {len(applied)}, skipped {len(skipped)}')


if __name__ == '__main__':
    main()
