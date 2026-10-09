import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_runner.dart';

/// bubblewrap is missing, or a probe sandbox does not behave (no unprivileged
/// user namespaces, an overlay that keeps writes). The audit cannot isolate
/// its runs: it stops unless `--no-sandbox` was given.
class SandboxUnavailable implements Exception {
  SandboxUnavailable(this.message);
  final String message;
  @override
  String toString() => 'SandboxUnavailable: $message';
}

/// The bubblewrap command line for one test run.
///
/// Why bubblewrap and not "put the files back afterwards": a test run can
/// leave state in places no restore knows about (a cache directory, `$HOME`,
/// a fixed path under `/tmp`, a socket, a process). Here the run never has a
/// writable view of any of them:
///
/// - the whole host is `--ro-bind / /`: the developer checkout, the out
///   directory, the sibling repositories and the SDKs cannot be written;
/// - the export is an overlay (`--overlay-src` + `--tmp-overlay`): the run
///   sees the export with the mutant already applied on the host, and every
///   write it makes lands in memory and disappears with the sandbox;
/// - `/tmp`, `/var/tmp`, `$HOME` and the desktop session's runtime directory
///   are fresh tmpfs mounts; only what the toolchain must READ under `$HOME`
///   (the pub cache, SDKs on `PATH`, packages the package config names) is
///   bound back, read-only;
/// - new PID namespace: when the sandbox's init exits the kernel kills every
///   process left in it, a TERM-ignoring grandchild included;
/// - new IPC and network namespaces (loopback only: `flutter_tester` talks to
///   the VM service over it; nothing else is reachable).
class Sandbox {
  Sandbox({
    this.bwrap = 'bwrap',
    required this.exportPath,
    required this.home,
    this.readOnly = const [],
    this.runtimeDir,
    this.unshareNet = true,
    this.tmpDirs = const ['/tmp', '/var/tmp'],
  });

  final String bwrap;
  final String exportPath;

  /// `$HOME` inside the sandbox: an empty tmpfs (plus [readOnly] paths under it).
  final String home;

  /// Paths the toolchain must read. Only those under [home] are bound (the
  /// rest of the host is visible read-only anyway); the order does not matter.
  final List<String> readOnly;

  /// Where the desktop session keeps its sockets; hidden when set.
  final String? runtimeDir;
  final bool unshareNet;

  /// Directories replaced by an empty tmpfs (they must exist on the host).
  final List<String> tmpDirs;

  /// Where the XDG base directories go: inside the `/tmp` tmpfs.
  static const _xdgRoot = '/tmp/xdg';

  /// The argv that runs [argv] in the sandbox, in [workingDirectory].
  List<String> wrap(List<String> argv, {required String workingDirectory}) {
    final binds = _homeBinds();
    final xdg = {
      'XDG_CACHE_HOME': '$_xdgRoot/cache',
      'XDG_CONFIG_HOME': '$_xdgRoot/config',
      'XDG_DATA_HOME': '$_xdgRoot/data',
      'XDG_STATE_HOME': '$_xdgRoot/state',
    };
    final runtime = runtimeDir;
    final env = <String, String>{
      'HOME': home,
      ...xdg,
      if (runtime != null) 'XDG_RUNTIME_DIR': runtime,
      'TMPDIR': '/tmp',
      'TMP': '/tmp',
      'TEMP': '/tmp',
      // Fresh HOME: the first-run banner would go to stdout, in the JSON stream.
      'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      'DART_SUPPRESS_ANALYTICS': 'true',
    };
    return [
      bwrap,
      '--ro-bind', '/', '/',
      '--dev', '/dev',
      '--proc', '/proc',
      '--unshare-pid',
      '--unshare-ipc',
      if (unshareNet) '--unshare-net',
      '--die-with-parent',
      '--new-session',
      for (final t in tmpDirs) ...['--tmpfs', t],
      '--tmpfs', home,
      if (runtime != null) ...['--tmpfs', runtime],
      for (final b in binds) ...['--ro-bind', b, b],
      for (final d in xdg.values) ...['--dir', d],
      // Last among the mounts: the export may live under /tmp or HOME, which
      // the tmpfs mounts above replaced.
      '--overlay-src', exportPath, '--tmp-overlay', exportPath,
      for (final e in env.entries) ...['--setenv', e.key, e.value],
      '--chdir', workingDirectory,
      '--',
      ...argv,
    ];
  }

  /// [readOnly] under [home], normalised, without duplicates and without paths
  /// inside another bound path, parents first.
  List<String> _homeBinds() => pruneNested([
        for (final r in readOnly)
          if (p.isAbsolute(r) && p.isWithin(p.normalize(home), p.normalize(r))) p.normalize(r),
      ]);

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

  /// A sandbox for [exportPath] with what the toolchain on this machine needs
  /// to read under `$HOME`: the pub cache (`PUB_CACHE`, else `~/.pub-cache`),
  /// `FLUTTER_ROOT`, every `PATH` entry, the roots the export's package config
  /// names, and [extraReadOnly]. [exists] answers whether a host path exists
  /// (a seam for tests; default: the file system); what is missing is left out
  /// because bubblewrap cannot mount it.
  static Sandbox discover(
    String exportPath, {
    Map<String, String>? environment,
    List<String> extraReadOnly = const [],
    String bwrap = 'bwrap',
    bool Function(String path)? exists,
  }) {
    final env = environment ?? Platform.environment;
    bool there(String path) =>
        exists != null ? exists(path) : FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    final configured = env['HOME'];
    final home = configured != null && configured.isNotEmpty && p.isAbsolute(configured) && there(configured)
        ? p.normalize(configured)
        : '/tmp/home';
    final cache = env['PUB_CACHE'];
    final candidates = <String>[
      if (cache != null && cache.isNotEmpty) cache else p.join(home, '.pub-cache'),
      if ((env['FLUTTER_ROOT'] ?? '').isNotEmpty) env['FLUTTER_ROOT']!,
      for (final e in (env['PATH'] ?? '').split(':')) if (e.isNotEmpty) e,
      ...packageRoots(exportPath),
      ...extraReadOnly,
    ];
    final runtime = env['XDG_RUNTIME_DIR'];
    return Sandbox(
      bwrap: bwrap,
      exportPath: exportPath,
      home: home,
      readOnly: pruneNested([
        for (final c in candidates)
          if (p.isAbsolute(c) && p.isWithin(home, p.normalize(c)) && there(c)) p.normalize(c)
      ]),
      runtimeDir: runtime != null && runtime.isNotEmpty && p.isAbsolute(runtime) && there(runtime) ? runtime : null,
      tmpDirs: [for (final t in const ['/tmp', '/var/tmp']) if (t == '/tmp' || there(t)) t],
    );
  }

  /// Package roots outside [exportPath] named by `.dart_tool/package_config.json`
  /// (hosted packages in the pub cache, path dependencies elsewhere). Empty
  /// when there is no package config yet.
  static List<String> packageRoots(String exportPath) {
    final file = File(p.join(exportPath, '.dart_tool', 'package_config.json'));
    if (!file.existsSync()) return const [];
    final Object? doc;
    try {
      doc = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return const [];
    }
    final packages = doc is Map ? doc['packages'] : null;
    if (packages is! List) return const [];
    final base = Uri.directory(p.join(exportPath, '.dart_tool'));
    final out = <String>{};
    for (final pkg in packages) {
      final root = pkg is Map ? pkg['rootUri'] : null;
      if (root is! String) continue;
      final Uri uri;
      try {
        uri = base.resolve(root);
      } on FormatException {
        continue;
      }
      if (uri.scheme != 'file') continue;
      final path = p.normalize(uri.toFilePath());
      if (path == p.normalize(exportPath) || p.isWithin(p.normalize(exportPath), path)) continue;
      out.add(path);
    }
    return out.toList()..sort();
  }

  /// Runs a tiny command in a real sandbox and checks that it holds: bubblewrap
  /// is installed, user namespaces are allowed, and a write to the export, to
  /// `/tmp` and to `$HOME` is gone on the host afterwards. Throws
  /// [SandboxUnavailable] with the reason otherwise.
  static Future<void> probe({String bwrap = 'bwrap', Map<String, String>? environment}) async {
    try {
      final v = await Process.run(bwrap, ['--version']);
      if (v.exitCode != 0) throw SandboxUnavailable('"$bwrap --version" failed (exit ${v.exitCode}): ${_first(v.stderr)}');
    } on ProcessException catch (e) {
      throw SandboxUnavailable('bubblewrap ("$bwrap") cannot be run: ${e.message}. Install it, or pass '
          '--no-sandbox to run without isolation (every kill is then reported as unisolated)');
    }
    final dir = Directory.systemTemp.createTempSync('mutaudit_probe_');
    final mark = p.basename(dir.path);
    try {
      final export = dir.resolveSymbolicLinksSync();
      final sandbox = discover(export, environment: environment, bwrap: bwrap);
      final script = 'echo x > "\$PWD/probe-export" && echo x > "/tmp/$mark" && echo x > "\$HOME/$mark" && echo ok';
      final ProcessResult r;
      try {
        final argv = sandbox.wrap(['sh', '-c', script], workingDirectory: export);
        r = await Process.run(argv.first, argv.sublist(1), workingDirectory: export, environment: environment);
      } on ProcessException catch (e) {
        throw SandboxUnavailable('the probe sandbox could not be started: ${e.message}');
      }
      if (r.exitCode != 0 || (r.stdout as String).trim() != 'ok') {
        throw SandboxUnavailable('the probe sandbox did not run (exit ${r.exitCode}): ${_first(r.stderr)}. '
            'bubblewrap needs unprivileged user namespaces; pass --no-sandbox to run without isolation');
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
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  static String _first(Object? text) {
    final t = '$text'.trim();
    return t.isEmpty ? 'no message' : t.split('\n').first;
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
  }) =>
      inner.run(sandbox.wrap(argv, workingDirectory: workingDirectory),
          workingDirectory: workingDirectory, timeout: timeout, environment: environment, cancel: cancel);
}
