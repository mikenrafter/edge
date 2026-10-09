import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fakes.dart';

/// A host described by a set of paths and links: [Sandbox.discover] without a
/// particular machine.
class FakeHost implements HostPaths {
  FakeHost(Iterable<String> paths, [this.links = const {}, this.specials = const {}]) : paths = paths.toSet();
  final Set<String> paths;
  final Map<String, String> links;

  /// Sockets and FIFOs that exist, by path.
  final Set<String> specials;

  /// The roots [specialFile] was asked about.
  final List<String> scanned = [];

  @override
  String? specialFile(String path) {
    scanned.add(path);
    for (final s in specials) {
      if (s == path || s.startsWith('$path/')) return s;
    }
    return null;
  }

  @override
  bool exists(String path) => realpath(path) != null || links.containsKey(path);

  @override
  String? linkTarget(String path) => links[path];

  @override
  String? realpath(String path) {
    var cur = path;
    for (var i = 0; i < 20; i++) {
      final hit = links.entries.where((e) => cur == e.key || cur.startsWith('${e.key}/')).toList()
        ..sort((a, b) => b.key.length.compareTo(a.key.length));
      if (hit.isEmpty) break;
      final e = hit.first;
      cur = p.normalize(p.join(e.value, cur.substring(e.key.length).replaceFirst('/', '')));
    }
    return paths.any((x) => x == cur || x.startsWith('$cur/')) ? cur : null;
  }
}

/// The bubblewrap command line, without running anything. What the sandbox
/// really does is pinned in sandbox_real_test.dart.
void main() {
  const export = '/tmp/mutaudit_export_1/repo';
  const home = '/home/dev';

  Sandbox sandbox({
    List<String> binds = const [],
    Map<String, String> symlinks = const {},
    bool net = true,
    String path = export,
    List<String> tmpDirs = const ['/tmp', '/var/tmp', '/run'],
  }) =>
      Sandbox(
          bwrap: 'bwrap',
          exportPath: path,
          home: home,
          binds: binds,
          symlinks: symlinks,
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

  group('tmpfs mounts are size-limited (bwrap --size, immediately before --tmpfs)', () {
    const gib = 1024 * 1024 * 1024;

    test('every --tmpfs has --size BYTES right before it: 1G by default', () {
      final a = wrap(sandbox());
      final tmpfs = [for (var i = 0; i < a.length; i++) if (a[i] == '--tmpfs') i];
      expect(tmpfs, hasLength(5), reason: '/tmp /var/tmp /run /dev/shm and HOME');
      for (final i in tmpfs) {
        expect(a.sublist(i - 2, i), ['--size', '$gib'], reason: 'before ${a[i + 1]}');
      }
    });

    test('--size is never given to anything else (bwrap applies it to the next --tmpfs only)', () {
      final a = wrap(sandbox());
      for (var i = 0; i < a.length; i++) {
        if (a[i] == '--size') expect(a[i + 2], '--tmpfs');
      }
      expect(a.where((x) => x == '--size'), hasLength(a.where((x) => x == '--tmpfs').length));
    });

    test('the size is configurable', () {
      final a = wrap(Sandbox(exportPath: export, home: home, tmpfsSize: 256 * 1024 * 1024));
      expect(a.where((x) => x == '${256 * 1024 * 1024}'), hasLength(5));
      expect(a, isNot(contains('$gib')));
    });

    test('the export overlay has no --size of its own: bwrap cannot size --tmp-overlay (its pages are charged to the cgroup)', () {
      final a = wrap(sandbox());
      final o = a.indexOf('--tmp-overlay');
      expect(a[o - 2], '--overlay-src');
      expect(a[o - 1], export);
    });
  });

  group('the root is minimal: the host is not bound', () {
    test('there is no bind of / (host sockets, other users\' files and services stay out of reach)', () {
      final a = wrap(sandbox(binds: ['/nix/store', '/usr']));
      for (var i = 0; i + 1 < a.length; i++) {
        if (a[i] == '--ro-bind' || a[i] == '--bind') expect(a[i + 1], isNot('/'), reason: 'argument $i');
      }
      expect(at(a, ['--ro-bind', '/', '/']), -1);
    });

    test('only what is listed is bound, read-only, and the new root itself is remounted read-only after all mounts', () {
      final a = wrap(sandbox(binds: ['/nix/store', '/usr', '/etc/passwd']));
      final bound = <String>[
        for (var i = 0; i + 2 < a.length; i++)
          if (a[i] == '--ro-bind') a[i + 1],
      ];
      expect(bound.where((b) => !b.startsWith('/nix') && !b.startsWith('/usr') && !b.startsWith('/etc')), isEmpty);
      expect(bound, containsAll(['/nix/store', '/usr', '/etc/passwd']));
      expect(a.indexOf('--remount-ro'), greaterThan(a.indexOf('--tmp-overlay')));
      expect(a[a.indexOf('--remount-ro') + 1], '/');
    });

    test('symbolic links are created, after the tmpfs mounts that may hold them', () {
      final a = wrap(sandbox(symlinks: {'/run/current-system/sw/bin': '/nix/store/abc-system-path/bin', '/lib64': 'usr/lib64'}));
      final i = at(a, ['--symlink', '/nix/store/abc-system-path/bin', '/run/current-system/sw/bin']);
      expect(i, isNonNegative);
      expect(i, greaterThan(at(a, ['--tmpfs', '/run'])));
      expect(at(a, ['--symlink', 'usr/lib64', '/lib64']), isNonNegative);
    });

    test('nested binds are folded into their parent, duplicates dropped', () {
      final a = wrap(sandbox(binds: ['/nix/store/abc-x', '/nix/store', '/nix/store/', '/opt/sdk']));
      final bound = [for (var i = 0; i + 2 < a.length; i++) if (a[i] == '--ro-bind') a[i + 1]];
      expect(bound, ['/nix/store', '/opt/sdk']);
    });

    test('binds under HOME or /tmp come after the tmpfs that replaces those directories', () {
      final a = wrap(sandbox(binds: ['/home/dev/.pub-cache', '/tmp/tools']));
      expect(at(a, ['--ro-bind', '/home/dev/.pub-cache', '/home/dev/.pub-cache']), greaterThan(at(a, ['--tmpfs', home])));
      expect(at(a, ['--ro-bind', '/tmp/tools', '/tmp/tools']), greaterThan(at(a, ['--tmpfs', '/tmp'])));
    });

    test('HOME itself is never bound', () {
      final a = wrap(sandbox(binds: [home, '$home/']));
      expect(at(a, ['--ro-bind', home, home]), -1);
    });
  });

  group('the fixed part', () {
    test('/dev and /proc are fresh, and every namespace that matters is new', () {
      final a = wrap(sandbox());
      expect(a.first, 'bwrap');
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
      final a = wrap(sandbox(binds: ['/nix/store', '/home/dev/.pub-cache']));
      for (final w in ['--bind', '--bind-try', '--dev-bind', '--dev-bind-try', '--bind-fd']) {
        expect(a, isNot(contains(w)), reason: w);
      }
      expect(a.where((x) => x == '--ro-bind').length, 2);
    });

    test('/tmp, /var/tmp, /run, /dev/shm and HOME are fresh, empty tmpfs; /dev/shm after /dev', () {
      final a = wrap(sandbox());
      for (final d in ['/tmp', '/var/tmp', '/run', '/dev/shm', home]) {
        expect(at(a, ['--tmpfs', d]), isNonNegative, reason: d);
      }
      expect(at(a, ['--tmpfs', '/dev/shm']), greaterThan(at(a, ['--dev', '/dev'])));
    });

    test('the runtime directory of the desktop session is inside /run, which is empty', () {
      final a = wrap(sandbox());
      expect(a, isNot(contains('/run/user/1000')));
      final i = at(a, ['--setenv', 'XDG_RUNTIME_DIR']);
      expect(i, isNonNegative);
      expect(a[i + 2], startsWith('/tmp/'));
    });
  });

  group('the export', () {
    test('is an overlay whose writes go to memory: --overlay-src then --tmp-overlay on the same path', () {
      final a = wrap(sandbox());
      expect(at(a, ['--overlay-src', export, '--tmp-overlay', export]), isNonNegative);
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

  group('environment', () {
    test('HOME, the XDG directories and TMPDIR point into the sandbox', () {
      final a = wrap(sandbox());
      String env(String k) {
        final i = at(a, ['--setenv', k]);
        expect(i, isNonNegative, reason: k);
        return a[i + 2];
      }

      expect(env('HOME'), home);
      for (final k in ['XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR']) {
        expect(env(k), startsWith('/tmp/'), reason: k);
        expect(a, contains(env(k)), reason: '$k exists: a --dir creates it');
      }
      for (final k in ['TMPDIR', 'TMP', 'TEMP']) {
        expect(env(k), '/tmp', reason: k);
      }
      expect(env('FLUTTER_SUPPRESS_ANALYTICS'), 'true');
    });
  });

  group('discover builds the root from the host', () {
    // A NixOS-like host: the store, /etc entries that are links into it, a
    // /bin with /bin/sh, the system profile reached through /run/current-system.
    final nixos = FakeHost([
      '/nix/store', '/nix/store/sys-path/bin', '/nix/store/flutter/bin/flutter', '/nix/store/flutter',
      '/usr', '/usr/bin', '/bin', '/etc', '/etc/passwd', '/etc/group', '/etc/nsswitch.conf', '/etc/hosts', '/etc/shadow',
      '/etc/litellm', '/home/dev', '/home/dev/.pub-cache', '/run', '/run/user/1000', '/run/wrappers/bin', '/nix/var/nix/daemon-socket',
    ], {
      '/run/current-system': '/nix/store/system',
      '/run/current-system/sw': '/nix/store/sys-path',
    });
    final env = {
      'HOME': home,
      'PATH': '/nix/store/flutter/bin:/run/current-system/sw/bin:/run/wrappers/bin:/gone/bin:relative/bin',
      'XDG_RUNTIME_DIR': '/run/user/1000',
    };
    Sandbox found({Map<String, String>? environment, FakeHost? host, List<String> extra = const [], List<String> command = const []}) =>
        Sandbox.discover(export, environment: environment ?? env, host: host ?? nixos, extraReadOnly: extra, command: command);

    test('the Nix store is bound, not /nix (the daemon socket lives in /nix/var)', () {
      final s = found();
      expect(s.binds, contains('/nix/store'));
      expect(s.binds, isNot(contains('/nix')));
      expect(s.binds.where((b) => b.startsWith('/nix/var')), isEmpty);
    });

    test('/usr and /bin are bound when they are directories; a link such as /lib64 or a merged /bin is recreated as a link', () {
      final s = found(host: FakeHost([...nixos.paths, '/lib64'], {...nixos.links, '/sbin': 'usr/sbin', '/lib': 'usr/lib'}));
      expect(s.binds, containsAll(['/usr', '/bin']));
      expect(s.symlinks['/sbin'], 'usr/sbin');
      expect(s.symlinks['/lib'], 'usr/lib');
      expect(s.binds, isNot(contains('/sbin')));
      expect(s.binds, contains('/lib64'));
    });

    test('of /etc only the allow-listed entries that exist are bound: users, groups, name service, hosts', () {
      final s = found();
      expect(s.binds, containsAll(['/etc/passwd', '/etc/group', '/etc/nsswitch.conf', '/etc/hosts']));
      expect(s.binds, isNot(contains('/etc')));
      expect(s.binds, isNot(contains('/etc/shadow')));
      expect(s.binds, isNot(contains('/etc/litellm')));
      expect(s.binds.where((b) => b.startsWith('/etc/')).length, 4, reason: 'localtime etc. are absent on this host');
    });

    test('a PATH entry inside the store needs nothing; one reached through a link is recreated as a link', () {
      final s = found();
      expect(s.binds, isNot(contains('/nix/store/flutter/bin')));
      expect(s.symlinks['/run/current-system/sw/bin'], '/nix/store/sys-path/bin');
    });

    test('PATH entries that do not exist, are relative, or are runtime state (/run) are not bound', () {
      final s = found();
      expect(s.binds.any((b) => b.startsWith('/gone') || b.startsWith('relative') || b.startsWith('/run')), isFalse);
      expect(s.binds, isNot(contains('/run/wrappers/bin')));
    });

    test('a PATH entry outside the store and the system directories is bound where it is', () {
      final s = found(
          host: FakeHost([...nixos.paths, '/opt/tools/bin'], nixos.links),
          environment: {...env, 'PATH': '/opt/tools/bin:/usr/bin'});
      expect(s.binds, contains('/opt/tools/bin'));
      expect(s.binds, isNot(contains('/usr/bin')), reason: 'inside /usr, which is bound');
    });

    test('the pub cache (PUB_CACHE, else ~/.pub-cache) and FLUTTER_ROOT are bound', () {
      expect(found().binds, contains('/home/dev/.pub-cache'));
      final s = found(
          host: FakeHost([...nixos.paths, '/srv/pub', '/opt/flutter'], nixos.links),
          environment: {...env, 'PUB_CACHE': '/srv/pub', 'FLUTTER_ROOT': '/opt/flutter'});
      expect(s.binds, containsAll(['/srv/pub', '/opt/flutter']));
      expect(s.binds, isNot(contains('/home/dev/.pub-cache')));
    });

    test('extra read-only paths are bound wherever they are (an allowed sibling outside HOME is no longer visible by itself)', () {
      final s = found(host: FakeHost([...nixos.paths, '/srv/sibling'], nixos.links), extra: ['/srv/sibling', '/gone/sibling']);
      expect(s.binds, contains('/srv/sibling'));
      expect(s.binds, isNot(contains('/gone/sibling')));
    });

    test('the executable of the test command: found on PATH, its SDK (the directory above bin/) is bound when outside the store', () {
      final host = FakeHost([...nixos.paths, '/opt/flutter/bin', '/opt/flutter/bin/flutter', '/opt/flutter/packages'], nixos.links);
      final s = found(host: host, environment: {...env, 'PATH': '/opt/flutter/bin:/usr/bin'}, command: ['flutter', 'test']);
      expect(s.binds, contains('/opt/flutter'));
      expect(s.binds, isNot(contains('/opt/flutter/bin')), reason: 'folded into /opt/flutter');
    });

    group('places that are never bound (and recorded as skipped)', () {
      Sandbox with_(List<String> pathEntries, {List<String> more = const [], Map<String, String> extraEnv = const {}, List<String> extra = const [], List<String> command = const []}) =>
          found(
              host: FakeHost([...nixos.paths, '/', ...pathEntries, ...more], nixos.links),
              environment: {...env, 'PATH': pathEntries.join(':'), ...extraEnv},
              extra: extra,
              command: command);

      test('a PATH entry that is, or is under, /tmp, /var/tmp, /run, /dev/shm, /proc, /sys, /dev', () {
        final entries = ['/tmp/tools', '/tmp', '/var/tmp/x/bin', '/dev/shm/bin', '/run/foo/bin', '/proc/self/cwd', '/sys/x', '/dev/x'];
        final s = with_(entries);
        for (final e in entries) {
          expect(s.binds, isNot(contains(e)), reason: e);
          expect(s.skipped.keys, contains(e), reason: e);
        }
        expect(s.skipped['/tmp/tools'], contains('/tmp'));
      });

      test('a path that CONTAINS one of them (/var holds /var/tmp; / holds everything) would cover the fresh tmpfs', () {
        final s = with_(['/var', '/'], more: ['/var/tmp']);
        expect(s.binds, isNot(contains('/var')));
        expect(s.binds, isNot(contains('/')));
        expect(s.skipped.keys, containsAll(['/var', '/']));
      });

      test('a PATH entry under HOME, HOME itself and the directory above it', () {
        final s = with_(['/home/dev/bin', '/home/dev', '/home'], more: ['/home/dev/bin']);
        expect(s.binds, isNot(anyOf(contains('/home/dev/bin'), contains('/home/dev'), contains('/home'))));
        expect(s.skipped.keys, containsAll(['/home/dev/bin', '/home/dev', '/home']));
        expect(s.skipped['/home/dev/bin'], contains('HOME'));
      });

      test('the explicit toolchain stays possible under HOME: the pub cache, FLUTTER_ROOT, --sandbox-ro, package roots', () {
        final s = with_(['/usr/bin'], more: ['/home/dev/flutter', '/home/dev/sibling'],
            extraEnv: {'FLUTTER_ROOT': '/home/dev/flutter'}, extra: ['/home/dev/sibling']);
        expect(s.binds, containsAll(['/home/dev/.pub-cache', '/home/dev/flutter', '/home/dev/sibling']));
        expect(s.skipped, isEmpty);
      });

      test('but not under /tmp and the like, whoever asks', () {
        final s = with_(['/usr/bin'], more: ['/tmp/sib'], extra: ['/tmp/sib']);
        expect(s.binds, isNot(contains('/tmp/sib')));
        expect(s.skipped.keys, contains('/tmp/sib'));
      });

      test('the SDK found for the test command is held to the same rule', () {
        final s = with_(['/home/dev/sdk/bin'], more: ['/home/dev/sdk/bin/flutter'], command: ['flutter']);
        expect(s.binds, isNot(contains('/home/dev/sdk')));
        expect(s.skipped.keys, contains('/home/dev/sdk'));
      });

      test('the skipped entries are in the report', () {
        final s = with_(['/tmp/tools']);
        expect(IsolationInfo(mode: 'bubblewrap', skipped: s.skipped).toJson()['skipped'], {'/tmp/tools': s.skipped['/tmp/tools']});
      });
    });

    group('a bind that holds a Unix socket or a FIFO is refused', () {
      test('a PATH directory with a socket in it: discovery fails and names the directory and the socket', () {
        final host = FakeHost([...nixos.paths, '/opt/tools/bin', '/opt/tools/bin/daemon.sock'], nixos.links, {'/opt/tools/bin/daemon.sock'});
        expect(() => found(host: host, environment: {...env, 'PATH': '/opt/tools/bin'}),
            throwsA(isA<SandboxUnavailable>().having((e) => e.message, 'message', allOf(contains('/opt/tools/bin'), contains('daemon.sock'), contains('socket')))));
      });

      test('a FIFO deeper in the pub cache, an explicit --sandbox-ro, FLUTTER_ROOT: all refused', () {
        for (final (what, e, extra) in [
          ('pub cache', <String, String>{}, <String>[]),
          ('flutter root', {'FLUTTER_ROOT': '/opt/flutter'}, <String>[]),
          ('extra', <String, String>{}, ['/srv/sib']),
        ]) {
          final host = FakeHost([...nixos.paths, '/opt/flutter', '/srv/sib', '/home/dev/.pub-cache/hosted/x/fifo'], nixos.links,
              {'/home/dev/.pub-cache/hosted/x/fifo', '/opt/flutter/bin/cache/pipe', '/srv/sib/a/b/s'});
          expect(() => found(host: host, environment: {...env, ...e}, extra: extra), throwsA(isA<SandboxUnavailable>()), reason: what);
        }
      });

      test('what is under /nix/store or /usr is not scanned (immutable, system)', () {
        final host = FakeHost([...nixos.paths], nixos.links, {'/nix/store/flutter/x.sock', '/usr/lib/y.sock'});
        final s = found(host: host);
        expect(s.binds, contains('/usr'));
        expect(host.scanned, isNot(anyOf(contains('/nix/store'), contains('/usr'))));
        expect(host.scanned, contains('/home/dev/.pub-cache'));
      });
    });

    test('HOME is never bound whole and does not have to exist on the host', () {
      final s = found(host: FakeHost(['/nix/store']), environment: {'HOME': '/home/nobody', 'PATH': ''});
      expect(s.home, '/home/nobody');
      expect(s.binds, isNot(contains('/home/nobody')));
    });

    test('without HOME the sandbox gets one inside /tmp', () {
      expect(found(environment: {'PATH': ''}).home, startsWith('/tmp/'));
    });

    test('what is not on the host is not bound', () {
      final s = found(host: FakeHost([]), environment: {'HOME': home, 'PATH': '/usr/bin', 'FLUTTER_ROOT': '/opt/flutter'});
      expect(s.binds, isEmpty);
      expect(s.symlinks, isEmpty);
    });

    test('package roots outside the export that the package config names are bound; the pub cache covers its packages', () {
      final dir = Directory.systemTemp.createTempSync('mutaudit_pc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tool = Directory(p.join(dir.path, '.dart_tool'))..createSync();
      File(p.join(tool.path, 'package_config.json')).writeAsStringSync(jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'hosted', 'rootUri': 'file:///home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0', 'packageUri': 'lib/'},
          {'name': 'sibling', 'rootUri': 'file:///srv/sibling', 'packageUri': 'lib/'},
          {'name': 'self', 'rootUri': '../', 'packageUri': 'lib/'},
          {'name': 'inside', 'rootUri': '../vendor/x', 'packageUri': 'lib/'},
        ],
      }));
      expect(Sandbox.packageRoots(dir.path),
          unorderedEquals(['/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0', '/srv/sibling']),
          reason: 'the export itself and what lies inside it are visible already');
      final host = FakeHost([...nixos.paths, '/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0', '/srv/sibling'], nixos.links);
      final s = Sandbox.discover(dir.path, environment: env, host: host);
      expect(s.binds, contains('/home/dev/.pub-cache'));
      expect(s.binds, isNot(contains('/home/dev/.pub-cache/hosted/pub.dev/hosted-1.0.0')));
      expect(s.binds, contains('/srv/sibling'));
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
