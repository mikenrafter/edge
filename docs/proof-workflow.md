# Capturing implementation proof

Run `make proof PROOF_DIR=build/proof/before-copy` from the repo root.
The command uses the Flutter 3.41.6 Nix shell and needs no emulator. Run
`make proof-native` to include Android JVM unit tests.

Each capture retains the source commit, working-tree patch, source hashes,
toolchain version, dependency-pin check, analyzer output, serial Flutter JSON
test events, headless widget PNGs, and hashes of the resulting artifacts.
`manifest.json` records command exit codes and skipped tests. A failed command
makes the capture fail; its log remains available for diagnosis.

Behavioral tests exercise the production sync/sleep coordinators and alert
dispatcher through injected dependencies. SQLite tests use the real database
implementation. Relay policy tests replay native metadata through the same
controller used by the app. Source guards check wiring and forbidden bypasses.
They do not establish native lifecycle behavior by themselves.

The proof view tests (`test/ui2_*_views_test.dart`) keep golden pictures only where pixels are the
point (see "Golden fixtures" below). Other screens are covered by structural
tests: what the screen must contain, and no overflow at phone sizes. Keep
fixtures synthetic and label them as such. Image comparisons use committed
baselines. Regenerate a baseline only after reviewing the changed image.

The wider existing gallery suite skips pixel comparisons when its local golden
directory is absent. Those skips remain in the manifest. They are separate from
the committed proof views.

Android notification extraction and permission/rebind behavior need native
tests. Real notification delivery, band haptics, native alarm firing, and
background survival need device checks. iOS, WidgetKit, and watch targets need
macOS/Xcode. Record the exercised hardware and OS versions with those results.

For copy changes, collect the corpus with
`python3 scripts/collect_explainers.py docs/copy-review/corpus.jsonl`.
Sonnet's review has one JSON row per corpus ID with `action` and `comment`.
Run the collector with `--review docs/copy-review/review.jsonl` to detect missing,
duplicate, unexpected, or uncommented items. Retain the prompt, CLI session ID,
full output, and model metadata. Repeat the proof capture after applying edits.

## Golden fixtures

Every fixture is one of two kinds.

- PAINTER: a custom painter, a chart, a symbol or a ring, where the pixels are
  what is being protected. Pictures in light and dark, at 1x and 2x text.
- SCREEN: a page or panel built from ordinary widgets. At most six showcase
  screens keep a picture, in light and dark at 1x text only. Every other
  screen has structural tests in place of a picture: key finders for what it
  must show, and no overflow (`tester.takeException()` is null) at 360x640,
  390x844, and 360x640 at 2x text, scrolled to the bottom. The harness is
  `test/support/structure_harness.dart` (`screenStructure`).

Why: a SCREEN picture records every pixel of text, so any copy edit or font
change shows up as a diff. Reviewers stop looking, and the baseline records
the bug. A finder fails on the thing that matters and names it.

Committed fixtures (`test/fixtures/proof_goldens`):

| fixture | file | kind | pictures kept |
|---|---|---|---|
| chart_key_day_hr_gaps, _no_gaps, _on_gap, _scrubbed | test/ui2_chart_key_views_test.dart | PAINTER | light/dark x 1x/2x |
| chart_key_two_series, chart_key_row | test/ui2_chart_key_views_test.dart | PAINTER | light/dark x 1x/2x |
| chart_scrub_readout | test/ui2_buzz_chart_live_views_test.dart | PAINTER | light/dark x 1x/2x |
| live_devices (line charts) | test/ui2_buzz_chart_live_views_test.dart | PAINTER | light/dark x 1x/2x |
| alerts_android (Settings, alerts) | test/ui2_sync_alerts_views_test.dart | SCREEN, showcase | light/dark 1x |
| primary_band_sync (device page) | test/ui2_sync_alerts_views_test.dart | SCREEN, showcase | light/dark 1x |
| buzz_pattern (pattern editor) | test/ui2_buzz_chart_live_views_test.dart | SCREEN, showcase | light/dark 1x |
| sync_offline, _downloading, _calculating, _waiting, _failed, _completed | test/ui2_sync_alerts_views_test.dart | SCREEN | none, structural |
| sleep_empty, sleep_asserted_without_metrics, sleep_inferred_window | test/ui2_sync_alerts_views_test.dart | SCREEN | none, structural |
| alerts_other_platform, relay_disabled, relay_enabled | test/ui2_sync_alerts_views_test.dart | SCREEN | none, structural |
| gestures_none_selected, gestures_mark_moment_and_flashlight, demo_disclosure | test/ui2_sync_alerts_views_test.dart | SCREEN | none, structural |
| device_lab_mg, _device_lab_no_ecg, _collapsed_taps | test/ui2_buzz_chart_live_views_test.dart | SCREEN | none, structural |
| gestures_draft_taps_no_ecg, _gestures_tap_method_mg | test/ui2_buzz_chart_live_views_test.dart | SCREEN | none, structural |
| source_catalog, resolved_data | test/sources_structure_views_test.dart | SCREEN | none, structural |

Showcase screens that exist only as local goldens (Home, Health overview,
Settings pages in `test/ui2_home_health_golden_test.dart` and
`test/ui2_onboarding_profile_golden_test.dart`) are SCREEN fixtures at 1x. The
component vocabulary in `test/ui2_golden_test.dart` is PAINTER (1x and 2x). In
`test/ui2_activity_test.dart` the summaries and the share card are PAINTER
(route, trace, laps); the picker and setup page are SCREEN at 1x. The
`test/goldens/` directory is gitignored and its suites skip when it is absent.

## Regenerating goldens

Regenerate only when the image is supposed to change: a deliberate design or
layout change to that fixture. Never to turn a red run green, and never for a
diff you cannot explain.

1. Run the failing test and look at the failure images. A failed comparison
   writes `*_masterImage.png`, `*_testImage.png`, `*_isolatedDiff.png` and
   `*_maskedDiff.png` under `test/**/failures/`. CI uploads that folder as the
   `golden-failures` artifact when the test job fails.
2. View at least one regenerated image yourself before committing. Check text
   is readable (not block glyphs), nothing is clipped, and both themes look
   right.
3. Regenerate only the affected file:
   `nix develop -c flutter test --update-goldens test/<file>_test.dart`.
   Use `--plain-name` to narrow it to the fixture.
4. In the commit message list the fixtures you regenerated and why each one
   changed. "Update goldens" alone is not an explanation.
5. Apply the PAINTER/SCREEN rule when adding a fixture. A new SCREEN fixture
   gets structural tests, not a picture, unless it is one of the six showcase
   screens. A new PAINTER fixture gets all four pictures.
6. Do not regenerate to fix an overflow. The structural tests fail on overflow
   independently of any picture; fix the layout.
