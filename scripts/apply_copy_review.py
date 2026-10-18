#!/usr/bin/env python3
"""Apply reviewed replacements to the offsets recorded in the corpus.

Rows are skipped, and listed, when the source no longer matches the corpus,
when interpolations or placeholders differ, or when the file is legal text.
`remove` rows are never applied here: deleting a string needs its call site.
"""
import argparse
import collections
import html
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
LEGAL = {'docs/terms.html', 'docs/privacy.html', 'docs/legal.html', 'docs/notice.html'}
INTERP = re.compile(r'\$\{[^}]*\}|\$[A-Za-z_]\w*')
ARB_PLACEHOLDER = re.compile(r'\{[A-Za-z_]\w*\}')


def unbalanced_interpolation(text):
    """True when the collector cut a literal inside a `${...}` expression."""
    depth = 0
    i = 0
    while i < len(text):
        if text.startswith('${', i):
            depth += 1
            i += 2
        elif text[i] == '}' and depth:
            depth -= 1
            i += 1
        elif text[i] == '}':
            return True
        else:
            i += 1
    return depth != 0


def indent_continuations(replacement, source, start):
    lines = replacement.split('\n')
    if len(lines) == 1:
        return replacement
    column = start - (source.rfind('\n', 0, start) + 1)
    return ('\n' + ' ' * column).join(line.strip() if i else line for i, line in enumerate(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('corpus', type=pathlib.Path)
    ap.add_argument('review', type=pathlib.Path)
    ap.add_argument('report', type=pathlib.Path)
    args = ap.parse_args()
    corpus = {json.loads(l)['id']: json.loads(l) for l in args.corpus.read_text().splitlines()}
    work = collections.defaultdict(list)
    skipped = []
    for line in args.review.read_text().splitlines():
        row = json.loads(line)
        entry = corpus[row['id']]
        old, new = entry['text'], row.get('replacement')
        if row['action'] not in ('rephrase', 'source') or new is None or new == old:
            continue
        if entry['file'] in LEGAL:
            skipped.append((row['id'], 'legal text; owner review'))
        elif entry.get('kind') == 'dart' and unbalanced_interpolation(old):
            skipped.append((row['id'], 'literal cut inside an interpolation'))
        elif entry.get('kind') == 'dart' and INTERP.findall(old) != INTERP.findall(new):
            skipped.append((row['id'], 'interpolations differ'))
        elif entry.get('kind') == 'arb' and sorted(ARB_PLACEHOLDER.findall(old)) != sorted(ARB_PLACEHOLDER.findall(new)):
            skipped.append((row['id'], 'placeholders differ'))
        elif not new.strip():
            skipped.append((row['id'], 'empty replacement'))
        else:
            work[entry['file']].append((entry, new))
    applied = 0
    for name, items in sorted(work.items()):
        path = ROOT / name
        source = path.read_text()
        if name.endswith('.arb'):
            for entry, new in items:
                key = entry['location']
                old_lit = f'"{key}": ' + json.dumps(entry['text'], ensure_ascii=False)
                if source.count(old_lit) != 1:
                    skipped.append((entry['id'], 'arb entry not found verbatim'))
                    continue
                source = source.replace(old_lit, f'"{key}": ' + json.dumps(new, ensure_ascii=False))
                applied += 1
        elif name.endswith('.html'):
            offsets = [0]
            for text_line in source.split('\n'):
                offsets.append(offsets[-1] + len(text_line) + 1)
            for entry, new in sorted(items, key=lambda it: -it[0]['line']):
                # The corpus holds decoded text; the file holds entities. Match a
                # raw text node whose decoded, stripped form equals the corpus text.
                found = None
                line_start = offsets[entry['line'] - 1]
                starts = [line_start] + [line_start + m.end() for m in re.finditer('>', source[line_start:line_start + 400])]
                for begin in starts:
                    end = source.find('<', begin)
                    chunk = source[begin:end] if end >= 0 else ''
                    if chunk.strip() and html.unescape(chunk).strip() == entry['text']:
                        found = (begin + len(chunk) - len(chunk.lstrip()), begin + len(chunk.rstrip()))
                        break
                if not found:
                    skipped.append((entry['id'], 'html text not found verbatim'))
                    continue
                source = source[:found[0]] + html.escape(new, quote=False) + source[found[1]:]
                applied += 1
        else:
            for entry, new in sorted(items, key=lambda it: -it[0]['start']):
                start, end = entry['start'], entry['end']
                if not source[start:end].startswith(('r', "'", '"')) or source[start:end].count('\n') != entry['text'].count('\n'):
                    skipped.append((entry['id'], 'dart span moved'))
                    continue
                source = source[:start] + indent_continuations(new, source, start) + source[end:]
                applied += 1
        path.write_text(source)
    args.report.write_text(json.dumps({'applied': applied, 'skipped': [{'id': i, 'why': w} for i, w in skipped]}, indent=1) + '\n')
    print(f'applied {applied}, skipped {len(skipped)}')


if __name__ == '__main__':
    main()
