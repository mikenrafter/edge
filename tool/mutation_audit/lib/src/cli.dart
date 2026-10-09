import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'audit_runner.dart';
import 'applier.dart';
import 'classifier.dart' show GuardMatcher;
import 'command.dart';
import 'config.dart';
import 'export.dart';
import 'generator.dart';
import 'guards.dart';
import 'mutant.dart';
import 'process_runner.dart';
import 'report.dart';
import 'selection.dart';
import 'source_facts.dart' show defaultSourceRoots;

const _toolVersion = '0.1.0';

/// `--no-guards` while the export has source-scanning suites.
class GuardPolicyError implements Exception {
  GuardPolicyError(this.message);
  final String message;
}

class _SetupFailed implements Exception {
  _SetupFailed(this.message);
  final String message;
}

/// Runs the whole tool: parse arguments, export the pinned commit, check the
/// dependency config, generate / select mutants, baseline, run, write the
/// results outside the export, dispose of the export. Returns the exit code:
/// 0 ran (whatever the mutants did), 64 usage error (usage on [err]), 65 the
/// baseline failed or a path override was refused, 70 internal / export error,
/// 130 interrupted (SIGINT or SIGTERM): the running tests were stopped and
/// reaped, the mutated file restored and the export removed, in that order;
/// no results are published (they are staged in the output directory and
/// renamed into place only after the export is gone and no signal arrived).
Future<int> runCli(
  List<String> args, {
  ProcessRunner? runner,
  StringSink? out,
  StringSink? err,
  DateTime Function()? now,
  Stream<ProcessSignal>? interrupts,
  Future<void> Function(DisposableExport export)? disposer,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final clock = now ?? DateTime.now;
  final AuditConfig config;
  try {
    config = parseAuditArgs(args);
  } on UsageError catch (e) {
    errSink
      ..writeln(e.message)
      ..writeln()
      ..writeln(auditUsage());
    return 64;
  }
  final processes = runner ?? const SystemProcessRunner();
  // Results are staged inside the output directory while the body runs and
  // published (renamed) only after the export has been removed and no signal
  // has arrived: a signal during removal must not leave fresh results next to
  // exit code 130.
  StagedResults? staged;
  String? summaryLine;
  try {
    final code = await withDisposableExport<int>(
      repo: config.repo,
      sha: config.sha,
      interrupts: interrupts ?? _signals(),
      disposer: disposer,
      body: (export, cancel) async {
        final startedAt = clock();
        // Preflight: refuse a pinned commit that already carries an override.
        final before = await resolveDependencyConfig(export.path,
            repo: export.repo, allowedOverrides: config.allowOverrides);

        // Source guards: found by reading the export, before anything runs.
        final files = expandFileGlobs(export.path, config.files);
        final suites = expandTestSelectors(export.path, config.tests);
        final sourceRoots = {...defaultSourceRoots, ...files.map((f) => f.split('/').first).where((d) => !d.endsWith('.dart'))}.toList();
        final scannerGlobs = [...defaultScannerGlobs, ...config.scanners];
        final detector =
            SourceScanDetector(root: export.path, sourceRoots: sourceRoots, scannerGlobs: scannerGlobs);
        final scanning = {
          for (final s in suites)
            if (detector.reasons(s).isNotEmpty) s: detector.reasons(s),
        };
        if (config.noGuards && scanning.isNotEmpty) {
          final shown = scanning.entries.take(5).map((e) => '  ${e.key}: ${e.value.first}').join('\n');
          throw GuardPolicyError('--no-guards is refused: ${scanning.length} of ${suites.length} suites '
              'scan source text, e.g.\n$shown\nTheir failures can never be kills. Drop --no-guards '
              '(they are detected automatically) and, for tests that really run code, list them in '
              '--runtime-allowlist.');
        }
        RuntimeAllowlist allowlist = const RuntimeAllowlist.empty();
        String? allowlistSha;
        if (config.runtimeAllowlist != null) {
          final bytes = File(config.runtimeAllowlist!).readAsBytesSync();
          allowlist = RuntimeAllowlist.parse(utf8.decode(bytes, allowMalformed: true));
          allowlistSha = sha256.convert(bytes).toString();
        }
        final guards = GuardMatcher(config.guardPatterns, detector: detector, allowlist: allowlist);

        final setup = config.setupCmd ?? defaultSetupCommand(export.path);
        if (setup.isNotEmpty) {
          final done = await processes.run(splitCommand(setup),
              workingDirectory: export.path,
              environment: config.env,
              timeout: config.timeout,
              cancel: cancel);
          if (done.cancelled || cancel.isCancelled) throw InterruptedError();
          if (done.timedOut) {
            throw _SetupFailed('"$setup" timed out after ${config.timeout.inSeconds} s and was stopped');
          }
          if (done.exitCode != 0) {
            throw _SetupFailed('"$setup" failed (exit code ${done.exitCode}): ${done.stderr.trim()}');
          }
        }
        // Setup may have created or rewritten the lock, the overrides file or
        // the package config: check again and record what is really in use.
        final deps = setup.isEmpty
            ? before
            : await resolveDependencyConfig(export.path,
                repo: export.repo, allowedOverrides: config.allowOverrides);

        final candidates = <Mutant>[];
        for (final file in files) {
          final source = File('${export.path}/$file').readAsStringSync();
          candidates.addAll(generateMutants(source, file: file));
        }
        final selected = selectMutants(candidates,
            maxMutants: config.maxMutants, sample: config.sample, seed: config.seed);

        final run = await AuditRunner(runner: processes)
            .run(config: config, root: export.path, mutants: selected, cancel: cancel, guards: guards);
        final results = AuditResults(
          AuditMeta(
            toolVersion: _toolVersion,
            repo: export.repo,
            sha: export.sha,
            dependencies: deps,
            dependenciesBeforeSetup: before,
            testCmd: config.testCmd,
            files: config.files,
            tests: config.tests,
            guardPatterns: config.guardPatterns,
            guardPolicy: config.guardPolicy,
            guards: GuardReport(
              policy: config.guardPolicy,
              patterns: config.guardPatterns,
              scannerGlobs: scannerGlobs,
              sourceRoots: sourceRoots,
              effectiveSuites: suites,
              sourceScanning: scanning,
              allowlistPath: config.runtimeAllowlist,
              allowlistSha256: allowlistSha,
              allowlistEntries: allowlist.length,
              allowlistUnknownSuites: [
                for (final s in allowlist.suiteNames)
                  if (!File('${export.path}/$s').existsSync()) s
              ]..sort(),
            ),
            timeoutSeconds: config.timeout.inSeconds,
            maxMutants: config.maxMutants,
            sample: config.sample,
            seed: config.seed,
            baseline: run.baseline,
            startedAt: startedAt,
            finishedAt: clock(),
            candidateMutants: candidates.length,
            env: config.env,
          ),
          run.results,
        );
        staged = await stageResults(results,
            outDir: config.outDir, exportPath: export.path, cancel: cancel);
        summaryLine = 'mutation audit of ${export.sha}: ${results.results.length} of '
            '${candidates.length} mutants run\n'
            '${results.counts.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
        return 0;
      },
    );
    // The export is gone and no signal arrived (withDisposableExport throws
    // InterruptedError otherwise): now the results become visible.
    final ready = staged;
    if (ready != null) {
      ready.publish();
      sink
        ..writeln(summaryLine)
        ..writeln(ready.markdown);
    }
    return code;
  } on GuardPolicyError catch (e) {
    errSink.writeln(e.message);
    return 64;
  } on PathOverrideRefused catch (e) {
    errSink.writeln(e.message);
    return 65;
  } on BaselineFailedError catch (e) {
    errSink.writeln(e.message);
    return 65;
  } on InterruptedError {
    errSink.writeln('interrupted; the export was removed');
    return 130;
  } on UnsafeExportTarget catch (e) {
    errSink.writeln(e.message);
    return 70;
  } on ExportFailed catch (e) {
    errSink.writeln(e.message);
    return 70;
  } on _SetupFailed catch (e) {
    errSink.writeln(e.message);
    return 70;
  } on RestoreFailedError catch (e) {
    errSink.writeln(e.message);
    return 70;
  } on StaleMutantError catch (e) {
    errSink.writeln(e.message);
    return 70;
  } on FormatException catch (e) {
    errSink.writeln('${e.message}: ${e.source}');
    return 70;
  } finally {
    staged?.discard();
  }
}

/// Ctrl-C and SIGTERM as one stream (a platform without one just lacks it).
/// Watching them replaces the default "die now", which is the point: the
/// export and the child processes are cleaned up first.
Stream<ProcessSignal> _signals() {
  final controller = StreamController<ProcessSignal>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  controller.onListen = () {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      try {
        subscriptions.add(signal.watch().listen(controller.add));
      } on SignalException {
        // not supported here
      }
    }
  };
  controller.onCancel = () => Future.wait(subscriptions.map((s) => s.cancel()));
  return controller.stream;
}
