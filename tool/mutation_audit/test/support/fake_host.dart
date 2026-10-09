import 'dart:async';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';

/// Virtual time for the process runner: alarms fire when [drive] advances the
/// clock, never because real time passed.
class VirtualClock {
  Duration now = Duration.zero;
  final List<_FakeAlarm> _alarms = [];

  /// Alarms the runner set and has neither seen fire nor cancelled.
  int get pending => _alarms.where((a) => !a.settled && !a.scripted).length;

  Alarm alarm(Duration after, {bool scripted = false}) {
    final a = _FakeAlarm(now + after, scripted);
    _alarms.add(a);
    return a;
  }

  /// Runs [work] to completion, advancing virtual time to the next alarm
  /// whenever everything else has gone quiet.
  Future<T> drive<T>(Future<T> work) async {
    var done = false;
    late T value;
    Object? error;
    StackTrace? trace;
    work.then((v) {
      value = v;
      done = true;
    }, onError: (Object e, StackTrace s) {
      error = e;
      trace = s;
      done = true;
    });
    while (!done) {
      for (var i = 0; i < 25 && !done; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (done) break;
      final due = _alarms.where((a) => !a.settled).toList()..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) throw StateError('deadlock: the work is pending and no alarm is set (at $now)');
      now = due.first.due;
      due.first.fire();
    }
    if (error != null) Error.throwWithStackTrace(error!, trace!);
    return value;
  }
}

class _FakeAlarm implements Alarm {
  _FakeAlarm(this.due, this.scripted);
  final Duration due;
  final bool scripted;
  final Completer<void> _c = Completer<void>();
  bool settled = false;

  @override
  Future<void> get fired => _c.future;

  void fire() {
    if (settled) return;
    settled = true;
    _c.complete();
  }

  @override
  void cancel() => settled = true;
}

/// One simulated process.
class FakeProc {
  FakeProc(this.pid, this.ppid, this.sid, {this.ignoresTerm = false, this.holdsOutput = false});
  final int pid;
  int ppid;
  final int sid;
  bool ignoresTerm;

  /// Keeps the child's stdout / stderr pipes open while alive.
  bool holdsOutput;
  bool alive = true;

  /// Cannot be killed at all (uninterruptible sleep).
  bool unkillable = false;
}

/// A [ProcessHost] over a table of simulated processes.
class FakeHost implements ProcessHost {
  FakeHost({this.ownsSession = true});

  final VirtualClock clock = VirtualClock();
  final Map<int, FakeProc> procs = {};
  final List<(int, ProcessSignal)> signals = [];
  final bool ownsSession;
  int _nextPid = 200;

  /// Runs right after the root is started; schedules what the processes do.
  void Function(FakeHost host)? script;

  /// Unrelated processes (never to be signalled) are added by the test.
  FakeProc bystander({int? pid, int? ppid, int? sid}) {
    final p = FakeProc(pid ?? _nextPid++, ppid ?? 1, sid ?? 1);
    procs[p.pid] = p;
    return p;
  }

  static const rootPid = 100;
  late FakeProc root;
  late final StreamController<List<int>> _out = StreamController<List<int>>();
  late final StreamController<List<int>> _err = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  bool _closed = false;
  List<String>? argv;
  int starts = 0;

  /// A new process forked by [parent] (default: the root).
  FakeProc spawn({int? parent, bool ignoresTerm = false, bool holdsOutput = false, int? sid}) {
    final p = FakeProc(_nextPid++, parent ?? rootPid, sid ?? (ownsSession ? rootPid : 1),
        ignoresTerm: ignoresTerm, holdsOutput: holdsOutput);
    procs[p.pid] = p;
    return p;
  }

  void print(String line) => _out.add('$line\n'.codeUnits);

  /// The root exits by itself.
  void rootExits(int code) {
    root.alive = false;
    if (!_exit.isCompleted) _exit.complete(code);
    _maybeClose();
    _orphan(root.pid);
  }

  /// [pid] exits by itself.
  void exits(int pid) => _die(pid, 0);

  /// Runs [action] when virtual time reaches [after].
  void at(Duration after, void Function() action) =>
      clock.alarm(after, scripted: true).fired.then((_) => action());

  void _orphan(int parent) {
    for (final p in procs.values) {
      if (p.alive && p.ppid == parent) p.ppid = 1;
    }
  }

  void _die(int pid, int signalCode) {
    final p = procs[pid];
    if (p == null || !p.alive) return;
    p.alive = false;
    if (pid == rootPid) {
      if (!_exit.isCompleted) _exit.complete(signalCode);
      _orphan(pid);
    }
    _maybeClose();
  }

  void _maybeClose() {
    if (_closed) return;
    final holders = procs.values.where((p) => p.alive && p.holdsOutput);
    if (holders.isEmpty) {
      _closed = true;
      _out.close();
      _err.close();
    }
  }

  @override
  Future<ChildProcess> start(List<String> argv,
      {required String workingDirectory, Map<String, String>? environment}) async {
    if (argv.first == 'missing') throw const ProcessException('missing', [], 'No such file');
    starts++;
    this.argv = argv;
    root = FakeProc(rootPid, 1, ownsSession ? rootPid : 1, holdsOutput: true);
    procs[rootPid] = root;
    script?.call(this);
    return _Child(this);
  }

  @override
  void signal(int pid, ProcessSignal signal) {
    signals.add((pid, signal));
    final p = procs[pid];
    if (p == null || !p.alive || p.unkillable) return;
    if (signal == ProcessSignal.sigterm && p.ignoresTerm) return;
    _die(pid, signal == ProcessSignal.sigkill ? -9 : -15);
  }

  @override
  Alarm alarm(Duration after) => clock.alarm(after);

  @override
  Future<Set<int>> family(int root, {required bool rootAlive, required bool ownsSession}) async {
    final members = <int>{};
    if (rootAlive && procs[root]?.alive == true) members.add(root);
    if (ownsSession) {
      for (final p in procs.values) {
        if (p.alive && p.sid == root) members.add(p.pid);
      }
    }
    var grew = true;
    while (grew) {
      grew = false;
      for (final p in procs.values) {
        if (p.alive && !members.contains(p.pid) && members.contains(p.ppid)) {
          members.add(p.pid);
          grew = true;
        }
      }
    }
    return members;
  }
}

class _Child implements ChildProcess {
  _Child(this.host);
  final FakeHost host;
  @override
  int get pid => FakeHost.rootPid;
  @override
  Stream<List<int>> get stdout => host._out.stream;
  @override
  Stream<List<int>> get stderr => host._err.stream;
  @override
  Future<int> get exitCode => host._exit.future;
  @override
  bool get ownsSession => host.ownsSession;
}
