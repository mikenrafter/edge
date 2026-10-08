// Design 04 phase 1, item 4 (owner decision 7): the per-second timeline in a
// reading's Details when the waveform was kept - each second's band quality,
// presence and S2 flags, reason mask and progress - read through ONE decoder
// (lib/ecg/ecg_seconds.dart), and "not kept" when the waveform was not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_seconds.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/cardio_fixtures.dart';

EcgAcceptedPacket _live(
  int seq, {
  int progress = 3,
  int quality = 2,
  int unreadable = 0,
  bool presence = true,
}) => EcgAcceptedPacket.of(
  r17(
    seq: seq,
    progress: progress,
    quality: quality,
    unreadable: unreadable,
    presence: presence,
  ),
);

Future<void> _pump(WidgetTester t, EcgDetailData data) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: EcgDetailScreen(data: data),
    ),
  );
  await t.pump();
}

Future<void> _openDetails(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('ecg-details')));
  await t.pumpAndSettle();
}

String _texts(WidgetTester t, Finder under) => t
    .widgetList<Text>(find.descendant(of: under, matching: find.byType(Text)))
    .map((w) => w.data ?? '')
    .join('\n');

void main() {
  group('the one decoder', () {
    test('a live packet decodes its own header bytes', () {
      final s = ecgSecondOf(
        4,
        _live(7, progress: 40, quality: 3, unreadable: 0x06),
      );
      expect(s.decoded, isTrue);
      expect(s.placeholder, isFalse);
      expect(s.ordinal, 4);
      expect(s.sequence, 7);
      expect(s.quality, 3);
      expect(s.presence, isTrue);
      expect(s.currentS2One, isTrue);
      expect(s.s2State, 1);
      expect(s.progress, 40);
      expect(s.mask, 0x06);
    });

    test('contact off is presence false', () {
      expect(ecgSecondOf(0, _live(1, presence: false)).presence, isFalse);
    });

    test('a placeholder second has no band bytes and is not "decoded"', () {
      final s = ecgSecondOf(2, EcgAcceptedPacket.placeholder(5));
      expect(s.placeholder, isTrue);
      expect(s.decoded, isFalse);
      expect(s.quality, isNull);
      expect(s.mask, isNull);
    });

    test('bytes that are not an R17 packet are undecodable, never guessed',
        () {
      final s = ecgSecondOf(0, cardioPacket(0)); // inner_hex ab00cdef01
      expect(s.decoded, isFalse);
      expect(s.quality, isNull);
      expect(s.mask, isNull);
    });

    test('ecgMaskAnyOf ORs every decodable second and ignores the rest', () {
      final packets = [
        _live(1, unreadable: 0x02),
        EcgAcceptedPacket.placeholder(2),
        cardioPacket(3),
        _live(4, unreadable: 0x04),
      ];
      expect(ecgMaskAnyOf(packets), 0x06);
      expect(ecgMaskAnyOf(const []), 0);
    });
  });

  group('the timeline in Details', () {
    testWidgets('Keep waveform on: a collapsible table, one row per second '
        'with quality, contact, S2, reasons and progress', (t) async {
      final packets = [
        _live(1, progress: 3, quality: 1),
        _live(2, progress: 6, quality: 2, unreadable: 0x02),
        EcgAcceptedPacket.placeholder(3),
        EcgAcceptedPacket.of(r17(seq: 4, progress: 12, quality: 3, presence: false)),
      ];
      await _pump(
        t,
        EcgDetailData(reading: cardioReading(), packets: packets),
      );
      await _openDetails(t);
      final box = find.byKey(const ValueKey('ecg-detail:timeline'));
      expect(box, findsOneWidget);
      expect(find.byKey(const ValueKey('ecg-timeline-table')), findsNothing,
          reason: 'collapsed until asked for');
      await t.tap(find.byKey(const ValueKey('ecg-timeline-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ecg-timeline-table')), findsOneWidget);
      final text = _texts(t, box);
      expect(text, contains('Significant noise'),
          reason: 'second 2 carried the noise bit');
      expect(text, contains('missing second'), reason: 'the gap is shown');
      expect(text, contains('12%'));
      expect(text, contains('6%'));
      expect(text, contains('\nno\n'), reason: 'second 4 had no contact');
      // Collapsing hides the rows again.
      await t.tap(find.byKey(const ValueKey('ecg-timeline-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ecg-timeline-table')), findsNothing);
    });

    testWidgets('bytes that cannot be decoded are said to be undecodable',
        (t) async {
      await _pump(
        t,
        EcgDetailData(reading: cardioReading(), packets: [cardioPacket(0)]),
      );
      await _openDetails(t);
      await t.tap(find.byKey(const ValueKey('ecg-timeline-toggle')));
      await t.pumpAndSettle();
      expect(
        _texts(t, find.byKey(const ValueKey('ecg-detail:timeline'))),
        contains('not decodable'),
      );
    });

    testWidgets('Keep waveform off: the timeline says "not kept" and has no '
        'table to open', (t) async {
      await _pump(t, EcgDetailData(reading: cardioReading(), packets: const []));
      await _openDetails(t);
      final box = find.byKey(const ValueKey('ecg-detail:timeline'));
      expect(box, findsOneWidget);
      expect(_texts(t, box), contains('not kept'));
      expect(find.byKey(const ValueKey('ecg-timeline-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('ecg-timeline-table')), findsNothing);
    });

    testWidgets('the timeline is not built while Details is collapsed',
        (t) async {
      await _pump(
        t,
        EcgDetailData(reading: cardioReading(), packets: [_live(1)]),
      );
      expect(find.byKey(const ValueKey('ecg-detail:timeline')), findsNothing);
    });
  });
}
