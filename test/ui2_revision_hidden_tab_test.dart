// A hidden tab does not re-read on every revision.
//
// No NEW symbol is needed to compile this file: it pins behaviour of the
// existing RevisionReload mixin and AppShell, so it fails on behaviour.
//
// CONTRACT:
//   * AppShell wraps every NON-current tab body in TickerMode(enabled: false);
//     the current tab is enabled. A never-built tab stays an unbuilt
//     SizedBox.shrink (the lazy-build rule is unchanged).
//   * RevisionReload registers a dependency on TickerMode (`TickerMode.of` is deprecated since
//     Flutter 3.35 — use `TickerMode.valuesOf(context).enabled`). On a
//     revision (or a locale change) while TickerMode is false it only
//     remembers "dirty"; when TickerMode turns true again and it is dirty it
//     reloads ONCE. Visible tabs still reload immediately.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.name, this.log);
  final String name;
  final List<String> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with RevisionReload {
  @override
  void reload() => widget.log.add(widget.name);
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

Widget _host(AppState app, LocaleController locale, Widget child) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LocaleController>.value(value: locale),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
    );

void main() {
  late AppState app;
  late LocaleController locale;
  late List<String> log;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState.forTesting();
    locale = LocaleController.seed(null);
    log = [];
  });
  tearDown(() {
    app.dispose();
    locale.dispose();
  });

  Widget tree(bool visible) => _host(
        app,
        locale,
        TickerMode(enabled: visible, child: _Probe('p', log)),
      );

  testWidgets('three bumps while hidden: zero reloads; showing it: exactly one',
      (t) async {
    await t.pumpWidget(tree(false));
    app.bumpInsights();
    app.bumpInsights();
    app.bumpInsights();
    await t.pump();
    expect(log, isEmpty, reason: 'a parked tab must not hit the database');

    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, ['p'], reason: 'the missed revisions are one reload, not three');

    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, ['p'], reason: 'dirty is cleared once it has been honoured');
  });

  testWidgets('showing a tab that missed nothing does not reload', (t) async {
    await t.pumpWidget(tree(false));
    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, isEmpty);
  });

  testWidgets('a visible tab still reloads immediately, once per bump',
      (t) async {
    await t.pumpWidget(tree(true));
    app.bumpInsights();
    await t.pump();
    expect(log, ['p']);
    app.bumpInsights();
    await t.pump();
    expect(log, ['p', 'p']);
  });

  testWidgets('hiding then bumping then showing again defers correctly',
      (t) async {
    await t.pumpWidget(tree(true));
    await t.pumpWidget(tree(false));
    app.bumpInsights();
    await t.pump();
    expect(log, isEmpty);
    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, ['p']);
  });

  testWidgets('a locale change while hidden is deferred the same way',
      (t) async {
    await t.pumpWidget(tree(false));
    await t.runAsync(() => locale.setCode('es'));
    await t.pump();
    expect(log, isEmpty, reason: 'hidden: no reload on a language switch');
    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, ['p'], reason: 'baked-in strings must still be refreshed');
  });

  testWidgets('a bump AND a locale change while hidden are one reload on show',
      (t) async {
    await t.pumpWidget(tree(false));
    app.bumpInsights();
    await t.runAsync(() => locale.setCode('es'));
    await t.pump();
    await t.pumpWidget(tree(true));
    await t.pump();
    expect(log, ['p']);
  });

  testWidgets('disposing a dirty hidden tab is silent', (t) async {
    await t.pumpWidget(tree(false));
    app.bumpInsights();
    await t.pump();
    await t.pumpWidget(_host(app, locale, const SizedBox()));
    app.bumpInsights();
    await t.pump();
    expect(log, isEmpty);
    expect(t.takeException(), isNull);
  });

  group('AppShell', () {
    Widget shell() => _host(
          app,
          locale,
          AppShell(
            builder: (c, d) => _Probe(d.name, log),
          ),
        );

    bool enabledFor(WidgetTester t, String name) {
      final probe = find.byWidgetPredicate(
          (w) => w is _Probe && w.name == name,
          skipOffstage: false);
      return TickerMode.valuesOf(t.element(probe)).enabled;
    }

    testWidgets('only the opened tab is built; the rest stay unbuilt',
        (t) async {
      await t.pumpWidget(shell());
      expect(find.byType(_Probe, skipOffstage: false), findsOneWidget);
      expect(enabledFor(t, 'home'), isTrue);
    });

    testWidgets('a tab left behind is wrapped in TickerMode(enabled: false)',
        (t) async {
      await t.pumpWidget(shell());
      await t.tap(find.text('Health'));
      await t.pump();
      expect(find.byType(_Probe, skipOffstage: false), findsNWidgets(2));
      expect(enabledFor(t, 'home'), isFalse);
      expect(enabledFor(t, 'health'), isTrue);
      // The three never-visited tabs are still unbuilt.
      expect(find.byType(_Probe, skipOffstage: false), findsNWidgets(2));
    });

    testWidgets('a revision reloads only the visible tab; coming back reloads '
        'the parked one once', (t) async {
      await t.pumpWidget(shell());
      await t.tap(find.text('Health'));
      await t.pump();
      log.clear();

      // Two bumps, a frame apart (the visible tab reloads once per bump, as
      // the test above pins; two bumps in one frame are two reloads too).
      app.bumpInsights();
      await t.pump();
      app.bumpInsights();
      await t.pump();
      expect(log, ['health', 'health'],
          reason: 'home is parked: it must not re-read on a derive');

      log.clear();
      await t.tap(find.text('Home'));
      await t.pump();
      expect(log, ['home'], reason: 'it missed two bumps: one reload on return');
      expect(enabledFor(t, 'health'), isFalse);
    });
  });
}
