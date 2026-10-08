// ECG features, phase 1 (RED): the ACTIVE page and the RESULT pages show real
// metric names and values ("Average heart rate 77 bpm"), "—" when a value is
// absent, never a zero, and only show live values as they become available.
//
// Metrics that exist: average heart rate and the band's signal quality. There
// is no RMSSD or SDNN from an ECG (see ecg_result_policy_test.dart); the
// generic list is tested with an RMSSD row only to pin that a name and value
// come from DATA, so an R-peak metric added in analytics later shows up
// without a UI change.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_result.dart';
import 'package:openstrap_edge/ecg/ecg_waveform_buffer.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/ecg_fixtures.dart';

Future<void> _pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1170, 4000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await t.pump();
}

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

Widget _body(EcgCaptureState s) => Scaffold(
  body: EcgCaptureBody(
    state: s,
    wrist: EcgWrist.right,
    phase: 0.25,
    live: EcgWaveformBuffer(capacity: 100),
    scheduler: EcgPreviewScheduler(),
    onRetry: () {},
    onTakeAnother: () {},
    onDone: () {},
    onView: () {},
  ),
);

Finder _row(String key) => find.byKey(ValueKey('ecg-metric:$key'));

String _rowText(WidgetTester t, String key) => t
    .widgetList<Text>(
      find.descendant(of: _row(key), matching: find.byType(Text)),
    )
    .map((w) => w.data ?? '')
    .join(' ');

const _hr = EcgMetric(
  key: 'avgHr',
  name: 'Average heart rate',
  value: 77,
  unit: 'bpm',
);
const _q = EcgMetric(key: 'quality', name: 'Signal quality', value: 2, unit: '');
const _rmssd = EcgMetric(key: 'rmssd', name: 'RMSSD', value: 42, unit: 'ms');
const _rmssdNone = EcgMetric(key: 'rmssd', name: 'RMSSD', value: null, unit: 'ms');

void main() {
  group('EcgMetricsList', () {
    testWidgets('one keyed row per metric: its real name and its value with '
        'the unit', (t) async {
      await _pump(
        t,
        const Scaffold(body: EcgMetricsList(metrics: [_hr, _q, _rmssd])),
      );
      expect(_rowText(t, 'avgHr'), allOf(contains('Average heart rate'), contains('77 bpm')));
      expect(_rowText(t, 'quality'), allOf(contains('Signal quality'), contains('2')));
      expect(_rowText(t, 'rmssd'), allOf(contains('RMSSD'), contains('42 ms')));
    });

    testWidgets('an absent value is "—", never zero, and the name stays',
        (t) async {
      await _pump(
        t,
        const Scaffold(body: EcgMetricsList(metrics: [_rmssdNone])),
      );
      final text = _rowText(t, 'rmssd');
      expect(text, contains('RMSSD'));
      expect(text, contains('—'));
      expect(text, isNot(contains('0')));
      expect(text, isNot(contains('ms')), reason: 'no unit on a missing value');
    });

    testWidgets('no metrics, no rows (it does not invent any)', (t) async {
      await _pump(t, const Scaffold(body: EcgMetricsList(metrics: [])));
      expect(find.byWidgetPredicate((w) =>
          w.key is ValueKey &&
          '${(w.key as ValueKey).value}'.startsWith('ecg-metric:')), findsNothing);
    });
  });

  group('the active page shows live values only as they become available', () {
    testWidgets('while measuring with a live heart rate and a quality: both '
        'appear, named', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.active,
          progress: 40,
          liveHr: 71,
          quality: 2,
        )),
      );
      final text = _allText(t);
      expect(text, contains('71'));
      expect(text, contains('bpm'));
      expect(text, contains('Signal quality'));
      expect(_rowText(t, 'quality'), contains('2'));
    });

    testWidgets('measuring but nothing yet: no bpm, no quality line, no "0" '
        'standing in for a missing value', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.active,
          progress: 40,
          liveHr: null,
          quality: 0,
        )),
      );
      final text = _allText(t);
      expect(text, isNot(contains('bpm')));
      expect(text, isNot(contains('Signal quality')));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('waiting for contact: no live metric of any kind', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.waiting,
          quality: 0,
        )),
      );
      final text = _allText(t);
      expect(text, isNot(contains('bpm')));
      expect(text, isNot(contains('Signal quality')));
    });

    testWidgets('it never shows an RMSSD or SDNN', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.active,
          liveHr: 71,
          quality: 2,
          progress: 40,
        )),
      );
      final text = _allText(t).toLowerCase();
      expect(text, isNot(contains('rmssd')));
      expect(text, isNot(contains('sdnn')));
    });
  });

  group('the result page (after the reading)', () {
    testWidgets('a complete reading lists its metrics with real names and '
        'values', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.completed,
          result: EcgReadingStatus.completed,
          readingId: 'r1',
          metrics: [_hr, _q],
        )),
      );
      expect(_rowText(t, 'avgHr'), allOf(contains('Average heart rate'), contains('77 bpm')));
      expect(_rowText(t, 'quality'), contains('Signal quality'));
    });

    testWidgets('a metric the result does not have is "—", never 0',
        (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.completed,
          result: EcgReadingStatus.completed,
          readingId: 'r1',
          metrics: [_hr, _rmssdNone],
        )),
      );
      expect(_rowText(t, 'rmssd'), contains('—'));
      expect(_rowText(t, 'rmssd'), isNot(contains('0')));
    });

    testWidgets('a partial recording says it stopped early and was saved as '
        'partial, shows "—" for metrics it had too little signal for, and '
        'offers to view it', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.cancelled,
          reason: 'paused',
          result: EcgReadingStatus.partial,
          readingId: 'p1',
          metrics: [
            EcgMetric(key: 'avgHr', name: 'Average heart rate', value: null, unit: 'bpm'),
            EcgMetric(key: 'quality', name: 'Signal quality', value: null, unit: ''),
          ],
        )),
      );
      final text = _allText(t).toLowerCase();
      expect(text, contains('partial'));
      expect(text, contains('saved'));
      expect(_rowText(t, 'avgHr'), contains('—'));
      expect(_rowText(t, 'quality'), contains('—'));
      expect(text, contains('view reading'));
    });

    testWidgets('a cancelled reading that saved nothing does not claim a '
        'saved partial', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.cancelled,
          reason: 'cancelled',
        )),
      );
      final text = _allText(t).toLowerCase();
      expect(text, isNot(contains('partial')));
      expect(text, isNot(contains('saved')));
    });
  });

  group('the detail screen', () {
    testWidgets('lists the metrics through the same rows: name, value, unit',
        (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: fixtureReading(avgHr: 77, quality: 3), packets: const []),
        ),
      );
      expect(_rowText(t, 'avgHr'), allOf(contains('Average heart rate'), contains('77 bpm')));
      expect(_rowText(t, 'quality'), allOf(contains('Signal quality'), contains('3')));
    });

    testWidgets('a band quality of 0, or a missing heart rate, is "—" and '
        'never "0"', (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(
            reading: fixtureReading(avgHr: null, quality: 0),
            packets: const [],
          ),
        ),
      );
      expect(_rowText(t, 'avgHr'), contains('—'));
      expect(_rowText(t, 'quality'), contains('—'));
      expect(_rowText(t, 'quality'), isNot(contains('0')));
    });

    testWidgets('a partial reading: marked partial with why it stopped, no '
        'band verdict, metrics "—"', (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: partialEndingAt(kT0 + 12), packets: const []),
        ),
      );
      final text = _allText(t);
      expect(text.toLowerCase(), contains('partial'));
      expect(text, isNot(contains('Band-reported result')),
          reason: 'the band never gave one');
      expect(text, isNot(contains('Inconclusive')));
      expect(text, isNot(contains('Sinus rhythm')));
      expect(_rowText(t, 'avgHr'), contains('—'));
      expect(_rowText(t, 'quality'), contains('—'));
    });

    testWidgets('never shows an RMSSD or SDNN row', (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: fixtureReading(), packets: const []),
        ),
      );
      expect(_row('rmssd'), findsNothing);
      expect(_row('sdnn'), findsNothing);
      expect(_allText(t).toLowerCase(), isNot(contains('rmssd')));
    });

    testWidgets('links to the screener page (what each state means)',
        (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: fixtureReading(), packets: const []),
        ),
      );
      expect(find.byKey(const ValueKey('ecg-screener-link')), findsOneWidget);
    });
  });
}
