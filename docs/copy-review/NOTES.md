# Copy review record

Model: `claude-sonnet-5-5` through the `claude` CLI (`scripts/run_copy_review.py`).
Prompt: `prompt.md` plus the unslop and plain-writing rules in `skills.txt`.
Corpus: `corpus.jsonl`, 7926 items from `scripts/collect_explainers.py` at commit `a0fcf0a`
(every English ARB string, Dart string literal with prose, and website text node).

Full output: `review.jsonl`, one row per corpus ID with `action`, `comment`,
`lineComments` (one per physical line) and `replacement`. `run/out/` holds each
batch's raw CLI result. CLI session IDs per batch are in `sessions.json`. Total cost
$18.76. The CLI also reports `claude-haiku-4-5-20251001` in its usage block;
Sonnet wrote every row.

Coverage check: `python3 scripts/collect_explainers.py docs/copy-review/corpus.jsonl --review docs/copy-review/review.jsonl`
reports 0 missing, 0 duplicate, 0 unexpected. One extra row Sonnet invented
(`settingsZoneAlertRowSubStub`) was dropped. 22 rows with the wrong number of line
comments were re-asked (`run/repair-out/`).

Actions: {'noncopy': 2433, 'keep': 4081, 'rephrase': 1382, 'source': 21, 'remove': 9}.

## Applied

`scripts/apply_copy_review.py` applied 1309 replacements (rephrase and source rows).
Skipped rows are in `apply-report.json` with a reason:
{'placeholders differ': 2, 'literal cut inside an interpolation': 28, 'interpolations differ': 1, 'legal text; owner review': 60, 'arb entry not found verbatim': 1, 'dart span moved': 1}.

- Legal pages (`docs/terms.html`, `privacy.html`, `legal.html`, `notice.html`) are not
  edited. Sonnet's rewrites are in `review.jsonl` for the owner to review.
- 28 Dart rows are literals the collector cut inside a `${...}` expression
  (`'${x.split('.').first}'`). Applying them would corrupt code, so they stay as written.
- 2 ARB rows with changed placeholders, 1 missing ARB key, and 1 moved Dart span were skipped.
- `remove` rows: applied 3 (two rotating coach status phrases, the coach slogan row and
  its ARB key in all locales). Not applied, because the widget needs a body or title:
  four empty-state `StatusCard` bodies in `summary.dart` and `nutrition_screen.dart`,
  and the beats scatter chart title.
- After the apply, 59 tests pinned old wording. Triage updated the tests, fixed 8 copy
  rewrites that were wrong or weaker (see the commit), and reverted one literal
  ("That did not work" in `device_picker.dart` and `pairSensorThatDidNotWork`).
- Only English ARB text changed. Other locales keep their translations.

## Gaps in the corpus

The collector does not read `<meta>` description or Open Graph `content` attributes,
JSON-LD, or developer comments. The meta description still says "No cloud, no account".
