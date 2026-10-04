// P4b: the one shared status line, "<label> · m:ss".
//
// ASSUMED API (new file lib/ui2/calc_status_line.dart):
//
//   class CalcStatusLine extends StatefulWidget {
//     const CalcStatusLine({
//       super.key,
//       ValueListenable<CalcStep?>? status,   // default CalcStatus.instance
//       DateTime Function()? now,             // default DateTime.now
//     });
//   }
//
// (CalcStep / CalcStatus: lib/compute/calc_status.dart, see calc_status_test.)
//
// SEMANTICS pinned here:
//   * null step => renders nothing (SizedBox.shrink): no text, no spinner, no
//     percentage, no ETA.
//   * open step => one line "<label> · <m:ss>", m:ss = now() - step.startedAt,
//     minutes unpadded, seconds padded ("0:00", "0:12", "1:05", "61:05");
//     never negative (a start in the future shows 0:00).
//   * ticks once a second, and ONLY while a step is open and the line is
//     visible: no tick (no `now()` call, no rebuild) when null, and none under
//     TickerMode(enabled: false) (a hidden tab); ticking resumes when the
//     TickerMode comes back on. A new step starting from null starts the tick.
//   * a step change shows the new label at once (listener driven, no wait for
//     the next tick).
//   * fits a 360 pt column at 1.5x text scale without overflow (the text
//     ellipsizes, it does not wrap past the box).
//   * no timer survives dispose (the binding's own "timer still pending" check
//     fails the test otherwise).
//
// Failure mode today: the library does not exist (the file fails to load).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_status.dart';
import 'package:openstrap_edge/ui2/calc_status_line.dart';

final _t0 = DateTime(2026, 10, 4, 9, 0, 0);

class _Clock {
  DateTime t = _t0;
  int calls = 0;
  DateTime call() {
    calls++;
    return t;
  }

  void advance(int seconds) => t = t.add(Duration(seconds: seconds));
}

Widget _host(Widget child, {bool tickers = true, double scale = 1}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: TickerMode(
            enabled: tickers,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 360, child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  late _Clock clock;
  late CalcStatus status;

  setUp(() {
    clock = _Clock();
    status = CalcStatus(clock: () => clock.t);
  });

  Widget line() => CalcStatusLine(status: status, now: clock.call);

  testWidgets('null step: nothing is drawn', (t) async {
    await t.pumpWidget(_host(line()));
    expect(find.byType(Text), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('an open step reads "<label> · m:ss" from the injected clock',
      (t) async {
    final token = status.begin('Sleep stages');
    clock.advance(12);
    await t.pumpWidget(_host(line()));
    expect(find.text('Sleep stages · 0:12'), findsOneWidget);
    status.end(token);
    await t.pump();
  });

  testWidgets('m:ss formatting: minutes unpadded, seconds padded, no negatives',
      (t) async {
    final token = status.begin('Day calculations');
    await t.pumpWidget(_host(line()));
    expect(find.text('Day calculations · 0:00'), findsOneWidget);

    clock.advance(65);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Day calculations · 1:05'), findsOneWidget);

    clock.advance(600 - 65);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Day calculations · 10:00'), findsOneWidget);

    clock.advance(3600);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Day calculations · 70:00'), findsOneWidget);

    clock.t = _t0.subtract(const Duration(seconds: 30)); // clock stepped back
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Day calculations · 0:00'), findsOneWidget);

    status.end(token);
    await t.pump();
  });

  testWidgets('ticks once a second while a step is open', (t) async {
    final token = status.begin('Baselines');
    await t.pumpWidget(_host(line()));
    expect(find.text('Baselines · 0:00'), findsOneWidget);

    clock.advance(1);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Baselines · 0:01'), findsOneWidget);

    clock.advance(1);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('Baselines · 0:01'), findsOneWidget,
        reason: 'not before the second is up');
    await t.pump(const Duration(milliseconds: 800));
    expect(find.text('Baselines · 0:02'), findsOneWidget);

    status.end(token);
    await t.pump();
  });

  testWidgets('a step change shows at once; ending hides at once; no tick is '
      'needed', (t) async {
    await t.pumpWidget(_host(line()));
    expect(find.byType(Text), findsNothing);

    final a = status.begin('Day calculations');
    await t.pump();
    expect(find.text('Day calculations · 0:00'), findsOneWidget);

    clock.advance(3);
    final b = status.begin('Sleep stages');
    await t.pump();
    expect(find.text('Sleep stages · 0:00'), findsOneWidget);
    expect(find.textContaining('Day calculations'), findsNothing);

    clock.advance(2);
    status.end(b);
    await t.pump();
    expect(find.text('Day calculations · 0:05'), findsOneWidget,
        reason: 'the outer step has been running since it began');

    status.end(a);
    await t.pump();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('no ticking while idle: the clock is not read once a second',
      (t) async {
    await t.pumpWidget(_host(line()));
    final before = clock.calls;
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 5));
    await t.pump(const Duration(seconds: 30));
    expect(clock.calls, before, reason: 'idle: no timer, no reads');
  });

  testWidgets('ticking stops when the step ends, and starts with the next',
      (t) async {
    final a = status.begin('Notifications');
    await t.pumpWidget(_host(line()));
    clock.advance(1);
    await t.pump(const Duration(seconds: 1));
    status.end(a);
    await t.pump();
    final after = clock.calls;
    await t.pump(const Duration(seconds: 10));
    expect(clock.calls, after, reason: 'closed: ticking stopped');

    final b = status.begin('Tidying up');
    await t.pump();
    clock.advance(1);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Tidying up · 0:01'), findsOneWidget);
    status.end(b);
    await t.pump();
  });

  testWidgets('hidden tab (TickerMode off): no ticking; back on: it resumes',
      (t) async {
    final token = status.begin('Trends across days');
    await t.pumpWidget(_host(line(), tickers: false));
    final before = clock.calls;
    clock.advance(5);
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 10));
    expect(clock.calls, before, reason: 'a hidden line does no work');

    await t.pumpWidget(_host(line(), tickers: true));
    clock.advance(1);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Trends across days · 0:06'), findsOneWidget,
        reason: 'visible again: it catches up from the clock, not a counter');

    status.end(token);
    await t.pump();
  });

  testWidgets('fits 360 pt, with a long label, at 1.5x text', (t) async {
    final token = status.begin(
        'Preparing the weekday effect and the journal insights for ninety days');
    clock.advance(754);
    await t.pumpWidget(_host(line(), scale: 1.5));
    expect(t.takeException(), isNull, reason: 'no overflow');
    expect(t.getSize(find.byType(CalcStatusLine)).width, lessThanOrEqualTo(360));
    expect(find.textContaining('12:34'), findsOneWidget,
        reason: 'the elapsed time survives a long label');
    status.end(token);
    await t.pump();
  });

  testWidgets('no timer after dispose (open step, then the line is removed)',
      (t) async {
    final token = status.begin('Reading recordings');
    await t.pumpWidget(_host(line()));
    clock.advance(1);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    final after = clock.calls;
    await t.pump(const Duration(seconds: 10));
    expect(clock.calls, after, reason: 'a removed line does not tick');
    status.end(token); // the status outlives the widget; no listener is left
    await t.pump();
    // The binding fails the test here if a Timer is still pending.
  });

  testWidgets('a status that changes after dispose does not touch the tree',
      (t) async {
    await t.pumpWidget(_host(line()));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    final token = status.begin('Late');
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull);
    status.end(token);
  });
}
