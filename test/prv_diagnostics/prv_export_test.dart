// PRV diagnostics (design 04 R7 "PRV verdict export comes with the PRV
// diagnostics item", item h): the screen's verdict AND the evidence behind it
// leave the app as a LOG FILE through logFileName + saveLogFileResult (AGENTS
// invariant 16), never the clipboard. Mirrors the ECG export
// (lib/ecg/ecg_export.dart): `key: value` lines in a fixed order, a value the
// stored day does not hold prints `not recorded`, the clock is injected.
//
// The line contract below is the tests' choice (design question in the report);
// it is deliberately small and flat so a person can read it and a script can
// parse it.
//
//   OpenStrap PRV log
//   app_version / analytics_pin / protocol_pin / algo_version / exported_at
//   day: <local day label>
//
//   screen: sleep      (the stored clinical.irregular map)
//   <key: value lines>
//
//   screen: 24h        (the stored clinical.irregular_24h envelope)
//   <key: value lines>
//
// Both blocks are ALWAYS present: a day with no PRV data says so per key.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/compute/prv_export.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/util/log_file.dart';

import '../support/dart_source_lexical.dart';

final _header = PrvExportHeader(
  appVersion: '1.2.3+45',
  analyticsPin: 'a' * 40,
  protocolPin: 'b' * 40,
  algoVersion: 103,
  exportedAt: DateTime.utc(2026, 10, 8, 12, 30, 5),
);

Map<String, dynamic> _diag({
  String? abstain,
  int? rrRaw = 12345,
  int nnIn = 12124,
  int nnKept = 12100,
  int? corrected = 77,
  int? dropped = 221,
  double artifact = 0.0638,
  Map<String, dynamic>? windows = const {
    'total': 61,
    'valid': 55,
    'flagged': 17,
    'sustained_observed': 0.3091,
    'open_beats': 43,
    'open': 'thin',
  },
}) => {
  'version': 1,
  'abstain': abstain,
  'beats': {
    'rr_raw': rrRaw,
    'nn_in': nnIn,
    'nn_kept': nnKept,
    'corrected': corrected,
    'dropped': dropped,
    'artifact_fraction': artifact,
  },
  'windows': windows,
  'thresholds': {
    'min_beats': 500,
    'max_artifact': 0.3,
    'sd1sd2_flag': 0.7,
    'pnn_threshold_ms': 70.0,
    'pnn_flag_pct': 30.0,
    'window_minutes': 5.0,
    'min_window_beats': 40,
    'sustained_fraction': 0.5,
  },
};

Map<String, dynamic> _env24(
        {Map<String, dynamic>? diagnostics, bool present = true, bool flag = false}) =>
    {
      'value': present
          ? {
              'sd1_ms': 41.2,
              'sd2_ms': 55.3,
              'sd1_sd2': 0.75,
              'pnn_pct': 33.1,
              'n_beats': 12100,
              'flag': flag,
            }
          : '—',
      'confidence': present ? 0.62 : 0.0,
      'tier': 'ESTIMATE',
      'inputs_used': ['rr_cleaned'],
      'note': present ? 'irregular-rhythm SCREEN (not a diagnosis)' : 'too few clean beats for an irregular-rhythm screen',
      'diagnostics': ?diagnostics,
    };

Map<String, dynamic> _sleep(
        {Map<String, dynamic>? diagnostics, bool present = true, bool flag = true}) =>
    {
      'sd1': present ? 30.0 : null,
      'sd2': present ? 60.0 : null,
      'flag': present ? flag : null,
      'confidence': present ? 0.7 : 0.0,
      'note': present ? 'irregular-rhythm SCREEN (not a diagnosis)' : 'too few clean beats for an irregular-rhythm screen',
      if (present) 'pnn_pct': 41.7,
      if (present) 'n_beats': 3456,
      if (present) 'sd1_sd2': 0.5,
      'diagnostics': ?diagnostics,
    };

/// `key: value` lines of the block that starts at `screen: <name>`.
Map<String, String> _block(String log, String name) {
  final lines = log.split('\n');
  final start = lines.indexOf('screen: $name');
  expect(start, isNonNegative, reason: 'a `screen: $name` block');
  final out = <String, String>{};
  for (var i = start + 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim().isEmpty || l.startsWith('screen: ')) break;
    final c = l.indexOf(': ');
    expect(c, greaterThan(0), reason: 'a `key: value` line, got "$l"');
    out[l.substring(0, c)] = l.substring(c + 2);
  }
  return out;
}

String _log({Map<String, dynamic>? sleep, Map<String, dynamic>? day}) =>
    formatPrvLog(header: _header, day: '2026-10-07', sleep: sleep, screen24h: day);

const _screenKeys = [
  'flag',
  'abstain',
  'note',
  'sd1_ms',
  'sd2_ms',
  'sd1_sd2',
  'pnn_pct',
  'n_beats',
  'confidence',
  'rr_raw',
  'nn_in',
  'nn_kept',
  'corrected',
  'dropped',
  'artifact_fraction',
  'windows_total',
  'windows_valid',
  'windows_flagged',
  'sustained_observed',
  'sustained_required',
  'open_window',
  'open_window_beats',
  'min_beats',
  'max_artifact',
  'sd1sd2_flag',
  'pnn_threshold_ms',
  'pnn_flag_pct',
  'window_minutes',
  'min_window_beats',
];

void main() {
  group('formatPrvLog', () {
    test('header: versions, the injected export time, the day', () {
      final lines = _log().split('\n');
      expect(lines[0], 'OpenStrap PRV log');
      expect(lines[1], 'app_version: 1.2.3+45');
      expect(lines[2], 'analytics_pin: ${'a' * 40}');
      expect(lines[3], 'protocol_pin: ${'b' * 40}');
      expect(lines[4], 'algo_version: 103');
      expect(lines[5], 'exported_at: 2026-10-08T12:30:05Z');
      expect(lines[6], 'day: 2026-10-07');
    });

    test('a screen that ran: verdict, figures, beats, cleaning, windows, '
        'thresholds - every key, fixed order', () {
      final log = _log(
        sleep: _sleep(diagnostics: _diag(rrRaw: 4100, nnIn: 4067, nnKept: 3456)),
        day: _env24(diagnostics: _diag(), flag: false),
      );
      final d = _block(log, '24h');
      expect(d.keys.toList(), _screenKeys, reason: 'same keys, same order');
      expect(d['flag'], 'not flagged');
      expect(d['abstain'], 'none');
      expect(d['sd1_ms'], '41.2');
      expect(d['sd2_ms'], '55.3');
      expect(d['sd1_sd2'], '0.75');
      expect(d['pnn_pct'], '33.1');
      expect(d['n_beats'], '12100');
      expect(d['confidence'], '0.62');
      expect(d['rr_raw'], '12345');
      expect(d['nn_in'], '12124');
      expect(d['nn_kept'], '12100');
      expect(d['corrected'], '77');
      expect(d['dropped'], '221');
      expect(d['artifact_fraction'], '0.0638');
      expect(d['windows_total'], '61');
      expect(d['windows_valid'], '55');
      expect(d['windows_flagged'], '17');
      expect(d['sustained_observed'], '0.3091');
      expect(d['sustained_required'], '0.5');
      expect(d['open_window'], 'thin');
      expect(d['open_window_beats'], '43');
      expect(d['min_beats'], '500');
      expect(d['max_artifact'], '0.3');
      expect(d['min_window_beats'], '40');

      final s = _block(log, 'sleep');
      expect(s.keys.toList(), _screenKeys);
      expect(s['flag'], 'flagged');
      expect(s['sd1_ms'], '30.0', reason: 'sleep sd1 is stored as `sd1`');
      expect(s['pnn_pct'], '41.7', reason: 'sleep pNN, stored since this change');
      expect(s['n_beats'], '3456');
      expect(s['rr_raw'], '4100');
      expect(s['nn_kept'], '3456');
    });

    test('a screen that abstained: "not screened", the reason, the counts that '
        'caused it; figures it never produced are not 0', () {
      final log = _log(
        sleep: _sleep(present: false, diagnostics: _diag(abstain: 'artifact', artifact: 0.45)),
        day: _env24(
            present: false,
            diagnostics: _diag(abstain: 'too_few_beats', nnKept: 212, nnIn: 218)),
      );
      final d = _block(log, '24h');
      expect(d['flag'], 'not screened');
      expect(d['abstain'], 'too_few_beats');
      expect(d['nn_kept'], '212');
      expect(d['min_beats'], '500');
      expect(d['note'], 'too few clean beats for an irregular-rhythm screen',
          reason: 'the estimator\'s own words, verbatim');
      for (final k in ['sd1_ms', 'sd2_ms', 'sd1_sd2', 'pnn_pct', 'n_beats']) {
        expect(d[k], 'not recorded', reason: '$k was never computed: not 0');
      }
      final s = _block(log, 'sleep');
      expect(s['flag'], 'not screened');
      expect(s['abstain'], 'artifact');
      expect(s['artifact_fraction'], '0.45');
      expect(s['max_artifact'], '0.3');
    });

    test('a day stored before diagnostics existed: the old verdict, every new '
        'key "not recorded", nothing inferred or zeroed', () {
      final log = _log(
        sleep: {'sd1': 30.0, 'sd2': 60.0, 'flag': true, 'confidence': 0.7},
        day: {
          'value': {
            'sd1_ms': 41.2,
            'sd2_ms': 55.3,
            'sd1_sd2': 0.75,
            'pnn_pct': 33.1,
            'n_beats': 12100,
            'flag': true,
          },
          'confidence': 0.62,
          'tier': 'ESTIMATE',
          'inputs_used': ['rr_cleaned'],
        },
      );
      final d = _block(log, '24h');
      expect(d['flag'], 'flagged');
      expect(d['sd1_ms'], '41.2');
      for (final k in [
        'abstain', 'rr_raw', 'nn_in', 'nn_kept', 'corrected', 'dropped',
        'artifact_fraction', 'windows_total', 'windows_valid', 'windows_flagged',
        'sustained_observed', 'sustained_required', 'open_window',
        'open_window_beats', 'min_beats', 'max_artifact', 'note',
      ]) {
        expect(d[k], 'not recorded', reason: k);
      }
      final s = _block(log, 'sleep');
      expect(s['flag'], 'flagged');
      expect(s['pnn_pct'], 'not recorded');
      expect(s['n_beats'], 'not recorded');
    });

    test('no PRV data at all: both blocks present, every key not recorded, the '
        'verdict "not screened"', () {
      final log = _log();
      for (final name in ['sleep', '24h']) {
        final b = _block(log, name);
        expect(b.keys.toList(), _screenKeys);
        expect(b['flag'], 'not screened');
        for (final e in b.entries.where((e) => e.key != 'flag')) {
          expect(e.value, 'not recorded', reason: '$name ${e.key}');
        }
      }
    });

    test('counts that were never measured are not zeros (rr_raw null, windows '
        'null)', () {
      final log = _log(
          day: _env24(
              diagnostics: _diag(rrRaw: null, corrected: null, dropped: null, windows: null)));
      final d = _block(log, '24h');
      for (final k in [
        'rr_raw', 'corrected', 'dropped', 'windows_total', 'windows_valid',
        'windows_flagged', 'sustained_observed', 'open_window', 'open_window_beats'
      ]) {
        expect(d[k], 'not recorded', reason: k);
      }
      expect(d['nn_kept'], '12100');
    });

    test('a real zero is printed as 0 (no voting window is a fact)', () {
      final log = _log(
          day: _env24(
              diagnostics: _diag(windows: const {
        'total': 2,
        'valid': 0,
        'flagged': 0,
        'sustained_observed': null,
        'open_beats': 9,
        'open': 'thin',
      })));
      final d = _block(log, '24h');
      expect(d['windows_valid'], '0');
      expect(d['windows_flagged'], '0');
      expect(d['sustained_observed'], 'not recorded');
    });

    test('pure and deterministic; the export time is the header\'s', () {
      final a = _log(sleep: _sleep(diagnostics: _diag()), day: _env24(diagnostics: _diag()));
      final b = _log(sleep: _sleep(diagnostics: _diag()), day: _env24(diagnostics: _diag()));
      expect(a, b);
      expect(a, contains('exported_at: 2026-10-08T12:30:05Z'));
    });

    test('no verdict-flavoured wording the app refuses elsewhere', () {
      final log = _log(sleep: _sleep(diagnostics: _diag()), day: _env24(diagnostics: _diag()));
      expect(RegExp(r'\b(normal|healthy|clear|clean|good)\b', caseSensitive: false).hasMatch(log),
          isFalse);
    });
  });

  group('exportPrvLog', () {
    Future<LogSaveResult> run(PrvLogSaver? save) =>
        exportPrvLog(
          env: PrvExportEnv(
            appVersion: () async => '1.2.3+45',
            now: () => DateTime.utc(2026, 10, 8, 12, 30, 5),
            save: save,
          ),
          analyticsPin: 'a' * 40,
          protocolPin: 'b' * 40,
          algoVersion: 103,
          day: '2026-10-07',
          sleep: _sleep(diagnostics: _diag()),
          screen24h: _env24(diagnostics: _diag()),
        );

    test('saves ONE file named by logFileName with the formatted text', () async {
      final calls = <(String, String)>[];
      final r = await run((name, text) async {
        calls.add((name, text));
        return const LogSaveOk();
      });
      expect(r, isA<LogSaveOk>());
      expect(calls, hasLength(1));
      expect(calls.single.$1, logFileName('prv', DateTime.utc(2026, 10, 8, 12, 30, 5)));
      expect(calls.single.$1, startsWith('openstrap-prv-log-'));
      expect(calls.single.$2,
          formatPrvLog(
            header: _header,
            day: '2026-10-07',
            sleep: _sleep(diagnostics: _diag()),
            screen24h: _env24(diagnostics: _diag()),
          ));
    });

    test('a failed save is returned with its reason, not thrown', () async {
      final r = await run((n, t) async => const LogSaveFailed('disk full'));
      expect(r, isA<LogSaveFailed>());
      expect((r as LogSaveFailed).reason, 'disk full');
    });

    test('a saver that throws is a failure with the error\'s text, not a throw',
        () async {
      final r = await run((n, t) async => throw StateError('share sheet gone'));
      expect(r, isA<LogSaveFailed>());
      expect((r as LogSaveFailed).reason, contains('share sheet gone'));
    });
  });

  group('source guard (invariant 16)', () {
    test('prv_export.dart saves through the log-file path and never touches '
        'the clipboard', () {
      final src = codeOnly(File('lib/compute/prv_export.dart').readAsStringSync());
      expect(src.contains('Clipboard'), isFalse);
      expect(src, contains('logFileName'));
      expect(src, contains('saveLogFileResult'));
    });
  });

  group('the Nerd stats control', () {
    Future<void> pump(WidgetTester t, PrvExportEnv env) async {
      t.view.physicalSize = const Size(390 * 3, 12000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Investigate(
          'hrv',
          prvExport: env,
          data: InvestigateData(
            day: '2026-10-07',
            heart: {
              'irregular': _sleep(diagnostics: _diag()),
              'irregular_24h': _env24(diagnostics: _diag()),
            },
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('tapping Export PRV log saves the log file for the day shown, '
        'with the injected clock, and never writes the clipboard', (t) async {
      final clipboard = <MethodCall>[];
      t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('Clipboard')) clipboard.add(call);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final saved = <(String, String)>[];
      await pump(
        t,
        PrvExportEnv(
          appVersion: () async => '9.9.9',
          now: () => DateTime.utc(2026, 10, 8, 12, 30, 5),
          save: (n, text) async {
            saved.add((n, text));
            return const LogSaveOk();
          },
        ),
      );
      final button = find.byKey(const ValueKey('prv-log-export'));
      expect(button, findsOneWidget);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.$1, logFileName('prv', DateTime.utc(2026, 10, 8, 12, 30, 5)));
      final text = saved.single.$2;
      expect(text, startsWith('OpenStrap PRV log'));
      expect(text, contains('app_version: 9.9.9'));
      expect(text, contains('day: 2026-10-07'));
      expect(text, contains('algo_version: $kAlgoVersion'));
      expect(text, contains('rr_raw: 12345'));
      expect(clipboard, isEmpty);
    });

    testWidgets('a failed save is said on screen, with its reason', (t) async {
      await pump(
        t,
        PrvExportEnv(
          appVersion: () async => '9.9.9',
          now: () => DateTime.utc(2026, 10, 8, 12, 30, 5),
          save: (n, text) async => const LogSaveFailed('disk full'),
        ),
      );
      await t.tap(find.byKey(const ValueKey('prv-log-export')));
      await t.pumpAndSettle();
      expect(find.textContaining('disk full'), findsOneWidget);
    });
  });
}
