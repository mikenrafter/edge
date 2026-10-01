"""Checks for copy inventory completeness and source-location accuracy."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

import collect_explainers as copy


class CopyInventoryTests(unittest.TestCase):
    def test_comments_do_not_become_app_copy(self):
        source = "// 'comment only'\n/* \"also a comment\" */\nText('App explanation')"
        literals = list(copy.dart_literals(source))
        self.assertEqual([row[2] for row in literals], ["'App explanation'"])
        start, end, raw = literals[0]
        self.assertEqual(source[start:end], raw)

    def test_adjacent_literal_paragraph_is_reviewed_as_one_item(self):
        source = "Text('First sentence. '  'Second sentence.')"
        literals = list(copy.dart_literals(source))
        self.assertEqual(len(literals), 1)
        self.assertIn('First sentence.', literals[0][2])
        self.assertIn('Second sentence.', literals[0][2])

    def test_html_includes_accessibility_copy_but_excludes_scripts(self):
        parser = copy.WebsiteText(copy.ROOT / 'docs/test.html')
        parser.feed('<img alt="Band diagram"><script>private code</script><p>How sleep works.</p>')
        self.assertEqual([row['text'] for row in parser.rows], ['Band diagram', 'How sleep works.'])

    def test_all_english_arb_values_are_collected(self):
        strings = json.loads((copy.ROOT / 'lib/l10n/app_en.arb').read_text())
        expected = {key for key, value in strings.items() if not key.startswith('@') and isinstance(value, str)}
        collected = {row['location'] for row in copy.collect() if row.get('kind') == 'arb'}
        self.assertEqual(collected, expected)

    def test_missing_duplicate_and_uncommented_reviews_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            original = pathlib.Path(directory) / 'original.jsonl'
            review = pathlib.Path(directory) / 'review.jsonl'
            original.write_text(json.dumps({'id': 'one'}) + '\n')
            valid = {'id': 'one', 'action': 'keep', 'comment': 'Names the actual control.'}
            cases = [[], [valid, valid], [{**valid, 'comment': ''}], [valid]]
            for rows, expected in zip(cases, [1, 1, 1, 0]):
                review.write_text(''.join(json.dumps(row) + '\n' for row in rows))
                result = subprocess.run([sys.executable, str(copy.ROOT / 'scripts/collect_explainers.py'),
                                         str(original), '--review', str(review)], capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
