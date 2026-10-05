// Priority is per signal, present without contention, and shows
// its consequence before saving (contract 9). Service model + pure view.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'support/sources_support.dart';

const _rrOrder = [kPrimary, kStrapA];
const _labels = {kPrimary: 'WHOOP', kStrapA: 'Polar H10 · 2c3d'};

Map<String, Object?> _signal(String name, List<String> order) => {
  'signal': name,
  'order': order,
  'labels': {for (final id in order) id: _labels[id]!},
};

void main() {
  useSourcesDb('sources_priority_test.db');

  group('service model', () {
    Future<Map<String, Map<String, Object?>>> model(dynamic svc) async {
      final list = await sourcesAsync<dynamic>(
        'SourceService.prioritySignals() listing every declared signal',
        () async => await svc.prioritySignals(),
      );
      return {
        for (final m in list as List)
          (m as Map)['signal'] as String: Map<String, Object?>.from(m),
      };
    }

    test('controls exist for every declared signal even with no contention',
        () async {
      final solo = await model(openService(sources: [kBand]));
      expect(solo.keys, containsAll(['hr1Hz', 'rrIntervals']),
          reason: 'one device, no contention, still has controls');
      expect(solo['hr1Hz']!['order'], [kPrimary]);
      expect(solo['hr1Hz']!['contended'], isFalse);
    });

    test('orders are per signal and only list devices declaring that signal',
        () async {
      final both = await model(openService(sources: [kBand, strap(kStrapA)]));
      expect(both['rrIntervals']!['contended'], isTrue);
      expect(both['rrIntervals']!['order'], unorderedEquals(_rrOrder));
      expect(both['hr1Hz']!['order'], [kPrimary],
          reason: 'a chest strap does not declare hr1Hz, so it is not offered');
      expect(both['hr1Hz']!['contended'], isFalse);
      expect(both['hrSparse']!['order'], [kStrapA]);
    });

    test('a stored order is shown, and saving one signal leaves the others',
        () async {
      await LocalDb.setSignalPriority(InputSignal.hr1Hz, [kPrimary]);
      final svc = openService(sources: [kBand, strap(kStrapA)]);
      await sourcesAsync<void>(
        'SourceService.savePriority(signal, order)',
        () async => await svc.savePriority(InputSignal.rrIntervals, [kStrapA, kPrimary]),
      );
      expect(await LocalDb.signalPriority(InputSignal.rrIntervals), [kStrapA, kPrimary]);
      expect(await LocalDb.signalPriority(InputSignal.hr1Hz), [kPrimary],
          reason: 'saving rrIntervals must not rewrite hr1Hz');
      final m = await model(svc);
      expect(m['rrIntervals']!['order'], [kStrapA, kPrimary]);
      expect((await LocalDb.signalPriorities()).keys, isNot(contains('hrSparse')),
          reason: 'saving one signal does not seed rows for untouched signals');
    });
  });

  group('priority editor view', () {
    Future<
      ({
        List<(String, List<String>)> saved,
        List<int> rebuilds,
      })
    >
    pumpEditor(WidgetTester t) async {
      t.view.physicalSize = const Size(1170, 15000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final saved = <(String, List<String>)>[];
      final rebuilds = <int>[];
      final dynamic views = openViews();
      final Widget editor = sourcesContract(
        'SourceViews.priorityEditor(signals:, onSave:, onRebuild:)',
        () =>
            views.priorityEditor(
                  signals: [
                    _signal('rrIntervals', _rrOrder),
                    _signal('hr1Hz', [kPrimary]),
                  ],
                  onSave: (String s, List<String> o) => saved.add((s, o)),
                  onRebuild: () => rebuilds.add(1),
                )
                as Widget,
      );
      await t.pumpWidget(material(editor));
      await t.pumpAndSettle();
      return (saved: saved, rebuilds: rebuilds);
    }

    testWidgets('each signal has its own section, with or without contention',
        (t) async {
      await pumpEditor(t);
      expect(find.byKey(const ValueKey('priority:rrIntervals')), findsOneWidget);
      expect(find.byKey(const ValueKey('priority:hr1Hz')), findsOneWidget,
          reason: 'uncontended signals still show their control');
      expect(find.text('Polar H10 · 2c3d'), findsWidgets);
      expect(find.byKey(const ValueKey('priority-consequence:rrIntervals')), findsNothing,
          reason: 'no change yet, so no consequence');
    });

    testWidgets('a pending change shows its consequence before anything saves',
        (t) async {
      final r = await pumpEditor(t);
      await t.tap(find.byKey(const ValueKey('priority-up:rrIntervals:$kStrapA')));
      await t.pumpAndSettle();

      final consequence = find.byKey(const ValueKey('priority-consequence:rrIntervals'));
      expect(consequence, findsOneWidget);
      final text = t.widgetList<Text>(
        find.descendant(of: consequence, matching: find.byType(Text)),
      ).map((w) => w.data ?? w.textSpan?.toPlainText() ?? '').join(' ').toLowerCase();
      expect(text, contains('polar h10 · 2c3d'),
          reason: 'names the source that would win');
      expect(text, contains('future'),
          reason: 'says it applies to current and future computation');
      expect(text, contains('history'),
          reason: 'says past days are unchanged unless rebuilt');
      expect(r.saved, isEmpty, reason: 'the consequence is shown BEFORE saving');
      expect(find.byKey(const ValueKey('priority-consequence:hr1Hz')), findsNothing,
          reason: 'priority is per signal: hr1Hz is unaffected');
    });

    testWidgets('save writes only the changed signal; rebuild is separate and '
        'explains its cost first', (t) async {
      final r = await pumpEditor(t);
      await t.tap(find.byKey(const ValueKey('priority-save:rrIntervals')));
      await t.pumpAndSettle();
      expect(r.saved, isEmpty, reason: 'nothing to save before a change');

      await t.tap(find.byKey(const ValueKey('priority-up:rrIntervals:$kStrapA')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('priority-save:rrIntervals')));
      await t.pumpAndSettle();
      expect(r.saved.length, 1);
      expect(r.saved.single.$1, 'rrIntervals');
      expect(r.saved.single.$2, [kStrapA, kPrimary]);
      expect(r.rebuilds, isEmpty, reason: 'saving never rebuilds history');

      expect(find.text('Rebuild history with this priority'), findsOneWidget);
      await t.tap(find.text('Rebuild history with this priority'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rebuild-cost')), findsOneWidget,
          reason: 'the cost is explained before anything runs');
      expect(r.rebuilds, isEmpty);
      await t.tap(find.byKey(const ValueKey('rebuild-confirm')));
      await t.pumpAndSettle();
      expect(r.rebuilds.length, 1);
    });
  });
}
