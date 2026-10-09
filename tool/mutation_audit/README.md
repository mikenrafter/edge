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
system temp directory. The audit logic is tested against a fake process runner that
answers from the file contents it sees, and the process runner against a fake host with
a virtual clock (no sleeps). Two files use real children, bounded by timeouts: `process_runner_real_test.dart` (small
shell scripts that ignore SIGTERM and hold the pipes) and `sigint_e2e_test.dart` (the real
tool, a real SIGINT / SIGTERM, a throwaway repo; Linux only). Neither starts `flutter test`.

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
/ `dart pub get`; `""` skips it). Exit codes: 0 ran, 64 usage (including a whole-suite audit
whose source guards are not classified), 65 baseline failed or path override refused, 70
export/internal error, 130 interrupted (SIGINT or SIGTERM).

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
| `int-literal` | a decimal integer literal that is a direct operand of a comparison (parentheses looked through; not under a unary minus; not hex, not double): +1 and -1; a replacement outside the signed 64-bit range (+1 on 9223372036854775807) is not produced |
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
3. failed tests: ambiguous ones (known flaky, or no `error` event) are re-run alone once (below).
   Confirmed failures that match a guard pattern are guard failures; any other confirmed failure
   -> `killed` (assertion or exception both count; the report says which for each killing test).
   Otherwise, a failure that could not be confirmed -> `unconfirmed`; otherwise only guard
   failures -> `killed-by-guard-only`
4. a load error left (exception at load, missing file), or a failed `setUpAll` / `tearDownAll`
   hook -> `load-failure`. A hook is never a test and never a kill: when `setUpAll` fails the
   tests of its group do not run at all (checked against a real run, fixture `real_setup_all.jsonl`)
5. no `done` event, or a non-zero exit with nothing to blame -> `load-failure`
6. at least one non-skipped test passed -> `survived`; otherwise `skipped`

Score = killed / (killed + survived); everything else is outside the denominator.

### Reruns (the rule that keeps a non-kill from being counted as a kill)

A failed test that is known flaky (`--flaky-test`) or has no error event is re-run alone, with
the mutant still applied: only that suite file, selected by its whole name (`--name '^<escaped
name>$'`, not a substring; any suite or name selector inside `--test-cmd` is dropped for the
rerun). The rerun's whole outcome is kept and interpreted:

| the rerun | result |
|---|---|
| the test ran and failed again, with an error event | `failed-again`: the failure is confirmed |
| the test ran and passed, in a complete run (output read to the end, successful `done`) | `passed-alone`: flaky, dropped |
| it timed out or was cancelled; did not compile; the suite did not load; a hook failed; the test did not run or was skipped; the output is incomplete; it failed without an error event | `unresolved`, with the reason |

A kill needs a repeated, attributable failure of that very test. An `unresolved` failure makes the
mutant `unconfirmed` (reported with the reason in the `Unconfirmed` section, outside the score)
unless another test was confirmed, in which case the confirmed kill stands. With no rerun possible
the failure is `unresolved` too.

## Timeouts and cancellation

`--timeout` bounds each run (setup, baseline, mutant, rerun) until the process has exited
AND its stdout/stderr have closed: a wrapper that exits early while a child keeps the pipes open
still times out. The child is started under `setsid` when the system has it (Linux), so it leads a
session of its own; on a timeout the runner

1. collects the family first: the child, its descendants, and every process of its session (this
   finds children that were reparented), scanning `/proc` (or `ps` where there is none);
2. sends SIGTERM to each of them by pid (never a process group, never a name match, never init);
3. waits up to 5 s, polling for exits, then sends a real SIGKILL to survivors, rescanning a few
   times for processes forked meanwhile;
4. waits at most 2 s for the output streams to close, then stops reading and reports
   `outputComplete: false` instead of hanging.

The end-to-end signal test starts the tool as `dart bin/mutation_audit.dart`; run it that way (or
from a compiled executable) when the signal has to reach the tool itself.

Without `setsid` (macOS) only descendants of the child can be found; a child that daemonised away
is out of reach.

SIGINT and SIGTERM are caught before the export is created. They cancel a token that is handed to the
audit loop and every child run: no further mutant is written, the active process tree is stopped as
above, the mutated file is restored and verified, and only then is the export removed (the signal
never abandons work that is still running in the export). No results are written for an interrupted
audit; the exit code is 130. Because the child is in its own session, the terminal's Ctrl-C reaches
the tool only; a `kill -9` of the tool itself cannot clean up and leaves the children running.

## Safety

The audit runs in `git worktree add --detach` of the pinned sha under the system temp
directory, one mutant at a time. The final export path is validated on every creation path
(an explicit export directory when the library is used that way, a parent directory, or TMPDIR): it must not be, contain or lie inside
the developer checkout or any other worktree of it (`git worktree list`), symlinks resolved; a
parent directory inside a checkout is refused before anything is created in it. The result
directory must be outside the export. The baseline must pass first. Each mutant is restored byte
for byte and the restore is re-read. The export is removed on success, failure, Ctrl-C and SIGTERM.

### Dependency configuration and path overrides

A path override is refused: entries of `pubspec_overrides.yaml`, `dependency_overrides` with
`path:` in `pubspec.yaml`, and `source: path` packages in `pubspec.lock` (a git package's
`description.path` is not one). The check runs on the pinned commit before setup, and again after the
setup command, because setup can create or rewrite the lock, the overrides file and the package config.

`--allow-override <path>` names the audited sibling (absolute, or relative to the developer
checkout). An override is allowed only when it points at that sibling: a relative override is
resolved against the EXPORT, which is where Pub reads it (so `../analytics` in an export under
`/tmp` is `/tmp/analytics`, not the developer's sibling, and is refused), then both sides are
canonicalised (`..`, `.`, trailing slash, symlinks) and compared. The usual way to audit with a
sibling override is therefore an absolute path in the override and the same path in
`--allow-override`.

For every allowed override the report records where it resolved, the sibling's git HEAD sha and
whether its working tree is dirty (untracked files count); `null` when it is not the top level of a
git repository. The report's `dependencies` is the configuration AFTER setup (lock hash, git pins with
resolved refs, `.dart_tool/package_config.json` hash, overrides); `dependenciesBeforeSetup` is what the
pinned commit carried.

## Report

`results.json`: `meta` (tool version, repo, sha, `dependencies`, `dependenciesBeforeSetup`, command,
`env`, `files`, `tests`, `guardPatterns`, `guardPolicy`, timeout, limits, `baseline`, times), `counts`
(every status, zero included), `score`, and `mutants`: per mutant id, file, line, column, operator,
original and mutated text, `status`, `killingTests` (keys), `killers` (`test`, `kind`: `assertion` or
`exception`), `guardTests`, `reruns` (`test`, `confirmed`, `result`: `failed-again` | `passed-alone` |
`unresolved`, `detail`), `durationMs`, `detail`. `summary.md` has the same, with sections for Killed
(each killing test with its kind), Survivors, Killed by guards only, Compile-invalid, Timeouts, Load
failures, Unconfirmed, and a per-file table.

Statuses: `killed`, `killed-by-guard-only`, `survived`, `compile-invalid`, `timeout`, `load-failure`,
`skipped`, `unconfirmed`.
