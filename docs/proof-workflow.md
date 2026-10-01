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

`test/proof` captures affected production views with bundled fonts in light and
dark mode at normal and doubled text size. Keep fixtures synthetic and label
them as such. Image comparisons use committed baselines for these selected
views. Regenerate a baseline only after reviewing the changed image.

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
