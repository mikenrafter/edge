// The pure Source catalog and Resolved data views (contracts 7
// and 8, widget half). Inputs are the JSON shapes in sources_contract.md.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/sources_support.dart';

Future<void> _pump(WidgetTester t, Widget Function(dynamic views) build) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final dynamic views = openViews();
  final Widget w = sourcesContract('SourceViews factory method', () => build(views));
  await t.pumpWidget(material(w));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

Widget _catalog(dynamic v, List<Map<String, Object?>> cards) => sourcesContract(
  'SourceViews.catalog(cards:)',
  () => v.catalog(cards: cards) as Widget,
);

Widget _resolved(dynamic v, List<Map<String, Object?>> rows) => sourcesContract(
  'SourceViews.resolvedData(rows:, names:)',
  () => v.resolvedData(rows: rows, names: kFixtureNames) as Widget,
);

void main() {
  final h0 = sec(2026, 9, 1, 0), h2 = sec(2026, 9, 1, 2), h3 = sec(2026, 9, 1, 3), h4 = sec(2026, 9, 1, 4);

  group('Source catalog view', () {
    testWidgets('two same-model cards are told apart by suffix only', (t) async {
      final a = cardFixture(deviceId: kStrapA, suffix: '2c3d', platformIdSuffix: 'EE01');
      final b = cardFixture(deviceId: kStrapB, suffix: '7d6c', platformIdSuffix: 'EE02');
      await _pump(t, (v) => _catalog(v, [a, b]));
      expect(find.text('Polar H10 · 2c3d'), findsOneWidget);
      expect(find.text('Polar H10 · 7d6c'), findsOneWidget);
      expect(textLike(kRemoteA.toLowerCase()), findsNothing);
      expect(textLike(kStrapA), findsNothing,
          reason: 'the full minted id is internal');
    });

    testWidgets('shows collection behavior, signals, permissions, limitations '
        'and why each signal uses the source', (t) async {
      await _pump(t, (v) => _catalog(v, [
        cardFixture(
          coverage: {
            'rrIntervals': {'start': h0, 'end': h4},
          },
          lastSeen: h4,
        ),
      ]));
      expect(textLike('user-started'), findsWidgets);
      expect(textLike(RegExp('beat-to-beat|rrintervals')), findsWidgets,
          reason: 'a supplied signal is named (any human label contains it or '
              'the signal name)');
      expect(textLike('bluetooth'), findsWidgets);
      expect(textLike('experimental'), findsWidgets);
      expect(find.textContaining('First in your order for beat timing.'), findsOneWidget,
          reason: 'the card prints the production reason verbatim');
    });

    testWidgets('each collection behavior has a label', (t) async {
      for (final behavior in [
        'continuous',
        'sampled',
        'user-started',
        'imported',
        'derived',
      ]) {
        await _pump(t, (v) => _catalog(v, [cardFixture(collection: behavior)]));
        expect(textLike(behavior), findsWidgets, reason: behavior);
      }
    });

    testWidgets('absent fields render a dash, never null or a guess', (t) async {
      await _pump(t, (v) => _catalog(v, [
        cardFixture(
          deviceId: '',
          name: 'This phone',
          suffix: null,
          type: 'phone',
          model: null,
          platformIdSuffix: null,
          collection: 'sampled',
          signals: const [],
          permissions: const [],
          limitations: const [],
          uses: const [],
        ),
      ]));
      expect(find.text('—'), findsWidgets);
      expect(textLike(RegExp(r'\bnull\b')), findsNothing);
      expect(textLike('unknown'), findsNothing);
    });
  });

  group('Resolved data view', () {
    final overlap = intervalFixture(start: h2, end: h3);
    final single = intervalFixture(
      start: h0,
      end: h2,
      kind: 'single',
      winner: kPrimary,
      alternatives: const [],
      agreement: 'single',
      reasonCode: 'onlySource',
      reason: 'Only the band was recording.',
    );
    final gap = intervalFixture(
      start: h3,
      end: h4,
      kind: 'gap',
      winner: null,
      alternatives: const [],
      agreement: 'none',
      reasonCode: 'noCoverage',
      reason: 'Nothing was recording.',
    );

    testWidgets('rows show winner, alternatives, agreement and reason',
        (t) async {
      await _pump(t, (v) => _resolved(v, [single, overlap, gap]));
      final row = find.byKey(ValueKey('resolved-row:rrIntervals:$h2'));
      expect(row, findsOneWidget);
      String within(Finder f) => t
          .widgetList<Text>(find.descendant(of: row, matching: f))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .join(' | ');
      final text = within(find.byType(Text));
      expect(text, contains('Polar H10 · 2c3d'), reason: 'winner');
      expect(text, contains('WHOOP'), reason: 'alternative');
      expect(text.toLowerCase(), contains('agree'));
      expect(text, contains('Ranked first in your order for beat timing.'));
      expect(find.textContaining('Only the band was recording.'), findsOneWidget);
      expect(find.textContaining('Nothing was recording.'), findsOneWidget);
      expect(find.text('—'), findsWidgets, reason: 'the gap has no winner');
      expect(textLike(RegExp(r'\bnull\b')), findsNothing);
    });

    testWidgets('each agreement state has its own wording', (t) async {
      final cases = {
        'agree': RegExp(r'^(?!.*disagree).*agree'),
        'disagree': RegExp('disagree'),
        'single': RegExp('single'),
        'none': RegExp('no comparison|nothing to compare|—'),
      };
      for (final e in cases.entries) {
        await _pump(t, (v) => _resolved(v, [
          intervalFixture(start: h2, end: h3, agreement: e.key),
        ]));
        expect(textLike(e.value), findsWidgets, reason: 'agreement ${e.key}');
      }
    });

    testWidgets('the timeline draws overlap and gap segments per signal',
        (t) async {
      await _pump(t, (v) => _resolved(v, [single, overlap, gap]));
      final timeline = find.byKey(const ValueKey('resolved-timeline:rrIntervals'));
      expect(timeline, findsOneWidget);
      Finder seg(String kind) => find.descendant(
        of: timeline,
        matching: find.byKey(ValueKey('segment:$kind')),
      );
      expect(seg('single'), findsOneWidget);
      expect(seg('overlap'), findsOneWidget);
      expect(seg('gap'), findsOneWidget,
          reason: 'a gap is drawn as a gap, never filled with the neighbour');
    });
  });
}
