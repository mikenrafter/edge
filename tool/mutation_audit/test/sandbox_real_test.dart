@TestOn('linux')
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// Real bubblewrap, bounded. A fake "test command" (a shell script) writes
/// everywhere a test run can write; the next run must see none of it, and the
/// host must be exactly as it was. Skipped, with the reason, where bubblewrap
/// cannot run (not installed, no unprivileged user namespaces).
String? _noBwrap() {
  try {
    final r = Process.runSync('bwrap', ['--ro-bind', '/', '/', '--unshare-pid', '--die-with-parent', 'true']);
    return r.exitCode == 0 ? null : 'bubblewrap cannot create a sandbox here: ${(r.stderr as String).trim()}';
  } on ProcessException {
    return 'bubblewrap (bwrap) is not installed';
  }
}

/// Every file and directory under [root] (git metadata excluded) with its
/// content hash: empty directories count.
Map<String, String> tree(String root) {
  final out = <String, String>{};
  for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: root);
    if (rel == '.git' || rel.startsWith('.git${p.separator}')) continue;
    out[rel] = e is File ? sha256.convert(e.readAsBytesSync()).toString() : (e is Link ? 'link' : 'dir');
  }
  return out;
}

void main() {
  final skip = _noBwrap();
  const runner = SystemProcessRunner(
      termGrace: Duration(milliseconds: 400), drainGrace: Duration(seconds: 1), pollEvery: Duration(milliseconds: 50));
  late GitFixture fx;
  late String root;
  // Host paths the fake test command tries to write; unique per test run.
  final id = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
  final sharedMarker = '/tmp/mutaudit_shared_marker_$id';
  final varTmpMarker = '/var/tmp/mutaudit_shared_marker_$id';
  final homeMarker = '${Platform.environment['HOME']}/.config/mutaudit_marker_$id';
  final xdgMarkerName = 'mutaudit_xdg_marker_$id';

  setUp(() async {
    fx = await GitFixture.create({
      '.gitignore': 'build/\n.dart_tool/\nignored.txt\nempty_ignored/\n',
      'lib/a.dart': 'bool lt(int a, int b) => a < b;\n',
      'build/seed.txt': 'seed', // ignored but present, like a build cache
    });
    root = fx.root;
    // `git add -A` honours .gitignore, so these two exist only on disk.
    Directory(p.join(root, 'build')).createSync();
    File(p.join(root, 'build/seed.txt')).writeAsStringSync('seed');
    Directory(p.join(root, '.dart_tool')).createSync();
    File(p.join(root, '.dart_tool/package_config.json')).writeAsStringSync('{"configVersion":2,"packages":[]}');
  });
  tearDown(() {
    fx.dispose();
    for (final f in [sharedMarker, varTmpMarker, homeMarker]) {
      if (File(f).existsSync()) File(f).deleteSync();
    }
  });

  ProcessRunner sandboxed() => SandboxedProcessRunner(runner, Sandbox.discover(root));

  Future<ProcessOutcome> sh(ProcessRunner r, String script, {Duration timeout = const Duration(seconds: 30)}) =>
      r.run(['sh', '-c', script], workingDirectory: root, timeout: timeout);

  /// Writes to every place a test run can reach.
  final writeEverywhere = '''
echo mutated > lib/a.dart
echo new > untracked.txt
echo ign > ignored.txt
echo db > build/x.sqlite
echo mark > .dart_tool/marker
echo changed > build/seed.txt
mkdir empty_ignored
mkdir -p brand/new/dir
echo s > $sharedMarker
echo v > $varTmpMarker
mkdir -p "\$HOME/.config" && echo h > "\$HOME/.config/mutaudit_marker_$id"
mkdir -p "\$XDG_CACHE_HOME" "\$XDG_CONFIG_HOME" "\$XDG_DATA_HOME"
echo c > "\$XDG_CACHE_HOME/$xdgMarkerName"
echo c > "\$XDG_CONFIG_HOME/$xdgMarkerName"
echo c > "\$XDG_DATA_HOME/$xdgMarkerName"
echo t > "\$TMPDIR/tmpdir_marker"
echo wrote
''';

  /// What a later run can see of the above.
  final lookEverywhere = '''
for f in untracked.txt ignored.txt build/x.sqlite .dart_tool/marker empty_ignored brand $sharedMarker $varTmpMarker \\
  "\$HOME/.config/mutaudit_marker_$id" "\$XDG_CACHE_HOME/$xdgMarkerName" "\$XDG_CONFIG_HOME/$xdgMarkerName" "\$XDG_DATA_HOME/$xdgMarkerName" \\
  "\$TMPDIR/tmpdir_marker"; do
  if [ -e "\$f" ]; then echo "SEEN \$f"; fi
done
echo "lib=\$(cat lib/a.dart)"
echo "seed=\$(cat build/seed.txt)"
echo looked
''';

  group('control: without the sandbox the same kind of script leaks (the checks below have teeth)', () {
    test('a plain run leaves state in the export and in /tmp that a next run sees', () async {
      final plain = SystemProcessRunner(termGrace: runner.termGrace, drainGrace: runner.drainGrace, pollEvery: runner.pollEvery);
      final before = tree(root);
      await sh(plain, 'echo x > untracked.txt; echo db > build/x.sqlite; echo s > $sharedMarker');
      final next = await sh(plain, 'ls untracked.txt build/x.sqlite $sharedMarker');
      expect(next.stdoutLines, hasLength(3), reason: 'a next run sees all three');
      expect(tree(root), isNot(before));
    });
  }, skip: skip);

  group('nothing a run writes survives it', () {
    test('tracked, untracked, ignored, cache and empty-directory writes are gone; the host tree is unchanged', () async {
      final before = tree(root);
      final status = await fx.git(['status', '--porcelain', '--ignored']);
      final first = await sh(sandboxed(), writeEverywhere);
      expect(first.stderr, isEmpty);
      expect(first.stdoutLines.last, 'wrote');
      expect(first.exitCode, 0);
      expect(tree(root), before, reason: 'the host export is byte-identical, empty directories included');
      expect(await fx.git(['status', '--porcelain', '--ignored']), status);
      expect(File(p.join(root, 'lib/a.dart')).readAsStringSync(), 'bool lt(int a, int b) => a < b;\n');
    });

    test('the next run sees none of it', () async {
      await sh(sandboxed(), writeEverywhere);
      final second = await sh(sandboxed(), lookEverywhere);
      expect(second.stdoutLines.where((l) => l.startsWith('SEEN')), isEmpty);
      expect(second.stdoutLines, contains('lib=bool lt(int a, int b) => a < b;'));
      expect(second.stdoutLines, contains('seed=seed'));
      expect(second.stdoutLines.last, 'looked');
    });

    test('/tmp, /var/tmp, ~/.config and the XDG directories of the host are untouched', () async {
      await sh(sandboxed(), writeEverywhere);
      expect(File(sharedMarker).existsSync(), isFalse);
      expect(File(varTmpMarker).existsSync(), isFalse);
      expect(File(homeMarker).existsSync(), isFalse);
      expect(File('/tmp/xdg/cache/$xdgMarkerName').existsSync(), isFalse);
      expect(File('/tmp/xdg/config/$xdgMarkerName').existsSync(), isFalse);
      expect(File('/tmp/xdg/data/$xdgMarkerName').existsSync(), isFalse);
      expect(File('/tmp/tmpdir_marker').existsSync(), isFalse);
    });

    test('a write inside a run is visible to that run (the overlay is read-write, only the end is discarded)', () async {
      final o = await sh(sandboxed(), 'echo new > untracked.txt; cat untracked.txt; echo x > /tmp/a; cat /tmp/a');
      expect(o.stdoutLines, ['new', 'x']);
    });

    test('the mutant applied on the host before the launch is what the run sees', () async {
      File(p.join(root, 'lib/a.dart')).writeAsStringSync('bool lt(int a, int b) => a <= b;\n');
      final o = await sh(sandboxed(), 'cat lib/a.dart');
      expect(o.stdoutLines, ['bool lt(int a, int b) => a <= b;']);
    });

    test('the rest of the host is read-only: a write outside the export, /tmp and HOME fails', () async {
      final o = await sh(sandboxed(),
          'for d in /etc /usr /var /opt; do [ -d \$d ] && { touch \$d/mutaudit_x_$id 2>/dev/null && echo "WROTE \$d" || echo "refused \$d"; }; done');
      expect(o.stdoutLines, isNotEmpty);
      expect(o.stdoutLines.where((l) => l.startsWith('WROTE')), isEmpty, reason: o.stdoutLines.join('\n'));
      for (final d in ['/etc', '/usr', '/var', '/opt']) {
        expect(File('$d/mutaudit_x_$id').existsSync(), isFalse);
      }
    });

    test('the directory of the export outside the export (its parent, the out directory) is not writable through the sandbox', () async {
      // The export sits under /tmp, which is a tmpfs inside: a sibling written there is gone with the run.
      final sibling = p.join(fx.parent, 'out_dir_stand_in');
      Directory(sibling).createSync();
      await sh(sandboxed(), 'echo x > "$sibling/result.json"; echo y > "${fx.parent}/top"');
      expect(Directory(sibling).listSync(), isEmpty);
      expect(File(p.join(fx.parent, 'top')).existsSync(), isFalse);
    });

    test('the same path seen from two parallel-looking sequential runs is the pristine export both times', () async {
      for (var i = 0; i < 3; i++) {
        final o = await sh(sandboxed(), 'test ! -e untracked.txt && echo clean; echo x > untracked.txt');
        expect(o.stdoutLines, ['clean'], reason: 'run $i');
      }
    });
  }, skip: skip);

  group('processes', () {
    int? findProcess(String marker) {
      for (final e in Directory('/proc').listSync(followLinks: false)) {
        final n = int.tryParse(p.basename(e.path));
        if (n == null) continue;
        try {
          final cmd = File('${e.path}/cmdline').readAsStringSync();
          if (cmd.contains(marker) && !cmd.contains('mutaudit_test_marker_scan')) return n;
        } on FileSystemException {
          continue;
        }
      }
      return null;
    }

    test('a TERM-ignoring grandchild dies with the sandbox (pid namespace), without any help from the runner', () async {
      final marker = '7${pid}1.25';
      final sandbox = Sandbox.discover(root);
      final argv = sandbox.wrap(['sh', '-c', 'trap "" TERM; (trap "" TERM; exec sleep $marker) >/dev/null 2>&1 & sleep 0.3; exit 0'],
          workingDirectory: root);
      final r = await Process.run(argv.first, argv.sublist(1), workingDirectory: root).timeout(const Duration(seconds: 20));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final leftover = findProcess(marker);
      if (leftover != null) Process.killPid(leftover, ProcessSignal.sigkill);
      expect(leftover, isNull, reason: 'the grandchild outlived the sandbox');
    });

    test('through the runner: a finished run leaves nothing for the runner to stop', () async {
      final marker = '7${pid}2.25';
      final o = await sh(sandboxed(), 'trap "" TERM; (trap "" TERM; exec sleep $marker) >/dev/null 2>&1 & sleep 0.3; echo up');
      final leftover = findProcess(marker);
      if (leftover != null) Process.killPid(leftover, ProcessSignal.sigkill);
      expect(o.stdoutLines, ['up']);
      expect(leftover, isNull);
      expect(o.survivors, isEmpty);
      expect(o.cleanupFailed, isFalse);
    });

    test('a timeout stops a TERM-ignoring tree, no survivors, and returns promptly', () async {
      final marker = '7${pid}3.25';
      final o = await sh(sandboxed(), 'trap "" TERM; (trap "" TERM; exec sleep $marker) & trap "" TERM; sleep $marker.9 & wait',
          timeout: const Duration(seconds: 2));
      final leftover = findProcess(marker);
      if (leftover != null) Process.killPid(leftover, ProcessSignal.sigkill);
      expect(o.timedOut, isTrue);
      expect(o.survivors, isEmpty);
      expect(leftover, isNull);
      expect(o.elapsed, lessThan(const Duration(seconds: 12)));
    });

    test('a cancel stops the run the same way', () async {
      final marker = '7${pid}4.25';
      final token = CancelToken();
      final running = sandboxed().run(
          ['sh', '-c', 'trap "" TERM; (trap "" TERM; exec sleep $marker) >/dev/null 2>&1 & echo up; wait'],
          workingDirectory: root,
          cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      token.cancel();
      final o = await running.timeout(const Duration(seconds: 40));
      final leftover = findProcess(marker);
      if (leftover != null) Process.killPid(leftover, ProcessSignal.sigkill);
      expect(o.cancelled, isTrue);
      expect(o.survivors, isEmpty);
      expect(leftover, isNull);
    });
  }, skip: skip);

  group('network', () {
    test('the host loopback is not reachable from inside; a loopback inside the run is', () async {
      if (Process.runSync('sh', ['-c', 'command -v bash']).exitCode != 0) {
        markTestSkipped('needs bash (/dev/tcp)');
        return;
      }
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final connections = server.listen((s) => s.destroy());
      addTearDown(connections.cancel);
      final probe = 'if (echo > /dev/tcp/127.0.0.1/${server.port}) 2>/dev/null; then echo REACHED; else echo blocked; fi';
      final inside = await sandboxed().run(['bash', '-c', probe], workingDirectory: root, timeout: const Duration(seconds: 20));
      final outside = await runner.run(['bash', '-c', probe], workingDirectory: root, timeout: const Duration(seconds: 20));
      expect(outside.stdoutLines.last, 'REACHED', reason: 'the control: the server is reachable from the host');
      expect(inside.stdoutLines.last, 'blocked');
    });
  }, skip: skip);

  group('Sandbox.probe', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mutaudit_fakebwrap_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String fake(String body) {
      final f = File(p.join(dir.path, 'bwrap'))..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', f.path]);
      return f.path;
    }

    test('passes with the real thing', () async {
      await Sandbox.probe();
    }, skip: skip);

    test('a missing bwrap is "unavailable", and says how to go on', () async {
      await expectLater(
          Sandbox.probe(bwrap: p.join(dir.path, 'nope')),
          throwsA(isA<SandboxUnavailable>().having((e) => e.message, 'message', allOf(contains('--no-sandbox'), contains('nope')))));
    });

    test('a bwrap that cannot create a sandbox is "unavailable", with its own message', () async {
      final b = fake('[ "\$1" = --version ] && { echo "bubblewrap 0.0"; exit 0; }\necho "bwrap: No permissions to create new namespace" >&2\nexit 1');
      await expectLater(
          Sandbox.probe(bwrap: b),
          throwsA(isA<SandboxUnavailable>().having((e) => e.message, 'message', contains('No permissions to create new namespace'))));
    });

    test('a bwrap that does not isolate (runs the command as is) is caught by the write check', () async {
      final b = fake('[ "\$1" = --version ] && { echo "bubblewrap 0.0"; exit 0; }\n'
          'while [ "\$1" != -- ]; do shift; done; shift; mkdir -p "\$HOME"; exec env TMPDIR=/tmp "\$@"');
      await expectLater(
          Sandbox.probe(bwrap: b, environment: {...Platform.environment, 'HOME': dir.path}),
          throwsA(isA<SandboxUnavailable>().having((e) => e.message, 'message', contains('let a write through'))));
    });
  });
}
