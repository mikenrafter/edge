#!/usr/bin/env python3
"""Collect English app and website copy with source locations for line review."""
import argparse
import hashlib
import json
import pathlib
import re
from html.parser import HTMLParser

ROOT = pathlib.Path(__file__).resolve().parents[1]


def entry(path, location, text, **extra):
    name = str(path.relative_to(ROOT))
    identity = f"{name}:{location}"
    return {"id": identity, "file": name, "location": location, "text": text,
            "sha256": hashlib.sha256(text.encode()).hexdigest(), **extra}


def dart_literals(source):
    # Consume comments as tokens so quoted prose inside comments is excluded.
    token = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|r?(?:"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27)''')
    pending = None
    for match in token.finditer(source):
        raw = match.group()
        if raw.startswith(('//', '/*')):
            if pending:
                yield pending
                pending = None
            continue
        if pending and not source[pending[1]:match.start()].strip():
            pending = (pending[0], match.end(), pending[2] + '\n' + raw)
        else:
            if pending:
                yield pending
            pending = (match.start(), match.end(), raw)
    if pending:
        yield pending


class WebsiteText(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path, self.hidden, self.rows = path, 0, []
        self.serial = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.hidden += 1
        for name, value in attrs:
            if name in ('alt', 'title', 'aria-label') and value:
                self.serial += 1
                self.rows.append(entry(self.path, f"html-{self.serial}", value,
                                       line=self.getpos()[0], attribute=name))

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden and data.strip() and re.search('[A-Za-z]', data):
            self.serial += 1
            self.rows.append(entry(self.path, f"html-{self.serial}", data.strip(),
                                   line=self.getpos()[0]))


def collect():
    rows = []
    arb = ROOT / 'lib/l10n/app_en.arb'
    for key, value in json.loads(arb.read_text()).items():
        if not key.startswith('@') and isinstance(value, str):
            rows.append(entry(arb, key, value, kind='arb'))
    # Include phrase literals without a length cutoff, so short explanations
    # survive. Generated l10n is not an editing source. Imports and machine
    # identifiers are excluded; ambiguous phrases stay for human review.
    paths = [path for path in (ROOT / 'lib').rglob('*.dart')
             if 'l10n' not in path.parts]
    for path in sorted(paths):
        source = path.read_text()
        for start, end, raw in dart_literals(source):
            if re.search('[A-Za-z]', raw) and re.search(r'[A-Za-z][ ,;:!?][A-Za-z]|[A-Za-z] [A-Za-z]', raw):
                rows.append(entry(path, f"offset-{start}", raw, kind='dart',
                                   start=start, end=end,
                                   line=source.count('\n', 0, start) + 1))
    for path in sorted((ROOT / 'docs').glob('*.html')):
        parser = WebsiteText(path)
        parser.feed(path.read_text())
        rows.extend(parser.rows)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--review', type=pathlib.Path)
    args = parser.parse_args()
    rows = collect()
    if args.review:
        originals = [json.loads(line) for line in args.output.read_text().splitlines()]
        reviewed = [json.loads(line) for line in args.review.read_text().splitlines() if line.strip()]
        expected = {row['id'] for row in originals}
        counts = {}
        for row in reviewed:
            counts[row['id']] = counts.get(row['id'], 0) + 1
            if not row.get('comment') or row.get('action') not in ('keep', 'rephrase', 'remove', 'source', 'noncopy'):
                raise SystemExit(f"Invalid review row: {row['id']}")
        missing = sorted(expected - counts.keys())
        unexpected = sorted(counts.keys() - expected)
        duplicates = sorted(key for key, count in counts.items() if count != 1)
        print(json.dumps({'expected': len(expected), 'reviewed': len(reviewed),
                          'missing': missing, 'unexpected': unexpected,
                          'duplicates': duplicates}, indent=2))
        if missing or unexpected or duplicates:
            raise SystemExit(1)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))
        print(f"Collected {len(rows)} items into {args.output}")


if __name__ == '__main__':
    main()
