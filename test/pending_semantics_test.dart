// CLAIM(pending-semantics): pending Sleep sections name the section rather
// than exposing placeholder values. Only a load started by a user action has
// a completion live region; refreshing in the background must stay silent.
// Catches: excluding all semantics, or marking every completion live.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/skeleton_fixture.dart';

class _SleepContent implements AsyncSectionContent<String> {
  const _SleepContent();
  @override Widget loaded(BuildContext context, String value) => Text(value);
  @override Widget pending(BuildContext context) => const Text('—');
  @override Widget empty(BuildContext context) => const SizedBox.shrink();
  @override Widget failed(BuildContext context) => const SizedBox.shrink();
}

Finder liveRegions() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.liveRegion == true,
);

void main() {
  testWidgets('pending Sleep section exposes its localized name', (t) async {
    skTallView(t, w: 390, h: 10000);
    final semantics = t.ensureSemantics();
    try {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.pumpWidget(
        perfApp(
          app,
          skHost(
            const SleepDetail(
              embedded: true,
              data: SleepData(historyPending: true),
            ),
          ),
        ),
      );
      await t.pump();
      expect(
        find.bySemanticsLabel('Loading, Against your usual'),
        findsOneWidget,
      );
      expect(liveRegions(), findsNothing);
      await t.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'background refresh stays silent; a user load completes politely in seven locales',
    (t) async {
      final semantics = t.ensureSemantics();
      try {
        // Literal language oracles, independent of the production formatter.
        const labels = {
          'en': ('Loading, Sleep', 'Loaded, Sleep'),
          'de': ('Wird geladen, Sleep', 'Geladen, Sleep'),
          'es': ('Cargando, Sleep', 'Cargado, Sleep'),
          'fr': ('Chargement, Sleep', 'Chargé, Sleep'),
          'hi': ('लोड हो रहा है, Sleep', 'लोड हो गया, Sleep'),
          'ru': ('Загрузка, Sleep', 'Загружено, Sleep'),
          'zh': ('正在加载，Sleep', '已加载，Sleep'),
        };
        for (final locale in labels.entries) {
          final pending = ValueNotifier(false);
          await t.pumpWidget(
            skHost(
              ValueListenableBuilder<bool>(
                valueListenable: pending,
                builder: (_, waiting, _) => Scaffold(
                  body: Column(
                    children: [
                      Pressable(
                        onTap: () => pending.value = true,
                        child: const Text('Switch day'),
                      ),
                      SettingsAccordion(
                        'Sleep',
                        id: 'semantics_sleep',
                        children: [
                          AsyncSection<String>(
                            pending: waiting,
                            value: waiting ? null : '7h 23m',
                            content: const _SleepContent(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              locale: Locale(locale.key),
            ),
          );
          // A semantic/control action that starts no load must still expire
          // its intent; otherwise a later background read inherits it.
          await t.pumpAndSettle();
          PendingUserAction.run(() {});
          expect(t.binding.hasScheduledFrame, isTrue);
          await t.pump();
          pending.value = true;
          await t.pump();
          expect(find.bySemanticsLabel(locale.value.$1), findsOneWidget);
          expect(find.bySemanticsLabel('—'), findsNothing);
          pending.value = false;
          await t.pump();
          expect(
            liveRegions(),
            findsNothing,
            reason: '${locale.key}: background read',
          );
          await t.tap(find.text('Switch day'));
          await t.pump();
          expect(find.bySemanticsLabel(locale.value.$1), findsOneWidget);
          expect(find.bySemanticsLabel('—'), findsNothing);
          pending.value = false;
          await t.pump();
          expect(find.bySemanticsLabel(locale.value.$2), findsOneWidget);
          expect(
            liveRegions(),
            findsOneWidget,
            reason: '${locale.key}: positive control',
          );
          expect(
            find.semantics
                .byLabel(locale.value.$2)
                .evaluate()
                .single
                .flagsCollection
                .isLiveRegion,
            isTrue,
          );
          await t.pump();
          expect(
            liveRegions(),
            findsNothing,
            reason: 'completion announces once',
          );
          await t.pumpWidget(const SizedBox());
          pending.dispose();
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
