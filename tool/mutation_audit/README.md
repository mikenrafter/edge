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
tool, a real SIGINT / SIGTERM, a throwaway repo; Linux only). Four more use real bubblewrap
(`sandbox_real_test.dart`: a fake test command writes everywhere a run can write and the next run
must see none of it, the root holds only what was bound, and a host pathname Unix socket (server in the
test process, with a control showing it is reachable unsandboxed) cannot be connected to, written or read; `sandbox_flutter_test.dart`: one real `flutter test` of a one-file package inside
the sandbox, skipped with the reason when `flutter` or `bwrap` is missing or the package cannot be
resolved offline; the sandboxed variants of `sigint_e2e_test.dart`; the control that shows the same
script leaks without the sandbox). They skip, naming the reason, where bubblewrap cannot run.

## Command line

```
dart run mutation_audit --repo <path> --sha <rev> --files <glob>... \
  [--test-cmd "<cmd>"] [--tests <file>...] [--max-mutants N] [--sample N --seed S] \
  [--timeout seconds] [--guard-pattern <glob>...] [--scanner <glob>...] \
  [--runtime-allowlist <file>] [--no-guards] [--allow-override <path>...] \
  [--flaky-test <suite::name>...] [--setup-cmd "<cmd>"] [--setup-leaves <glob>...] \
  [--no-sandbox] [--sandbox-ro <path>...] --out <dir>
```

`--test-cmd` defaults to `flutter test --no-pub --reporter json` for a Flutter package and
`dart test --reporter json` otherwise (`--reporter json` is added when missing).
`--setup-cmd` runs once in the export before the baseline (default: `flutter pub get`
/ `dart pub get`; `""` skips it); it runs OUTSIDE the sandbox, because it needs the network.
Everything after it runs inside (see "Isolation"). `--no-pub` is in the default Flutter command because
Flutter may start an implicit `pub get` on its own, which can only fail or re-resolve in a sandbox with
no network; put it in a custom `--test-cmd` too. Exit codes: 0 ran, 64 usage (including `--no-guards` on
an export that has source-scanning suites), 65 baseline failed or path override refused, 70
export/internal error (also: no usable bubblewrap, the export left the pinned commit, a sandboxed run
changed the host export), 130 interrupted (SIGINT or SIGTERM).

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

(or put `nix develop <repo> -c` inside `--test-cmd` and `--setup-cmd`). The tests run in
bubblewrap (`bwrap` on `PATH`; both repo flakes put it there). A fresh export has no
package config: the setup command (`flutter pub get` / `dart pub get`) runs in it first.
Results go to `--out`, which must be outside the export.

## Source guards: found in the export, never counted as kills

A source guard is a test that reads source text (`File('lib/...').readAsStringSync()`, the
`test/support/dart_source*.dart` scanners) instead of running code. When a mutant makes one fail,
that is not runtime coverage. Whoever picks the tests (`--tests test` is the whole suite; a file
list can mix runtime and scanning suites) the tool decides for itself, from the pinned export, which
suites are source-scanning, and their failures are never kills: they are reported as
`killed-by-guard-only` (or as `discounted` next to the real killers of a killed mutant), with the
reasons.

The effective suite set is resolved first: `--tests` entries (files, directories, globs; none means
`test`) are expanded to `*_test.dart` files in the export; an entry that names nothing is an error.

A suite is source-scanning when any of these holds:

a. it matches a `--guard-pattern` (additional globs; the file-name patterns below are a good
   start for edge);
b. it imports a shared source scanner, directly or through any chain of files in the export:
   `**/dart_source*.dart` by default (edge: `test/support/dart_source.dart`,
   `test/support/dart_source_lexical.dart`), plus `--scanner <glob>...`. The import graph is read
   from the AST, not from text: EVERY URI of every `import` / `export` / `part` is followed,
   including all URIs of conditional directives (`import 'a.dart' if (dart.library.io) 'b.dart';`
   follows `a.dart` and `b.dart`) and any number of directives on one line. Relative URIs,
   `package:<the audited package>/x.dart` (resolved to `lib/x.dart`) and `package:<p>/x.dart` of a
   path dependency that lies inside the export (read from `pubspec.yaml` and
   `pubspec_overrides.yaml`) are resolved; hosted, git and outside-the-export packages and `dart:`
   are not part of the repository. Files under `lib/`, `tool/` and the other source roots are
   followed too: where a file lives never proves what it does;
c. it, or a helper it imports, may read source text. Each reachable Dart file is parsed to an AST
   (`package:analyzer`) and every one of these is a site (reported as `file:line [rule] code`):

   - `[path-not-literal]` a `File(...)`, `Directory(...)` or `Link(...)` (also `new`, `io.File`,
     `.fromUri`, `File.new` tear-offs, a `typedef` of them) whose path is not a compile-time string:
     a variable that is not a `final`/`const` declared once with a resolvable initializer, a
     parameter, a call, `Directory.current.path`, an interpolation of any of those. Strings,
     interpolation, `+`, adjacent strings, such constants and `package:path` `join` are resolved;
     nothing else is;
   - `[source-path]` a path that resolves under a source root (`lib`, `tool`, `packages`, `bin` and the
     top-level directory of every mutated file), after normalisation (`test/../lib/a` is `lib/a`),
     absolute paths included (any segment); the package root itself (`.`, `..`, `/`); any string
     literal that starts at a root (`lib/...`, `../lib/...`, `${x}/lib/...`); a `join` that starts at one;
   - `[read-call]` `readAsString*`, `readAsBytes*`, `readAsLines*`, `openRead`, `list`, `listSync` on a
     receiver that is not itself a `File`/`Directory`/`Link` construction (or a `final` variable
     initialised with one): its path is unknown;
   - `[Platform.script]` `Platform.script`, `Platform.packageConfig`, `Isolate.resolvePackageUri`,
     `Isolate.packageConfig`;
   - `[process-launch]` `Process.run`, `Process.runSync`, `Process.start` (also `io.Process.run`, an
     alias, a tear-off): a subprocess (`grep`, `cat`, `git`) reads whatever it is told to, and its
     arguments are not followed;
   - `[cwd]` `Directory.current`, `Uri.base`: the bases of paths built at run time;
   - `[unresolved-import]` an `import` / `export` / `part` (any URI of a conditional one) that names a
     file the export does not have: a relative URI, `package:<the audited package>/...`, a path
     dependency or a package the package config places inside the export. The file could be a scanner, so
     "not there" is evidence, not a clean pass. A relative URI that leaves the export counts too. `dart:`,
     hosted and git packages and packages outside the export are not part of the repository and are
     ignored;
   - `[package-mapping]` an import of a `package:` the detector cannot map to a directory. Which
     directory `package:demo/h.dart` runs is decided by the resolved `.dart_tool/package_config.json`
     (`rootUri` + `packageUri`, e.g. `src/` instead of `lib/`), which setup writes and the compiler uses;
     it is AUTHORITATIVE and overrides whatever the pubspec suggests. The pubspecs only say which
     packages are expected to be in the export (the audited package, path dependencies inside it). If the
     config is missing, is not JSON, does not list such a package, lists it twice with different roots, or
     gives a root that is not a file location, importing that package is scanning evidence: there is no
     way to tell what code runs. Packages the config places outside the export, and packages nothing says
     are ours (hosted, git), are not part of the repository and are ignored;
   - `[unparsable]` a file with syntax errors.

   The detection runs AFTER setup, on the prepared tree: setup (`pub get`, code generation) may create
   helpers the pinned commit does not contain, and a generated scanner is found as any other. The
   package config (`.dart_tool/package_config.json`) is read as well (below), so a package that setup
   placed inside the export is followed. Consequence: `--no-guards` is judged after setup (a refusal is exit 64
   after the setup command has run).

   The rules apply STRICTLY to every file reached, files under `lib/`, `tool/` and the other source
   roots included: a helper there that builds a path at run time may read source whatever its callers
   show (`File(['lib','a.dart'].join('/'))` behind a zero-argument call). The price is that a test
   that reaches the app's data layer (which reads files at run time) is flagged; runtime credit for
   such suites comes only from the reviewed allowlist below.

A suite file that is not in the export cannot be checked and counts as source-scanning. The rules are
wide on purpose: a runtime suite wrongly taken for a scanner only loses kill credit, a scanner
taken for runtime would inflate the score.

### The reviewed runtime allowlist

`--runtime-allowlist <file>` lists tests that really run code although the detector (or a pattern)
flags their suite. One entry per line, and EVERY entry needs a reason after `#`; `#` at the start of a
line is a comment; blank lines are ignored:

```
# reviewed 2026-10-09
test/ecg_tap_runtime_test.dart::ecg tap runtime starts the session  # pumps the widget; the grep below is another test
test/some_runtime_test.dart  # reaches db.dart, which reads its database file; reads no source
```

`suite  # reason` frees every test of that suite; `suite::full test name  # reason` frees that test
only (the rest of the suite stays a guard). The reason starts at the first whitespace-`#`-whitespace
(a `#` inside a test name such as `issue #12` is fine). A line without a reason is a usage error
(exit 64, before anything is exported). Matching is exact (no globs, no prefixes) and also overrides
`--guard-pattern`.

Review workflow: run once, read `meta.guards.allowlist.overrides` in `results.json` (and the
"Allowlist overrides" lines of `summary.md`): each override lists the entry, your reason and the flag
reasons the detector gave (file:line and rule), so you see exactly what you are overriding. Entries
whose suite nothing flagged are listed under `unflagged` (they free nothing), entries naming a suite
that is not in the export under `unknownSuites`. The report also records the file's path and sha256
and the number of entries.

### `--no-guards`

An assertion for repositories without source scanners (`openstrap-analytics` reads only data
fixtures). It is checked: if the detector finds any source-scanning suite the tool exits 64 and
names some. It cannot be combined with `--guard-pattern` or `--runtime-allowlist`.

The report (`meta.guards`, Markdown "Source-scanning suites") has the policy (`detected` or
`no-guards-asserted`), patterns, scanner globs, source roots, how many suites are covered and how many
are source-scanning (the list with reasons is in `results.json`), and the allowlist.

File-name patterns for `--guard-pattern` that match edge's guard tests by convention
(`<!-- guard-patterns:edge -->` is read by a test that checks these globs against real file names):

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
3. failed tests: a test that failed by the test framework's own timeout is set aside first (below).
   Ambiguous ones (known flaky, or no `error` event) are re-run alone once (below).
   Confirmed failures that match a guard pattern are guard failures; any other confirmed failure
   -> `killed` (assertion or exception both count; the report says which for each killing test).
   Otherwise, a failure that could not be confirmed -> `unconfirmed`; otherwise only guard
   failures -> `killed-by-guard-only`; otherwise, if every remaining failure is a framework timeout
   -> `timeout`
4. a load error left (exception at load, missing file), or a failed `setUpAll` / `tearDownAll`
   hook -> `load-failure`. A hook is never a test and never a kill: when `setUpAll` fails the
   tests of its group do not run at all (checked against a real run, fixture `real_setup_all.jsonl`)
5. no `done` event, or a non-zero exit with nothing to blame -> `load-failure`
6. at least one non-skipped test passed -> `survived`; otherwise `skipped`

Score = killed / (killed + survived); everything else is outside the denominator.

### Framework timeouts are evidence of a hang, never a kill

`package:test` (and `flutter_test`, which runs on it) fails a test that outlives its `Timeout`
with an error event `TimeoutException after 0:00:30.000000: Test timed out after 30 seconds.` and a
failed result (`test_api` `Invoker.heartbeat`; real output in `test/fixtures/real_timeout.jsonl`). The
tool recognises that message exactly (`TestError.isFrameworkTimeout`: `TimeoutException after
<h:mm:ss[.f]>: Test timed out after <n> <unit>`), in the mutant run and in reruns:

- such a test is not a kill and is not re-run; it is listed in `frameworkTimeouts` of the mutant
  (results.json) and in the summary as "timed out by the test framework (not a kill)";
- a rerun in which the test fails that way is `unresolved` (it does not confirm anything);
- if nothing else is left (no kill, no unconfirmed failure, no guard failure), the mutant is
  `timeout`; next to a real kill the kill stands;
- a `TimeoutException` the test's own code throws (`Future not completed`, from `Future.timeout`) has a
  different message and is an ordinary exception failure.

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

With the sandbox (the default) the child that is started, timed and stopped is the `bwrap` process: its
descendants are visible from the host's `/proc`, so everything below applies to the whole tree in the
sandbox, and the sandbox's own PID namespace removes whatever is left when its init exits (see
"Isolation"). On a timeout or a cancel the bubblewrap process and its family are stopped as described, and
a captured process that survives the last SIGKILL still ends the audit (exit 70).

`--timeout` bounds each run (setup, baseline, mutant, rerun) until the process has exited
AND its stdout/stderr have closed: a wrapper that exits early while a child keeps the pipes open
still times out. The child is started under `setsid` when the system has it (Linux), so it leads a
session of its own; on a timeout the runner

1. works from a captured family, by process identity (pid AND start time, from
   `/proc/<pid>/stat` field 22; `ps -o lstart` where there is no `/proc`). The family is sampled
   once a second while the child runs, once more the moment the child exits (its session is read
   then, while the kernel still holds its number), and at the start of cleanup. A captured process is
   never forgotten while it lives (members are keyed by pid AND start time, so a genuine descendant that
   was handed the pid of a captured process that exited is a new member, not a refused signal to an old one): every rescan is the captured set that is still alive plus the
   descendants of any such member, so a child reparented to init (or in a session of its own) when its
   parent dies on SIGTERM is still found.

   Every adoption is anchored. A process joins the family only as the child of a member (or, for a
   session scan, of the child's session) and only if (a) that anchor's start time is read AGAIN after
   the whole process-table walk and is still the one captured, (b) the candidate's start time is not
   earlier than the anchor's, and (c) the candidate's own identity re-reads the same. A `/proc` walk is
   not atomic (an old parent entry can sit beside a child of the process that took its pid), and the
   checks above reject that mix. The child's session is scanned only while the child is alive, and
   once right after its exit, and then only if no other process holds the child's pid by then (a
   newcomer that started a session would own a session of the same number);
2. sends SIGTERM to each member (never a process group, never a name match, never init);
3. waits up to 5 s, polling, then sends a real SIGKILL to survivors, rescanning first;
4. before every signal re-reads the target's start time and skips it if it changed: a pid that was
   handed out again is another process and is never signalled. (Between that read and the kill there
   remains a window of microseconds that no portable API closes.);
5. waits at most 2 s for the output streams to close, then stops reading and reports
   `outputComplete: false` instead of hanging.

The same cleanup runs on EVERY path, a normal finish included: after the child has exited and its
output has closed, any captured process that is still alive (a helper that redirected its output and
kept running, a server) is stopped (SIGTERM, grace, SIGKILL, identity-checked) before `run()` returns,
so one mutant's run cannot affect the next. The outcome records how many processes other than the
child that were stopped (`lingeringStopped`, 0 for a clean run; it counts on timeout and cancel too). It
counts CONFIRMED EXITS, not signals sent.

If a captured process is still alive after the last SIGKILL round (uninterruptible sleep, a process
nothing can remove), the outcome lists it in `survivors` (`cleanupFailed`) and the audit does not go
on: a later run could not be told apart from that process. The audit stops with exit 70, naming the
survivors, the mutated file is restored first, and no results are published. The same applies to the
setup command, the baseline, mutant runs and confirming reruns.

The end-to-end signal test starts the tool as `dart bin/mutation_audit.dart`; run it that way (or
from a compiled executable) when the signal has to reach the tool itself.

Weaker guarantees: without `setsid` (macOS) there is no session of its own, so only processes seen as
descendants in a sample (or at cleanup) are found: a child forked and reparented between two samples,
or one that daemonised away, is out of reach. Where `/proc` is missing, `ps -o lstart` has a
resolution of one second, so a pid reused by a process started within the same second as the
captured one is not told apart, and `ps` gives no session ids.

SIGINT and SIGTERM are caught before the export is created. They cancel a token that is handed to the
audit loop and every child run: no further mutant is written, the active process tree is stopped as
above, the mutated file is restored and verified, and only then is the export removed (the signal
never abandons work that is still running in the export). No results are published for an interrupted
audit, and publication comes last: while the audit runs the two result files are staged as
`results.json.tmp` and `summary.md.tmp` inside `--out`; they are renamed into place only after the
export has been removed successfully and no signal has arrived, so a signal anywhere (the removal of
the export included) is exit 130 with the staged files deleted and any earlier `results.json` /
`summary.md` pair left exactly as it was. A removal that fails (exit 70) publishes nothing either.
The signal handlers stay installed until the export is gone; the instant between that and the
rename (two synchronous renames) has no handler, and a signal in it kills the tool and leaves the
`*.tmp` files (a hard kill between the two renames could leave one new file). Because the child is in its own session, the terminal's Ctrl-C reaches
the tool only; a `kill -9` of the tool itself cannot clean up and leaves the children running.

## Safety

The audit runs in `git worktree add --detach` of the pinned sha under the system temp
directory, one mutant at a time. The final export path is validated on every creation path
(an explicit export directory when the library is used that way, a parent directory, or TMPDIR): it must not be, contain or lie inside
the developer checkout or any other worktree of it (`git worktree list`), symlinks resolved; a
parent directory inside a checkout is refused before anything is created in it. The result
directory must be outside the export. The baseline must pass first. Each mutant is restored byte
for byte and the restore is re-read. The export is removed on success, failure, Ctrl-C and SIGTERM.

### Isolation: every test run in its own bubblewrap sandbox

All runs of an audit (the baseline, every mutant, every confirming rerun) share one export, so what a
test run leaves behind could reach the next run and turn a non-kill into a kill or the reverse (a
SQLite file in `build/`, a marker under `$HOME` or `/tmp`, a socket, a process). Putting files back
afterwards cannot find all of that, so the runs cannot write to it in the first place: setup runs
unsandboxed (it needs the network), then the mutant is applied on the host and the test command is
launched as

```
bwrap --dev /dev --proc /proc --unshare-pid --unshare-ipc --unshare-net --die-with-parent --new-session \
      --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --tmpfs /dev/shm --tmpfs $HOME \
      --ro-bind <bind> <bind>...   --symlink <target> <link>... \
      --overlay-src <export> --tmp-overlay <export> --remount-ro / \
      --setenv HOME $HOME --setenv XDG_{CACHE,CONFIG,DATA,STATE,RUNTIME}_HOME /tmp/xdg/... --setenv TMPDIR /tmp ... \
      --chdir <export> -- <test command>
```

- **The root is a minimal read-only tmpfs; the host is NOT bound.** An earlier version used
  `--ro-bind / /`, but a read-only mount does not stop `connect(2)`: every pathname Unix socket on the
  host stayed reachable, so one run could change a host service's state and a later run observe it
  (and `Socket.connect` needs no process launch for that). Now the run sees only the binds below, plus
  the export. Everything else (the developer checkout, the out directory, `/var`, `/home`, `/nix/var`
  where the Nix daemon socket lives, `/run`, other users' files) does not exist in the sandbox.
- **The bind list** is found by `Sandbox.discover` from the machine and is recorded in
  `meta.isolation.binds` (read-only binds at the same path) and `meta.isolation.symlinks`:
  - the base system: `/nix/store` (not `/nix`), `/usr`, `/bin`, `/sbin`, `/lib`, `/lib32`, `/lib64`,
    `/libx32` when they exist; a directory is bound, a link (a merged `/bin`) is recreated as a link;
  - from `/etc` only `passwd`, `group`, `nsswitch.conf`, `hosts`, `localtime`, `os-release`,
    `ld.so.cache`, `ld.so.conf`, `ld.so.conf.d`;
  - the toolchain: the pub cache (`PUB_CACHE`, else `~/.pub-cache`), `FLUTTER_ROOT`, every `PATH` entry
    (resolved; an entry that is only a link into something bound, like `/run/current-system/sw/bin`
    into the store, is recreated as a link; entries in `/run`, `/proc`, `/sys`, `/dev`, relative ones and
    missing ones are skipped), the SDK around the program of the test command when it is outside the
    store (the directory above its `bin/`), the package roots `.dart_tool/package_config.json` names
    outside the export, and the sibling paths of allowed overrides. Add more with `--sandbox-ro <path>`
    (any location now, not only under `$HOME`). `$HOME` itself and `/` are never bound.
  - On the machine this was developed on (NixOS, `nix develop`) that is: `/bin`, `/lib64`, `/usr`,
    `/etc/group`, `/etc/hosts`, `/etc/localtime`, `/etc/nsswitch.conf`, `/etc/os-release`, `/etc/passwd`,
    `/nix/store`, `~/.pub-cache`, `~/.local/share/flatpak/exports/bin` (a `PATH` entry), and four links
    for the profile `PATH` entries (`/run/current-system/sw/bin`, `/etc/profiles/per-user/<u>/bin`,
    `~/.nix-profile/bin`, `/nix/var/nix/profiles/per-user/<u>/.../bin`).
  - Consequence: `--test-cmd "nix develop ... -c ..."` cannot work inside (no Nix daemon); start the tool
    from the development shell instead, as described above. Git commands in the export fail too (the
    worktree's gitdir is in the developer checkout, which is not there).
- **The export is an overlay.** The run sees the export with the current mutant applied; every write it
  makes (tracked, untracked or ignored files, `build/`, `.dart_tool/`, empty directories) goes to memory
  and is discarded when the sandbox ends. The caches that used to be excluded from the restore are no
  longer a channel: they are rebuilt from the export every time. The root itself is remounted read-only
  (`--remount-ro /`), so nothing can be created outside the export and the tmpfs mounts.
- **`/tmp`, `/var/tmp`, `/run`, `/dev/shm` and `$HOME` are empty tmpfs mounts**, `--unshare-ipc` hides the
  host's SysV IPC, and `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_RUNTIME_DIR` point into `/tmp/xdg`, `TMPDIR`/`TMP`/`TEMP` to `/tmp`. A fixed absolute path
  (`/tmp/shared-marker`) or `~/.config/x` is written into a fresh tmpfs.
  `FLUTTER_SUPPRESS_ANALYTICS` and `DART_SUPPRESS_ANALYTICS` are set (a fresh `$HOME` would make Flutter
  print its first-run banner into the JSON stream).
- **Own PID namespace** (`--unshare-pid`, `--die-with-parent`): when the sandbox's init exits the kernel
  kills every process left in it, a TERM-ignoring grandchild that let go of the pipes included. That is
  the primary cleanup; the identity-based cleanup of "Timeouts and cancellation" below runs unchanged on
  the bubblewrap process and what it can see below it, as defence in depth, and a survivor still ends the
  audit.
- **New IPC and network namespaces** (`--unshare-net`): no network, and the host's loopback services are
  not reachable. `flutter_tester` talks to the VM service over the namespace's own loopback, which works
  (checked by a real `flutter test`).
- `--new-session` stops a test from injecting input into the terminal.

What `flutter test` needed, measured with a one-file Flutter package on a nix machine: the base system
and `/nix/store` (the Flutter SDK lives there, readable, and its cache is not written), the `PATH`
entries, and the pub cache (without it the test fails to compile: "Error when reading
'/home/dev/.pub-cache/hosted/pub.dev/test_api-.../lib/backend.dart'"). Not needed: `/etc` beyond the
few files above, `/sys`, `/var`, `$HOME` content (`~/.config/flutter`, `~/.dart-tool` are fresh and Flutter
recreates what it wants in them).

**Before anything is exported** the tool runs a probe sandbox: `bwrap --version`, then a real sandbox
that writes to its export, to `/tmp` and to `$HOME` and checks that none of it arrived on the host, then
the program of the test command inside the minimal root: `flutter --version` / `dart --version` must
succeed (any other program must at least be found). If bubblewrap is missing, the probe fails or the
program does not run in the minimal root the audit stops with exit 70 and says why (for the last case:
what to put on `PATH`, in `FLUTTER_ROOT` or in `--sandbox-ro`). `--no-sandbox` is the
explicit way out: the tests then run directly, `meta.isolation.mode` is `none`, every mutant has
`unisolated: true` in `results.json`, the summary says `Isolation: NONE` and tags every kill `unisolated`
(something an earlier run left could have caused the failure), and each run gets its own `TMPDIR`
(`TMP`, `TEMP`) in a directory deleted afterwards, the one thing that can be done cheaply without a
sandbox. The score is still computed; read it knowing that.

**The sandbox is checked from the host.** The per-run restore of earlier versions is gone, but a cheap
tripwire stays: before each run the tool takes a view of the export (HEAD, `git status
--porcelain --untracked-files=all --ignored`, the size and modification time of the ignored entries git
lists, the modification time of the root and of the directories directly in it, which also shows an empty
directory git cannot see, and the hash of the mutated file) and compares it after the run. Any difference
means the sandbox did not hold: exit 70, naming the difference and the run (`the run of mutant <id>`,
`the rerun of <test>`, `the baseline run`); the mutated file is restored first and no results are
published. A write deeper inside an ignored directory that does not move the modification time of
anything directly under the root is out of this check's sight (the overlay is what keeps it out of the
host).

**HEAD is pinned.** `--sha` is resolved once; the export's HEAD must be that commit before setup, after
setup, after the baseline and after EVERY run (also with `--no-sandbox`). A setup command or a test that
checks out or commits something else stops the audit with exit 70 naming both commits. After setup the
export must also be clean (`git status` empty apart from `.dart_tool`, `build`, `.flutter-plugins*`,
`.packages` and whatever `--setup-leaves <glob>` declares, e.g. `pubspec.lock` in a project that does
not commit it), otherwise exit 70 naming the files: every run starts from the pinned commit plus one
mutant.

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

`results.json`: `meta` (tool version, repo, sha, `isolation` (`mode`: `bubblewrap` | `none`, `network`, `binds`, `symlinks`, `bwrap`), `dependencies`, `dependenciesBeforeSetup`, command,
`env`, `files`, `tests`, `guardPatterns`, `guardPolicy`, `guards`, timeout, limits, `baseline`, times), `counts`
(every status, zero included), `score`, and `mutants`: per mutant id, file, line, column, operator,
original and mutated text, `status`, `killingTests` (keys), `killers` (`test`, `kind`: `assertion` or
`exception` in the mutant run, `confirmedKind`: the same for the confirming rerun, null if none),
`guardTests` (keys), `discounted` (`test`, `reasons`: failures not counted as kills and why), `reruns`
(`test`, `confirmed`, `result`: `failed-again` | `passed-alone` | `unresolved`, `kind`: how the rerun
failed, `detail`), `unisolated` (true for every mutant of a `--no-sandbox` audit), `durationMs`, `detail`. `summary.md` has the same, with sections for Killed
(each killing test with its kind), Survivors, Killed by guards only, Compile-invalid, Timeouts, Load
failures, Unconfirmed, and a per-file table.

Statuses: `killed`, `killed-by-guard-only`, `survived`, `compile-invalid`, `timeout`, `load-failure`,
`skipped`, `unconfirmed`.
