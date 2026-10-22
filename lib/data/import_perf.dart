// Owner of import timing context. Only operational metadata belongs here.
import 'dart:io';
import '../sync/dev_log.dart';

class ImportPerf {
  static String latestRun = 'none';
  static final Map<String, int> _pages = {};

  static void start(String run) {
    latestRun = run;
    _pages[run] = 0;
  }

  static void page(String run) {
    if (_pages.containsKey(run)) _pages[run] = _pages[run]! + 1;
  }

  static int finish(String run) => _pages.remove(run) ?? 0;

  static void write(String run, String event, String fields) {
    DevLog.write(
      '[import-perf] $event run=$run $fields',
      source: 'import',
      always: true,
    );
  }

  static Future<int> walBytes(String path) async {
    try {
      return await File('$path-wal').length();
    } on FileSystemException {
      return 0;
    }
  }

  static void phase(String name, Stopwatch watch, {String? run}) {
    write(
      run ?? latestRun,
      'phase',
      'name=$name ms=${watch.elapsedMilliseconds}',
    );
    watch.reset();
  }
}
