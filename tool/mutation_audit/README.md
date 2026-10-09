# mutation_audit

The pilot's in-house mutation audit (design 05, section 4; conventions in
`edge.research/design/05-c2a-mutation-notes.md`). It generates mutants from the
AST with `package:analyzer`, runs the tests against each one in a disposable
export of a pinned commit, and classifies the outcome from the JSON test reporter.

Standalone Dart package: it is not a dependency of the app, and the app's
`flutter analyze` skips it (`analysis_options.yaml` excludes `tool/mutation_audit/**`).

## Running the tests

From the repository root, inside the repo flake (it provides the Dart SDK):

```
nix develop . -c bash -c 'cd tool/mutation_audit && dart pub get --offline && dart test'
# or, from tool/mutation_audit:
nix develop ../.. -c dart test
nix develop ../.. -c dart analyze
```

The export tests use the real `git` binary on throwaway repositories under the
system temp directory. No test reads the clock or spawns the test runner: the
process runner is a fake that answers from the file contents it sees.

## Command line

```
dart run mutation_audit --repo <path> --sha <rev> --files <glob>... \
  [--test-cmd "<cmd>"] [--tests <file>...] [--max-mutants N] [--sample N --seed S] \
  [--timeout seconds] (--guard-pattern <glob>... | --no-guards) [--allow-override <path>...] \
  [--flaky-test <suite::name>...] [--setup-cmd "<cmd>"] --out <dir>
```

`--test-cmd` defaults to `flutter test --reporter json` for a Flutter package and
`dart test --reporter json` otherwise (`--reporter json` is added when missing).
`--setup-cmd` runs once in the export before the baseline (default: `flutter pub get`
/ `dart pub get`; `""` skips it). Exit codes: 0 ran, 64 usage, 65 baseline failed or
path override refused, 70 export/internal error, 130 interrupted.

`--env KEY=VALUE` (repeatable) sets variables for every child process on top of the
parent's environment; the default is `TZ=UTC`, which the tests of both repos assume.

The tool does not know about nix. The test command is run with the `PATH` of whoever
started the tool, so wrap the tool in the shell of the repository being audited:

```
cd tool/mutation_audit
nix develop /path/to/analytics -c dart run mutation_audit --repo /path/to/analytics --sha <sha> \
  --files lib/src/onehz/incremental_core.dart \
  --tests test/onehz/incremental/int_histogram_test.dart --max-mutants 8 --out /tmp/mutation/analytics
nix develop /path/to/edge -c dart run mutation_audit --repo /path/to/edge --sha <sha> \
  --files lib/ui2/chart_annotations.dart --tests test/properties/annotation_layout_laws_test.dart \
  --max-mutants 5 --out /tmp/mutation/edge
```

(or put `nix develop <repo> -c` inside `--test-cmd` and `--setup-cmd`). A fresh export has no
package config: the setup command (`flutter pub get` / `dart pub get`) runs in it first.
Results go to `--out`, which must be outside the export.

## Source guards: classify them or say there are none

A source guard is a test that reads source text (`File('lib/...').readAsStringSync()`, the
`test/support/dart_source*.dart` scanner) instead of running code. When a mutant makes one fail,
that is not runtime coverage, so such failures are reported as `killed-by-guard-only` and stay out
of the score.

A whole-suite audit (no `--tests`) therefore has to say how its guards are classified, or the
tool refuses to start (exit 64):

- `--guard-pattern <glob>...`: suites matching any glob are guards. A pattern without `/` matches
  the file name; one with `/` matches the path or any suffix of it.
- `--no-guards`: the author states that no test of this suite scans source text. Recorded in the
  report as `guardPolicy: none-declared`. Cannot be combined with `--guard-pattern`.
- an explicit `--tests` list needs neither (`guardPolicy: subset`); the author picked the tests.

The report records the policy (`meta.guardPolicy`, `meta.guardPatterns`; Markdown "Source guards").

Defaults for this repository, found by grepping `test/` for tests that read `lib/` text and by the
naming convention of the guard tests (`<!-- guard-patterns:edge -->` is read by a test that checks
these globs against real file names):

<!-- guard-patterns:edge -->
```
test/guards/**
*_guard_test.dart
*_guards_test.dart
*_wiring_test.dart
*_structural_test.dart
*_inventory_test.dart
*_audit_test.dart
no_*_test.dart
```
<!-- /guard-patterns:edge -->

These are file-level: a guard that lives inside a mostly-runtime test file is not caught, and
a matched file loses all of its tests as kill credit (the safe direction: the score can only go
down). Test files that use the shared source scanner but are not matched are listed with
`grep -rlE "support/dart_source(_lexical)?\.dart" test | sort`; when mutating code those files
cover, either pass `--tests` with the runtime tests you mean, or add the file to `--guard-pattern`.

`openstrap-analytics` has no test that scans source text (its file reads are data fixtures), so
audit it with `--no-guards`.

## Mutation operators (one documented rule each)

| id | rule |
|---|---|
| `relational` | `<`<->`<=`, `>`<->`>=`, `==`<->`!=` on a binary expression |
| `int-literal` | a decimal integer literal that is a direct operand of a comparison (parentheses looked through; not under a unary minus; not hex, not double): +1 and -1 |
| `negate-condition` | the condition of an `if` / `while` / ternary becomes `!(cond)` (not `do-while`, `for`, collection `if`) |
| `logical` | `&&`<->`||` |
| `remove-return` | a `return ...;` that is a direct statement of an if-branch (then or else) is replaced by `;`, only when the outermost `if` has a following statement in its block |

Never mutated: comments, string literals (interpolations included), `import` /
`export` / `part` directives (conditional ones too), annotations. A mutant id is
`<file>:<UTF-8 byte offset>:<operator id>:<FNV-1a 32 of the replacement, 8 hex>`.
Order is byte offset, operator id, replacement text. `--max-mutants` keeps the first
N; `--sample N --seed S` draws N with a seeded PRNG of this package and keeps the
original order.

## Outcome classification

Precedence, first match wins:

1. run timed out -> `timeout`
2. a suite failed to load with a compiler diagnostic -> `compile-invalid` (nothing else in the run counts)
3. failed tests: ambiguous ones (known flaky, or no `error` event) are re-run alone once; a failure that passes alone is dropped. Confirmed failures that match a guard pattern are guard failures; any other confirmed failure -> `killed` (assertion or exception both count; the report says which); only guard failures -> `killed-by-guard-only`
4. a load error left (exception at load, missing file) -> `load-failure`
5. no `done` event, or a non-zero exit with nothing to blame -> `load-failure`
6. at least one non-skipped test passed -> `survived`; otherwise `skipped`

Score = killed / (killed + survived); everything else is outside the denominator.

## Safety

The audit runs in `git worktree add --detach` of the pinned sha under the system temp
directory, one mutant at a time; it refuses any target that is, contains or lies inside
the developer checkout, refuses a result directory inside the export, and refuses an active
path override (`pubspec_overrides.yaml`, `dependency_overrides` with `path:`, or `source: path`
in the lock) unless `--allow-override` names it. The baseline must pass first. Each mutant is
restored byte for byte and the restore is re-read. The export is removed on success, failure
and Ctrl-C.
