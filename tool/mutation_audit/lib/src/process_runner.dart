import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A request to stop: Ctrl-C / SIGTERM. Threaded from the signal handler
/// through the audit loop and the process runner, so that whoever started a
/// child process is the one that stops it (and waits for it to be gone).
class CancelToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called (never, otherwise).
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// What one command run produced.
class ProcessOutcome {
  const ProcessOutcome({
    required this.exitCode,
    this.stdoutLines = const [],
    this.stderr = '',
    this.timedOut = false,
    this.cancelled = false,
    this.outputComplete = true,
    this.elapsed = Duration.zero,
  });

  final int exitCode;
  final List<String> stdoutLines;
  final String stderr;

  /// The run was stopped because it exceeded its timeout. The timeout bounds
  /// the whole run: the process exiting AND both output streams closing.
  final bool timedOut;

  /// The run was stopped because the audit was cancelled (Ctrl-C).
  final bool cancelled;

  /// Both output streams were read to their end. False when the runner had to
  /// stop waiting for them (a surviving process still held them open), so
  /// [stdoutLines] may be cut short.
  final bool outputComplete;
  final Duration elapsed;
}

/// Runs a command to completion. The real one spawns a process; tests inject a
/// fake. The runner owns the timeout (the tool never reads the real clock).
abstract class ProcessRunner {
  /// Runs [argv] in [workingDirectory]. Stops it (and everything it started)
  /// when [timeout] passes -- counted until the process has exited AND its
  /// output has closed -- or when [cancel] is cancelled, and says which in
  /// the outcome. Returns only once the stopped processes are gone (or could
  /// not be killed: then [ProcessOutcome.outputComplete] is false).
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
  });
}

/// A timer the runner can drop: a pending real timer would keep the process
/// alive after the work is done.
abstract class Alarm {
  /// Completes when the time has passed (never, once cancelled).
  Future<void> get fired;
  void cancel();
}

/// A started child process.
abstract class ChildProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  /// Started in a session of its own, so that [ProcessHost.family] can find
  /// processes that were reparented (a wrapper that exited, leaving a child).
  bool get ownsSession;
}

/// Everything the runner needs from the operating system. Faked in tests.
abstract class ProcessHost {
  /// Throws [ProcessException] when the program cannot be started.
  Future<ChildProcess> start(
    List<String> argv, {
    required String workingDirectory,
    Map<String, String>? environment,
  });

  /// Live processes that belong to [root]: itself while [rootAlive], its
  /// descendants, and (when [ownsSession]) every process of its session, even
  /// reparented ones. Only these are ever signalled: no negative pids, no
  /// name matching, nothing that is not in the root's tree or session.
  Future<Set<int>> family(int root, {required bool rootAlive, required bool ownsSession});

  void signal(int pid, ProcessSignal signal);
  Alarm alarm(Duration after);
}

/// Spawns real processes (the only place the tool touches real time).
///
/// The child is started under `setsid` when that exists, so it leads a session
/// of its own and everything it starts (reparented or not) can be found by
/// session id. On a timeout or a cancel, the family is collected FIRST (before
/// any signal can make processes reparent), every member gets SIGTERM, those
/// still there after [termGrace] get SIGKILL (rescanned a few times for
/// processes forked meanwhile), and then the streams get at most [drainGrace]
/// to close before the runner stops waiting for them.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner({
    this.host = const SystemProcessHost(),
    this.termGrace = const Duration(seconds: 5),
    this.drainGrace = const Duration(seconds: 2),
    this.pollEvery = const Duration(milliseconds: 100),
  });

  final ProcessHost host;

  /// How long SIGTERM gets before SIGKILL.
  final Duration termGrace;

  /// How long to wait for the output streams to close after the kill.
  final Duration drainGrace;

  final Duration pollEvery;

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
  }) async {
    final clock = Stopwatch()..start();
    if (cancel != null && cancel.isCancelled) {
      return ProcessOutcome(exitCode: -15, cancelled: true, elapsed: clock.elapsed);
    }
    final ChildProcess child;
    try {
      child = await host.start(argv, workingDirectory: workingDirectory, environment: environment);
    } on ProcessException catch (e) {
      return ProcessOutcome(exitCode: 127, stderr: e.toString(), elapsed: clock.elapsed);
    }

    final stdout = _Collector(child.stdout);
    final stderr = _Collector(child.stderr);
    var exited = false;
    final exit = child.exitCode.then((code) {
      exited = true;
      return code;
    });
    final finished = Future.wait<Object?>([exit, stdout.closed, stderr.closed]);
    final deadline = timeout == null ? null : host.alarm(timeout);

    // Whole-run bound: the process AND its streams.
    final winner = await Future.any<_Ended>([
      finished.then((_) => _Ended.finished),
      if (deadline != null) deadline.fired.then((_) => _Ended.timeout),
      if (cancel != null) cancel.whenCancelled.then((_) => _Ended.cancelled),
    ]);
    deadline?.cancel();

    if (winner == _Ended.finished) {
      return ProcessOutcome(
        exitCode: await exit,
        stdoutLines: stdout.lines(),
        stderr: stderr.text(),
        elapsed: clock.elapsed,
      );
    }

    await _stop(child, rootAlive: () => !exited);
    // The root is gone (or unkillable); the streams get a bounded time to close.
    final code = await _withinDrain(exit) ?? -9;
    await _withinDrain(Future.wait<Object?>([stdout.closed, stderr.closed]));
    final complete = stdout.isClosed && stderr.isClosed;
    await stdout.stop();
    await stderr.stop();
    return ProcessOutcome(
      exitCode: code,
      stdoutLines: stdout.lines(),
      stderr: stderr.text(),
      timedOut: winner == _Ended.timeout,
      cancelled: winner == _Ended.cancelled,
      outputComplete: complete,
      elapsed: clock.elapsed,
    );
  }

  /// [work]'s value, or null when [drainGrace] passes first.
  Future<T?> _withinDrain<T>(Future<T> work) async {
    final alarm = host.alarm(drainGrace);
    try {
      return await Future.any<T?>([work, alarm.fired.then((_) => null)]);
    } finally {
      alarm.cancel();
    }
  }

  /// SIGTERM the family, give it [termGrace], SIGKILL what is left.
  Future<void> _stop(ChildProcess child, {required bool Function() rootAlive}) async {
    Future<Set<int>> family() =>
        host.family(child.pid, rootAlive: rootAlive(), ownsSession: child.ownsSession);

    for (final pid in (await family()).toList().reversed) {
      host.signal(pid, ProcessSignal.sigterm);
    }
    final grace = host.alarm(termGrace);
    var graceOver = false;
    unawaited(grace.fired.then((_) => graceOver = true));
    try {
      while (!graceOver) {
        if ((await family()).isEmpty) return;
        final tick = host.alarm(pollEvery);
        await Future.any<void>([tick.fired, grace.fired]);
        tick.cancel();
      }
    } finally {
      grace.cancel();
    }
    // Survivors ignored SIGTERM. Rescan: something may have forked since.
    for (var round = 0; round < 5; round++) {
      final left = await family();
      if (left.isEmpty) return;
      for (final pid in left) {
        host.signal(pid, ProcessSignal.sigkill);
      }
      final tick = host.alarm(pollEvery);
      await tick.fired;
    }
  }
}

enum _Ended { finished, timeout, cancelled }

/// Reads one stream into memory and can stop reading at any time.
class _Collector {
  _Collector(Stream<List<int>> source) {
    _subscription = source.listen(
      _bytes.add,
      onDone: _close,
      onError: (Object _) => _close(),
      cancelOnError: true,
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<void> get closed => _done.future;
  bool get isClosed => _done.isCompleted;

  void _close() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Stops listening (a surviving process may still hold the pipe).
  Future<void> stop() => _subscription.cancel();

  String text() => utf8.decode(_bytes.toBytes(), allowMalformed: true);
  List<String> lines() => const LineSplitter().convert(text());
}

/// The real thing: `Process.start`, `/proc` (or `pgrep -P`), `kill`.
class SystemProcessHost implements ProcessHost {
  const SystemProcessHost();

  static bool? _setsid;

  /// util-linux `setsid` exists (Linux; macOS has none: then only descendants
  /// of the child can be found).
  static bool get hasSetsid => _setsid ??= () {
        try {
          return Process.runSync('setsid', ['--version']).exitCode == 0;
        } on ProcessException {
          return false;
        }
      }();

  @override
  Future<ChildProcess> start(
    List<String> argv, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final session = hasSetsid;
    final process = await Process.start(
      session ? 'setsid' : argv.first,
      session ? ['-w', ...argv] : argv.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return _RealChild(process, session);
  }

  @override
  void signal(int pid, ProcessSignal signal) {
    // Positive pids only: a pid from this runner's own family scan.
    if (pid > 1) Process.killPid(pid, signal);
  }

  @override
  Alarm alarm(Duration after) => _TimerAlarm(after);

  @override
  Future<Set<int>> family(int root, {required bool rootAlive, required bool ownsSession}) async {
    final table = await _processTable();
    final members = <int>{};
    // The root's pid may have been reused once it exited and was reaped:
    // it is only a member while it is known to be alive.
    if (rootAlive && table.containsKey(root)) members.add(root);
    if (ownsSession) {
      for (final e in table.entries) {
        if (e.value.sid == root) members.add(e.key);
      }
    }
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in table.entries) {
        if (!members.contains(e.key) && members.contains(e.value.ppid)) {
          members.add(e.key);
          grew = true;
        }
      }
    }
    return members;
  }

  /// pid -> parent and session of every live (non-zombie) process.
  Future<Map<int, _Entry>> _processTable() async {
    if (Directory('/proc/self').existsSync()) {
      final table = <int, _Entry>{};
      for (final entity in Directory('/proc').listSync(followLinks: false)) {
        final pid = int.tryParse(entity.path.substring(entity.path.lastIndexOf('/') + 1));
        if (pid == null) continue;
        try {
          final stat = File('${entity.path}/stat').readAsStringSync();
          // "pid (comm) S ppid pgrp session ..." and comm may hold spaces and parens.
          final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
          if (rest[0] == 'Z' || rest[0] == 'X') continue;
          table[pid] = _Entry(int.parse(rest[1]), int.parse(rest[3]));
        } on FileSystemException {
          continue; // exited meanwhile
        }
      }
      return table;
    }
    // No /proc: the whole table from ps (pid, ppid; the session is unknown).
    try {
      final r = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,stat=']);
      final table = <int, _Entry>{};
      for (final line in LineSplitter.split(r.stdout as String)) {
        final f = line.trim().split(RegExp(r'\s+'));
        if (f.length < 3 || f[2].startsWith('Z')) continue;
        final pid = int.tryParse(f[0]), ppid = int.tryParse(f[1]);
        if (pid != null && ppid != null) table[pid] = _Entry(ppid, -1);
      }
      return table;
    } on ProcessException {
      return {};
    }
  }
}

class _Entry {
  const _Entry(this.ppid, this.sid);
  final int ppid, sid;
}

class _RealChild implements ChildProcess {
  _RealChild(this._process, this.ownsSession);
  final Process _process;

  @override
  final bool ownsSession;
  @override
  int get pid => _process.pid;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  Future<int> get exitCode => _process.exitCode;
}

class _TimerAlarm implements Alarm {
  _TimerAlarm(Duration after) {
    _timer = Timer(after, _completer.complete);
  }
  final Completer<void> _completer = Completer<void>();
  late final Timer _timer;

  @override
  Future<void> get fired => _completer.future;
  @override
  void cancel() => _timer.cancel();
}
