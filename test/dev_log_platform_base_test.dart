// The dev log's default folder on a platform with no external storage (iOS).
//
// path_provider's getExternalStorageDirectory() does not return null there: it
// throws (documented as UnsupportedError; the platform interface's default,
// which path_provider_foundation does not override, throws UnimplementedError).
// DevLog's default base resolver is `getExternalStorageDirectory() ??
// getApplicationDocumentsDirectory()`, so the `??` fallback never runs, every
// line is dropped, and the export's legacyFiles() lets the same error escape so
// shareDevLog() returns false.
//
// The seam used is the real one: PathProviderPlatform.instance, with the
// untouched DevLog.instance (whose baseDir is the private platform resolver).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/dev_log.dart';
import 'package:openstrap_edge/sync/dev_log_export.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// iOS as path_provider_foundation exposes it: documents work, external
/// storage is not overridden, so the interface default throws.
class _IosPaths extends PathProviderPlatform {
  _IosPaths(this.docs, {this.externalError});
  final String docs;

  /// What getExternalStoragePath throws; null keeps the interface default.
  final Object? externalError;

  @override
  Future<String?> getExternalStoragePath() {
    final e = externalError;
    if (e != null) throw e;
    return super.getExternalStoragePath();
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
  @override
  Future<String?> getTemporaryPath() async => docs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs, out;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('devlog_ios_docs_');
    out = await Directory.systemTemp.createTemp('devlog_ios_out_');
  });
  tearDown(() async {
    for (final d in [docs, out]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  String allLogText() {
    final dir = Directory('${docs.path}/dev_log');
    if (!dir.existsSync()) return '';
    return [
      for (final f in dir.listSync().whereType<File>())
        f.readAsStringSync(),
    ].join();
  }

  for (final (label, error) in <(String, Object?)>[
    ('UnsupportedError (documented)', UnsupportedError('not on iOS')),
    ('the platform interface default (UnimplementedError)', null),
  ]) {
    test('an always-on line is written to the documents dir when external '
        'storage throws $label', () async {
      PathProviderPlatform.instance = _IosPaths(docs.path, externalError: error);
      await DevLog.write('[alarm] armed for 07:00', always: true)
          .timeout(const Duration(seconds: 5));
      await DevLog.instance.flush().timeout(const Duration(seconds: 5));
      expect(allLogText(), contains('[alarm] armed for 07:00'),
          reason: 'the documents-dir fallback must run when the external '
              'storage lookup throws instead of returning null');
    });
  }

  test('export still shares on a platform whose external storage throws',
      () async {
    PathProviderPlatform.instance = _IosPaths(docs.path,
        externalError: UnsupportedError('not on iOS'));
    final shared = <String>[];
    final ok = await shareDevLog(
      DevLog.instance,
      tempDir: out,
      now: DateTime(2026, 10, 6, 12, 7, 31),
      wakeTrace: () async => const [],
      share: (p) async => shared.add(p),
    ).timeout(const Duration(seconds: 10));
    expect(ok, isTrue,
        reason: 'legacyFiles() must not let the external-storage error '
            'escape and fail the whole export');
    expect(shared, hasLength(1));
  });
}
