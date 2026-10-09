import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fakes.dart';

/// The bubblewrap command line, without running anything. What the sandbox
/// really does is pinned in sandbox_real_test.dart.
void main() {
  const export = '/tmp/mutaudit_export_1/repo';
  const home = '/home/dev';

  Sandbox sandbox({
    List<String> readOnly = const [],
    bool net = true,
    String? runtime = '/run/user/1000',
    String path = export,
    List<String> tmpDirs = const ['/tmp', '/var/tmp'],
  }) =>
      Sandbox(
          bwrap: 'bwrap',
          exportPath: path,
          home: home,
          readOnly: readOnly,
          runtimeDir: runtime,
          unshareNet: net,
          tmpDirs: tmpDirs);

  List<String> wrap(Sandbox s, [List<String> cmd = const ['flutter', 'test', '--reporter', 'json']]) =>
      s.wrap(cmd, workingDirectory: export);

  /// Index of the flag sequence [seq] in [argv] (-1: absent).
  int at(List<String> argv, List<String> seq) {
    for (var i = 0; i + seq.length <= argv.length; i++) {
      var ok = true;
      for (var j = 0; j < seq.length; j++) {
        if (argv[i + j] != seq[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  group('the fixed part', () {
    test('the host is read-only, /dev and /proc are fresh, and every namespace that matters is new', () {
      final a = wrap(sandbox());
      expect(a.first, 'bwrap');
      expect(at(a, ['--ro-bind', '/', '/']), isNonNegative);
      expect(at(a, ['--dev', '/dev']), isNonNegative);
      expect(at(a, ['--proc', '/proc']), isNonNegative);
      for (final f in ['--unshare-pid', '--unshare-ipc', '--unshare-net', '--die-with-parent', '--new-session']) {
        expect(a, contains(f), reason: f);
      }
    });

    test('the network namespace is optional', () {
      expect(wrap(sandbox(net: false)), isNot(contains('--unshare-net')));
    });

    test('nothing is bound writable: every bind is read-only', () {
      final a = wrap(sandbox(readOnly: ['/home/dev/.pub-cache', '/home/dev/flutter']));
      for (final w in ['--bind', '--bind-try', '--dev-bind', '--dev-bind-try', '--bind-fd']) {
        expect(a, isNot(contains(w)), reason: w);
      }
      expect(a.where((x) => x == '--ro-bind').length, greaterThanOrEqualTo(3));
    });

    test('/tmp, /var/tmp and HOME are fresh, empty tmpfs', () {
      final a = wrap(sandbox());
      expect(at(a, ['--tmpfs', '/tmp']), isNonNegative);
      expect(at(a, ['--tmpfs', '/var/tmp']), isNonNegative);
      expect(at(a, ['--tmpfs', home]), isNonNegative);
    });

    test('a temporary directory the host lacks is not mounted (the host root is read-only: it could not be created)', () {
      final a = wrap(sandbox(tmpDirs: ['/tmp']));
      expect(a, isNot(contains('/var/tmp')));
    });

    test('the runtime directory (sockets of the desktop session) is hidden too', () {
      expect(at(wrap(sandbox()), ['--tmpfs', '/run/user/1000']), isNonNegative);
      expect(wrap(sandbox(runtime: null)), isNot(contains('/run/user/1000')));
    });
  });

  group('the export', () {
    test('is an overlay whose writes go to memory: --overlay-src then --tmp-overlay on the same path', () {
      final a = wrap(sandbox());
      final i = at(a, ['--overlay-src', export, '--tmp-overlay', export]);
      expect(i, isNonNegative);
    });

    test('is mounted after the tmpfs that may hide its parent (/tmp, HOME)', () {
      final a = wrap(sandbox());
      final o = at(a, ['--overlay-src', export]);
      expect(o, greaterThan(at(a, ['--tmpfs', '/tmp'])));
      expect(o, greaterThan(at(a, ['--tmpfs', home])));
      expect(o, greaterThan(at(a, ['--tmpfs', '/var/tmp'])));
      final underHome = Sandbox(exportPath: '$home/work/export', home: home);
      final b = underHome.wrap(['x'], workingDirectory: '$home/work/export');
      expect(at(b, ['--overlay-src', '$home/work/export']), greaterThan(at(b, ['--tmpfs', home])));
    });

    test('is never the target of a plain bind (which would write through)', () {
      final a = wrap(sandbox());
      expect(at(a, ['--ro-bind', export, export]), -1);
      expect(at(a, ['--bind', export, export]), -1);
    });

    test('the working directory is set inside, and the command comes last after "--"', () {
      final a = wrap(sandbox(), ['dart', 'test', '--version', '--', '-x']);
      final dd = a.indexOf('--');
      expect(a.sublist(dd + 1), ['dart', 'test', '--version', '--', '-x'], reason: 'verbatim, never re-parsed');
      expect(at(a, ['--chdir', export]), isNonNegative);
      expect(at(a, ['--chdir', export]), lessThan(dd));
    });
  });

  group('HOME', () {
    test('read-only toolchain paths under HOME are re-bound after the tmpfs; others are dropped', () {
      final a = wrap(sandbox(readOnly: ['/home/dev/.pub-cache', '/opt/flutter', '/home/dev/.pub-cache/hosted/x', '/home/dev/sdk']));
      final tm = at(a, ['--tmpfs', home]);
      expect(at(a, ['--ro-bind', '/home/dev/.pub-cache', '/home/dev/.pub-cache']), greaterThan(tm));
      expect(at(a, ['--ro-bind', '/home/dev/sdk', '/home/dev/sdk']), greaterThan(tm));
      expect(a, isNot(contains('/opt/flutter')), reason: 'outside HOME it is visible already');
      expect(a, isNot(contains('/home/dev/.pub-cache/hosted/x')), reason: 'inside a path that is bound already');
    });

    test('HOME itself being listed does not expose it', () {
      final a = wrap(sandbox(readOnly: [home, '$home/']));
      expect(at(a, ['--ro-bind', home, home]), -1);
    });

    test('HOME, the XDG directories and TMPDIR point into the sandbox', () {
      final a = wrap(sandbox());
      String env(String k) {
        final i = at(a, ['--setenv', k]);
        expect(i, isNonNegative, reason: k);
        return a[i + 2];
      }

      expect(env('HOME'), home);
      for (final k in ['XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME']) {
        expect(env(k), startsWith('/tmp/'), reason: k);
        expect(a, contains(env(k)), reason: '$k exists: a --dir creates it');
      }
      for (final k in ['TMPDIR', 'TMP', 'TEMP']) {
        expect(env(k), '/tmp', reason: k);
      }
      expect(env('XDG_RUNTIME_DIR'), '/run/user/1000');
      expect(env('FLUTTER_SUPPRESS_ANALYTICS'), 'true');
    });
  });

  group('discover reads the toolchain from the environment', () {
    test('the pub cache, FLUTTER_ROOT and PATH entries under HOME are read-only binds; the rest is not', () {
      final s = Sandbox.discover(export, environment: {
        'HOME': home,
        'PUB_CACHE': '/home/dev/cache/pub',
        'FLUTTER_ROOT': '/home/dev/flutter',
        'PATH': '/home/dev/flutter/bin:/usr/bin:/home/dev/.local/bin',
        'XDG_RUNTIME_DIR': '/run/user/1000',
      }, extraReadOnly: ['/home/dev/sibling'], exists: (_) => true);
      expect(s.home, home);
      expect(s.readOnly, containsAll(['/home/dev/cache/pub', '/home/dev/flutter', '/home/dev/.local/bin', '/home/dev/sibling']));
      expect(s.readOnly, isNot(contains('/usr/bin')));
      expect(s.runtimeDir, '/run/user/1000');
    });

    test('without PUB_CACHE the default ~/.pub-cache is used', () {
      final s = Sandbox.discover(export, environment: {'HOME': home, 'PATH': '/usr/bin'}, exists: (_) => true);
      expect(s.readOnly, ['/home/dev/.pub-cache']);
    });

    test('without HOME the sandbox gets one inside /tmp', () {
      final s = Sandbox.discover(export, environment: {'PATH': '/usr/bin'});
      expect(s.home, startsWith('/tmp/'));
    });

    test('a HOME that does not exist on the host is replaced (it could not be mounted over)', () {
      final s = Sandbox.discover(export, environment: {'HOME': home, 'PATH': '/usr/bin'}, exists: (_) => false);
      expect(s.home, startsWith('/tmp/'));
    });

    test('what is not on the host is not bound: read-only paths, /var/tmp, the runtime directory', () {
      final s = Sandbox.discover(export,
          environment: {'HOME': home, 'PATH': '/home/dev/gone/bin', 'XDG_RUNTIME_DIR': '/run/user/1000'},
          exists: (path) => path == home);
      expect(s.readOnly, isEmpty);
      expect(s.tmpDirs, ['/tmp']);
      expect(s.runtimeDir, isNull);
    });

    test('package roots outside the export that the package config names are read-only binds', () {
      final dir = Directory.systemTemp.createTempSync('mutaudit_pc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tool = Directory(p.join(dir.path, '.dart_tool'))..createSync();
      File(p.join(tool.path, 'package_config.json')).writeAsStringSync(jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'hosted', 'rootUri': 'file:///home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0', 'packageUri': 'lib/'},
          {'name': 'sibling', 'rootUri': '../../sibling', 'packageUri': 'lib/'},
          {'name': 'self', 'rootUri': '../', 'packageUri': 'lib/'},
          {'name': 'inside', 'rootUri': '../vendor/x', 'packageUri': 'lib/'},
        ],
      }));
      final s = Sandbox.discover(dir.path, environment: {'HOME': home, 'PATH': ''}, exists: (_) => true);
      expect(s.readOnly, contains('/home/dev/.pub-cache'));
      expect(s.readOnly, isNot(contains('/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0')),
          reason: 'inside the pub cache, which is bound whole');
      final other = Sandbox.discover(dir.path, environment: {'HOME': home, 'PATH': '', 'PUB_CACHE': '/home/dev/elsewhere'}, exists: (_) => true);
      expect(other.readOnly, contains('/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0'),
          reason: 'a package root of its own is bound when nothing above it is');
      expect(Sandbox.packageRoots(dir.path),
          unorderedEquals(['/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0', p.normalize(p.join(dir.path, '..', 'sibling'))]),
          reason: 'the export itself and what lies inside it are visible already');
    });
  });

  group('the runner wraps every command', () {
    test('the inner runner gets the wrapped argv, the same directory, timeout, environment and token', () async {
      final inner = FakeProcessRunner((call) => const ProcessOutcome(exitCode: 0));
      final runner = SandboxedProcessRunner(inner, sandbox());
      final token = CancelToken();
      await runner.run(['dart', 'test'],
          workingDirectory: export, timeout: const Duration(seconds: 7), environment: {'TZ': 'UTC'}, cancel: token);
      final c = inner.calls.single;
      expect(c.argv.first, 'bwrap');
      expect(c.argv.sublist(c.argv.indexOf('--') + 1), ['dart', 'test']);
      expect(c.cwd, export);
      expect(c.timeout, const Duration(seconds: 7));
      expect(c.environment, {'TZ': 'UTC'});
      expect(c.cancel, same(token));
    });
  });
}
