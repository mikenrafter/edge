import 'dart:async';
import 'dart:io';

import 'audit_runner.dart';
import 'applier.dart';
import 'command.dart';
import 'config.dart';
import 'export.dart';
import 'generator.dart';
import 'mutant.dart';
import 'process_runner.dart';
import 'report.dart';
import 'selection.dart';

const _toolVersion = '0.1.0';

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
/// no results are written.
Future<int> runCli(
  List<String> args, {
  ProcessRunner? runner,
  StringSink? out,
  StringSink? err,
  DateTime Function()? now,
  Stream<ProcessSignal>? interrupts,
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
  try {
    return await withDisposableExport<int>(
      repo: config.repo,
      sha: config.sha,
      interrupts: interrupts ?? _signals(),
      body: (export, cancel) async {
        final startedAt = clock();
        // Preflight: refuse a pinned commit that already carries an override.
        final before = await resolveDependencyConfig(export.path,
            repo: export.repo, allowedOverrides: config.allowOverrides);

        final setup = config.setupCmd ?? defaultSetupCommand(export.path);
        if (setup.isNotEmpty) {
          final done = await processes.run(splitCommand(setup),
              workingDirectory: export.path, environment: config.env, cancel: cancel);
          if (done.cancelled || cancel.isCancelled) throw InterruptedError();
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
        for (final file in expandFileGlobs(export.path, config.files)) {
          final source = File('${export.path}/$file').readAsStringSync();
          candidates.addAll(generateMutants(source, file: file));
        }
        final selected = selectMutants(candidates,
            maxMutants: config.maxMutants, sample: config.sample, seed: config.seed);

        final run = await AuditRunner(runner: processes)
            .run(config: config, root: export.path, mutants: selected, cancel: cancel);
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
        final written = await writeResults(results, outDir: config.outDir, exportPath: export.path);
        sink
          ..writeln('mutation audit of ${export.sha}: ${results.results.length} of '
              '${candidates.length} mutants run')
          ..writeln(results.counts.entries.map((e) => '${e.key}=${e.value}').join(' '))
          ..writeln(written.markdown);
        return 0;
      },
    );
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
