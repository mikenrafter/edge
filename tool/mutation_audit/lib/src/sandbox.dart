import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_assets.dart';
import 'process_runner.dart';
import 'run_log.dart';

/// bubblewrap is missing, or a probe sandbox does not behave (no unprivileged
/// user namespaces, an overlay that keeps writes). The audit cannot isolate
/// its runs: it stops unless `--no-sandbox` was given.
class SandboxUnavailable implements Exception {
  SandboxUnavailable(this.message, {this.output});
  final String message;

  /// The whole output of the probe run that failed (command, exit code,
  /// stdout, stderr), when there was one; the command line saves it.
  final String? output;
  @override
  String toString() => 'SandboxUnavailable: $message';
}

/// The bubblewrap command line for one test run.
///
/// Why bubblewrap and not "put the files back afterwards": a test run can
/// leave state in places no restore knows about (a cache directory, `$HOME`,
/// a fixed path under `/tmp`, a socket, a process). Here the run never has a
/// writable view of any of them, and it does not even see most of the host:
///
/// - the root is a MINIMAL, read-only tmpfs. The host is not bound (`--ro-bind
///   / /` would leave every pathname Unix socket on it connectable: a read-only
///   mount does not stop `connect(2)`, so a run could change a host service's
///   state and a later run observe it). Only [binds] are mounted, read-only,
///   and [symlinks] recreated: the Nix store (not `/nix`: the daemon socket is
///   in `/nix/var`), `/usr`, `/bin` and friends, a few `/etc` files, the
///   toolchain (pub cache, SDK, `PATH` entries) and whatever [discover] was
///   told to add;
/// - the export is an overlay (`--overlay-src` + `--tmp-overlay`): the run
///   sees the export with the mutant already applied on the host, and every
///   write it makes lands in memory and disappears with the sandbox;
/// - `/tmp`, `/var/tmp`, `/run`, `/dev/shm` and `$HOME` are fresh tmpfs
///   mounts (`/run` is where the desktop session's sockets live);
/// - new PID namespace: when the sandbox's init exits the kernel kills every
///   process left in it, a TERM-ignoring grandchild included;
/// - new IPC and network namespaces (loopback only: `flutter_tester` talks to
///   the VM service over it; nothing else is reachable).
class Sandbox {
  Sandbox({
    this.bwrap = 'bwrap',
    required this.exportPath,
    required this.home,
    this.binds = const [],
    this.symlinks = const {},
    this.unshareNet = true,
    this.tmpDirs = const ['/tmp', '/var/tmp', '/run'],
    this.skipped = const {},
  });

  /// Paths [discover] would have bound and did not, with the reason.
  final Map<String, String> skipped;

  final String bwrap;
  final String exportPath;

  /// `$HOME` inside the sandbox: an empty tmpfs (plus [binds] under it).
  final String home;

  /// Host paths bound read-only at the same path. The only part of the host
  /// the run can see besides the export.
  final List<String> binds;

  /// Symbolic links created in the sandbox: link -> target (as `readlink`
  /// shows it).
  final Map<String, String> symlinks;
  final bool unshareNet;

  /// Directories replaced by an empty tmpfs.
  final List<String> tmpDirs;

  /// Where the XDG base directories go: inside the `/tmp` tmpfs.
  static const _xdgRoot = '/tmp/xdg';

  /// The argv that runs [argv] in the sandbox, in [workingDirectory].
  List<String> wrap(List<String> argv, {required String workingDirectory}) {
    final xdg = {
      'XDG_CACHE_HOME': '$_xdgRoot/cache',
      'XDG_CONFIG_HOME': '$_xdgRoot/config',
      'XDG_DATA_HOME': '$_xdgRoot/data',
      'XDG_STATE_HOME': '$_xdgRoot/state',
      'XDG_RUNTIME_DIR': '$_xdgRoot/runtime',
    };
    final env = <String, String>{
      'HOME': home,
      ...xdg,
      'TMPDIR': '/tmp',
      'TMP': '/tmp',
      'TEMP': '/tmp',
      // Fresh HOME: the first-run banner would go to stdout, in the JSON stream.
      'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      'DART_SUPPRESS_ANALYTICS': 'true',
    };
    return [
      bwrap,
      '--dev', '/dev',
      '--proc', '/proc',
      '--unshare-pid',
      '--unshare-ipc',
      if (unshareNet) '--unshare-net',
      '--die-with-parent',
      '--new-session',
      for (final t in tmpDirs) ...['--tmpfs', t],
      '--tmpfs', '/dev/shm',
      '--tmpfs', home,
      // After the tmpfs mounts: a bind or a link under /tmp, /run or HOME
      // needs the directory that replaced the host's.
      for (final b in _binds()) ...['--ro-bind', b, b],
      for (final l in symlinks.entries) ...['--symlink', l.value, l.key],
      for (final d in xdg.values) ...['--dir', d],
      // The export may live under /tmp or HOME, which the tmpfs mounts above
      // replaced: it is mounted after them.
      '--overlay-src', exportPath, '--tmp-overlay', exportPath,
      // The new root is a tmpfs of ours: nothing may be created in it.
      '--remount-ro', '/',
      for (final e in env.entries) ...['--setenv', e.key, e.value],
      '--chdir', workingDirectory,
      '--',
      ...argv,
    ];
  }

  /// [binds] normalised, without duplicates, without paths inside another
  /// bound path, never `/` or `$HOME` (or what contains it), shallowest first.
  List<String> _binds() {
    final h = p.normalize(home);
    return pruneNested([
      for (final b in binds)
        if (p.isAbsolute(b) && p.normalize(b) != '/' && p.normalize(b) != h && !p.isWithin(p.normalize(b), h)) p.normalize(b),
    ]);
  }

  /// [paths] without duplicates and without any path inside another one,
  /// shallowest first.
  static List<String> pruneNested(Iterable<String> paths) {
    int depth(String x) => p.split(x).length;
    final sorted = paths.toSet().toList()
      ..sort((a, b) => depth(a) != depth(b) ? depth(a).compareTo(depth(b)) : a.compareTo(b));
    final kept = <String>[];
    for (final path in sorted) {
      if (!kept.any((k) => p.isWithin(k, path))) kept.add(path);
    }
    return kept;
  }

  /// Replaced by an empty tmpfs or kernel state in the sandbox: never bound.
  static const _volatileRoots = ['/tmp', '/var/tmp', '/run', '/dev/shm', '/proc', '/sys', '/dev'];

  /// Directories of the base system a dynamically linked program or a script
  /// (`#!/bin/sh`, `#!/usr/bin/env`) needs: bound when they are directories,
  /// recreated when they are links (a merged `/bin`, `/lib64`). The Nix store
  /// is bound, but not `/nix`.
  static const systemRoots = ['/nix/store', '/usr', '/bin', '/sbin', '/lib', '/lib32', '/lib64', '/libx32'];

  /// The only `/etc` entries bound: who the user is, how names resolve, the
  /// time zone and the dynamic linker's cache.
  static const etcEntries = [
    'passwd', 'group', 'nsswitch.conf', 'hosts', 'localtime', 'os-release', 'ld.so.cache', 'ld.so.conf', 'ld.so.conf.d',
  ];

  /// A sandbox for [exportPath] with a minimal root: [systemRoots], [etcEntries]
  /// and what the toolchain on this machine needs, found from [environment]
  /// (default: the process's): the pub cache (`PUB_CACHE`, else `~/.pub-cache`),
  /// `FLUTTER_ROOT`, every `PATH` entry, the roots the export's package config
  /// names, the SDK of the executable of [command] when it is outside the
  /// store, and [extraReadOnly]. A `PATH` entry that is only a link into
  /// something bound (`/run/current-system/sw/bin`) is recreated as a link.
  /// [host] answers what exists on the machine (a seam for tests); what is
  /// missing is left out because bubblewrap cannot mount it.
  static Sandbox discover(
    String exportPath, {
    Map<String, String>? environment,
    List<String> extraReadOnly = const [],
    List<String> command = const [],
    String bwrap = 'bwrap',
    HostPaths? host,
  }) {
    final env = environment ?? Platform.environment;
    final h = host ?? const SystemHostPaths();
    final configured = env['HOME'];
    final home = configured != null && configured.isNotEmpty && p.isAbsolute(configured) ? p.normalize(configured) : '/tmp/home';

    final binds = <String>[];
    final symlinks = <String, String>{};
    final roots = <String>[];
    for (final d in systemRoots) {
      final target = h.linkTarget(d);
      if (target != null) {
        symlinks[d] = target;
        roots.add(d);
      } else if (h.exists(d)) {
        binds.add(d);
        roots.add(d);
      }
    }
    for (final f in etcEntries) {
      if (h.exists('/etc/$f')) binds.add('/etc/$f');
    }
    bool covered(String path) => roots.any((r) => path == r || p.isWithin(r, path));
    final skipped = <String, String>{};

    /// Why [real] must not be bound (null: it may be). The directories the
    /// sandbox replaces with an empty tmpfs, kernel state, and anything that
    /// would cover them are never bound; HOME is an empty tmpfs too, and only
    /// what was asked for explicitly may be bound back into it.
    String? refusal(String real, {required bool explicit}) {
      if (real == '/') return 'it is the whole root';
      for (final r in _volatileRoots) {
        if (real == r || p.isWithin(r, real)) return 'it is under $r, which the sandbox replaces with an empty tmpfs (or kernel state)';
        if (p.isWithin(real, r)) return 'it contains $r, which the sandbox replaces with an empty tmpfs (or kernel state)';
      }
      if (real == home || p.isWithin(real, home)) return 'it contains HOME, which is an empty tmpfs in the sandbox';
      if (p.isWithin(home, real) && !explicit) {
        return 'it is under HOME, which is an empty tmpfs in the sandbox (only the pub cache, FLUTTER_ROOT, --sandbox-ro and package roots are bound there)';
      }
      return null;
    }

    void need(String path, {bool explicit = false}) {
      if (!p.isAbsolute(path)) return;
      final given = p.normalize(path);
      if (!h.exists(given)) return;
      final real = h.realpath(given);
      if (real == null) return;
      if (covered(real)) {
        if (given != real && !covered(given)) symlinks[given] = real;
        return;
      }
      final why = refusal(real, explicit: explicit);
      if (why != null) {
        skipped[given] = given == real ? why : '$why ($given is $real)';
        return;
      }
      binds.add(real);
      if (given != real && !covered(given)) symlinks[given] = real;
    }

    final cache = env['PUB_CACHE'];
    need(cache != null && cache.isNotEmpty ? cache : p.join(home, '.pub-cache'), explicit: true);
    final flutterRoot = env['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) need(flutterRoot, explicit: true);
    final path = (env['PATH'] ?? '').split(':').where((e) => e.isNotEmpty).toList();
    for (final e in path) {
      need(e);
    }
    for (final r in packageRoots(exportPath)) {
      need(r, explicit: true);
    }
    for (final r in extraReadOnly) {
      need(r, explicit: true);
    }
    if (command.isNotEmpty) {
      final exe = command.first;
      final candidates = exe.contains('/') ? [exe] : [for (final e in path) p.join(e, exe)];
      for (final c in candidates) {
        if (!p.isAbsolute(c) || !h.exists(c)) continue;
        final real = h.realpath(c);
        if (real != null && !covered(real)) {
          // The SDK around bin/flutter, bin/dart: its scripts read their siblings.
          final dir = p.dirname(real);
          need(p.basename(dir) == 'bin' ? p.dirname(dir) : dir);
        }
        break;
      }
    }
    final bound = pruneNested(binds);
    // A read-only bind does not stop connect(2) on a Unix socket in it, nor an
    // open of a FIFO: nothing that holds one is bound. (The Nix store and /usr
    // are immutable system directories and are not scanned.)
    for (final b in bound) {
      if (b == '/nix/store' || p.isWithin('/nix/store', b) || b == '/usr' || p.isWithin('/usr', b)) continue;
      final special = h.specialFile(b);
      if (special != null) {
        throw SandboxUnavailable('$b would be bound into the sandbox but holds a Unix socket or FIFO ($special): a read-only '
            'bind does not stop connect(2), so a run could reach a host service through it. Remove it, or take $b off '
            'PATH / FLUTTER_ROOT / --sandbox-ro');
      }
    }
    return Sandbox(
        bwrap: bwrap, exportPath: exportPath, home: home, binds: bound, symlinks: symlinks, skipped: skipped);
  }

  /// Package roots outside [exportPath] named by `.dart_tool/package_config.json`
  /// (hosted packages in the pub cache, path dependencies elsewhere). Empty
  /// when there is no package config yet.
  static List<String> packageRoots(String exportPath) {
    final export = p.normalize(exportPath);
    return {
      for (final e in packageConfigEntries(exportPath))
        if (e.path != export && !p.isWithin(export, e.path)) e.path,
    }.toList()
      ..sort();
  }

  /// Runs a tiny command in a real sandbox and checks that it holds: bubblewrap
  /// is installed, user namespaces are allowed, and a write to the export, to
  /// `/tmp` and to `$HOME` is gone on the host afterwards. Throws
  /// [SandboxUnavailable] with the reason otherwise. Returns `bwrap --version`.
  static Future<String> probe({String bwrap = 'bwrap', Map<String, String>? environment, List<String> command = const []}) async {
    final String version;
    try {
      final v = await Process.run(bwrap, ['--version']);
      if (v.exitCode != 0) throw SandboxUnavailable('"$bwrap --version" failed (exit ${v.exitCode}): ${_first(v.stderr)}');
      version = '${v.stdout}'.trim();
    } on ProcessException catch (e) {
      throw SandboxUnavailable('bubblewrap ("$bwrap") cannot be run: ${e.message}. Install it, or pass '
          '--no-sandbox to run without isolation (every kill is then reported as unisolated)');
    }
    final dir = Directory.systemTemp.createTempSync('mutaudit_probe_');
    final mark = p.basename(dir.path);
    try {
      final export = dir.resolveSymbolicLinksSync();
      final sandbox = discover(export, environment: environment, bwrap: bwrap, command: command);
      final script = 'echo x > "\$PWD/probe-export" && echo x > "/tmp/$mark" && echo x > "\$HOME/$mark" && echo ok';
      final ProcessResult r;
      final argv = sandbox.wrap(['sh', '-c', script], workingDirectory: export);
      try {
        r = await Process.run(argv.first, argv.sublist(1), workingDirectory: export, environment: environment);
      } on ProcessException catch (e) {
        throw SandboxUnavailable('the probe sandbox could not be started: ${e.message}');
      }
      if (r.exitCode != 0 || (r.stdout as String).trim() != 'ok') {
        throw SandboxUnavailable('the probe sandbox did not run (exit ${r.exitCode}): ${_first(r.stderr)}. '
            'bubblewrap needs unprivileged user namespaces; pass --no-sandbox to run without isolation',
            output: _log(argv, r));
      }
      final leaked = [
        if (dir.listSync().isNotEmpty) 'the export',
        if (File('/tmp/$mark').existsSync()) '/tmp',
        if (File(p.join(sandbox.home, mark)).existsSync()) 'HOME',
      ];
      if (leaked.isNotEmpty) {
        File('/tmp/$mark').deleteSync(recursive: false);
        throw SandboxUnavailable('the probe sandbox let a write through to ${leaked.join(', ')}; refusing to rely on it');
      }
      if (command.isNotEmpty) await _probeToolchain(sandbox, export, command.first);
      return version;
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// The test command's program must run in the minimal root: `--version` for
  /// `flutter` and `dart`, else it must at least be found.
  static Future<void> _probeToolchain(Sandbox sandbox, String export, String program) async {
    final name = p.basename(program);
    final toolchain = name == 'flutter' || name == 'dart';
    final argv = sandbox.wrap(
        toolchain ? [program, '--version'] : ['sh', '-c', 'command -v "\$0" >/dev/null', program],
        workingDirectory: export);
    final ProcessResult r;
    try {
      r = await Process.run(argv.first, argv.sublist(1), workingDirectory: export)
          .timeout(const Duration(seconds: 120));
    } on ProcessException catch (e) {
      throw SandboxUnavailable('the probe sandbox could not be started: ${e.message}');
    } on TimeoutException {
      throw SandboxUnavailable('"$program --version" did not finish in the probe sandbox');
    }
    if (r.exitCode != 0) {
      throw SandboxUnavailable(
          '"$program"${toolchain ? ' --version' : ''} does not run in the minimal sandbox root '
          '(exit ${r.exitCode}: ${_first(r.stderr)}); what it needs from the host must be on PATH, in FLUTTER_ROOT '
          'or listed with --sandbox-ro. The binds were: ${sandbox.binds.join(', ')}',
          output: _log(argv, r));
    }
  }

  static String _log(List<String> argv, ProcessResult r) => renderRunLog(
      argv,
      ProcessOutcome(exitCode: r.exitCode, stdoutLines: const LineSplitter().convert('${r.stdout}'), stderr: '${r.stderr}'));

  static String _first(Object? text) {
    final t = '$text'.trim();
    return t.isEmpty ? 'no message' : t.split('\n').first;
  }
}

/// What the host looks like to [Sandbox.discover]: a seam so the bind list can
/// be tested without a particular machine.
abstract class HostPaths {
  bool exists(String path);

  /// The path with every symbolic link resolved, or null when it does not exist.
  String? realpath(String path);

  /// Where [path] points when it is a symbolic link itself, else null.
  String? linkTarget(String path);

  /// The first Unix socket or FIFO at or below [path] (not following links),
  /// or null when there is none.
  String? specialFile(String path);
}

/// The machine this process runs on.
class SystemHostPaths implements HostPaths {
  const SystemHostPaths();

  @override
  bool exists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound || FileSystemEntity.isLinkSync(path);

  @override
  String? realpath(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  String? specialFile(String path) {
    bool special(String x) {
      final type = FileSystemEntity.typeSync(x, followLinks: false);
      return type == FileSystemEntityType.unixDomainSock || type == FileSystemEntityType.pipe;
    }

    if (special(path)) return path;
    final stack = <String>[if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) path];
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = Directory(dir).listSync(followLinks: false);
      } on FileSystemException {
        continue; // unreadable here means unreadable in the sandbox too
      }
      for (final e in entries) {
        if (e is Link) continue;
        if (e is Directory) {
          stack.add(e.path);
        } else if (special(e.path)) {
          return e.path;
        }
      }
    }
    return null;
  }

  @override
  String? linkTarget(String path) {
    if (!FileSystemEntity.isLinkSync(path)) return null;
    try {
      return Link(path).targetSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// A [ProcessRunner] that runs every command inside [sandbox]. Timeouts and
/// cancellation are the inner runner's: it stops the bubblewrap process and
/// everything it can see below it; the PID namespace takes whatever is left.
class SandboxedProcessRunner implements ProcessRunner {
  SandboxedProcessRunner(this.inner, this.sandbox);
  final ProcessRunner inner;
  final Sandbox sandbox;

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
    RunObserver? observer,
  }) =>
      inner.run(sandbox.wrap(argv, workingDirectory: workingDirectory),
          workingDirectory: workingDirectory,
          timeout: timeout,
          environment: environment,
          cancel: cancel,
          observer: observer);
}
