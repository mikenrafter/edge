// CalcLoading reserves its detail line, so the line appearing when the derive
// pass reports its first day pushes nothing. And the progress lines speak the
// app language.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/inline_loading.dart';
import 'package:openstrap_edge/ui2/sync_control.dart';
import 'package:openstrap_edge/ui2/theme.dart';

class _App extends AppState {
  _App() : super.forTesting();
  final derive = ValueNotifier<DeriveProgress?>(null);
  @override
  ValueListenable<DeriveProgress?> get deriveProgress => derive;
}

void main() {
  testWidgets('CalcLoading height does not change when detail appears',
      (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const Scaffold(
              body: Column(children: [CalcLoading(status: 'Reading')]))),
    ));
    final before = t.getSize(find.byType(InlineLoading)).height;
    app.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 12);
    await t.pump();
    expect(find.text('Calculating · day 3 of 12'), findsOneWidget);
    expect(t.getSize(find.byType(InlineLoading)).height, before);
  });

  testWidgets('progress lines are localised', (t) async {
    final ru = await AppLocalizations.delegate.load(const Locale('ru'));
    expect(deriveProgressLine(const DeriveProgress(dayIndex: 3, dayTotal: 12), ru),
        'Расчёт · день 3 из 12');
    expect(
        deriveProgressLine(
            const DeriveProgress(dayIndex: 3, dayTotal: 12, day: 'd'), ru),
        'Расчёт · день 3 из 12 · d');
    expect(deriveProgressLine(const DeriveProgress(waiting: true), ru),
        'Ожидание другого расчёта');
    expect(deriveProgressLine(const DeriveProgress(), ru), 'Считаем…');
    expect(
        calcProgressLine(
            const SyncPresentationState(phase: 'deriving', busy: true), ru),
        'Считаем…');
  });
}
