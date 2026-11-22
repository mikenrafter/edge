// CLAIM growing-tail: the oracle rejects a 2 px prefix move, and still reports
// growth below a stable prefix. This catches restoring the blanket exemption.
import 'package:flutter_test/flutter_test.dart';
import '../support/layout_shift/layout_shift.dart';
import '../support/tail_shift.dart';

void main() {
  test('tail growth is scored and cannot excuse prefix movement', () {
    const before = Frame(0, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 0, 100, 20),
        role: ElementRole.control,
      ),
      ElementSnapshot(id: 'tail', rect: ShiftRect(0, 40, 100, 20)),
    ]);
    const grown = Frame(1000, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 0, 100, 20),
        role: ElementRole.control,
      ),
      ElementSnapshot(id: 'tail', rect: ShiftRect(0, 40, 100, 80)),
    ]);
    final cost = checkGrowingTail(
      scenario: const Scenario(
        viewport: ShiftRect(0, 0, 390, 844),
        frames: [before, grown],
      ),
      pending: before,
      tailTop: 40,
      route: 'control',
    );
    expect(cost.prefix.total, 0);
    expect(cost.tail.total, greaterThan(0));
    const moved = Frame(1000, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 2, 100, 20),
        role: ElementRole.control,
      ),
    ]);
    expect(
      () => checkGrowingTail(
        scenario: const Scenario(
          viewport: ShiftRect(0, 0, 390, 844),
          frames: [before, moved],
        ),
        pending: before,
        tailTop: 40,
        route: 'mutation',
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  // Fix round 1, F7: a chart readout's TEXT may change width inside its keyed
  // slot (glyph widths follow the number), but it cannot move, change height or
  // leave the slot while the slot itself keeps its frame, and it cannot vanish.
  group('readout text under the prefix contract', () {
    const slotId = 'chart-key-value:Heart rate';
    const textId = '~text|$slotId|FittedBox<Expanded<Row#0';
    const button = ElementSnapshot(
      id: 'button',
      rect: ShiftRect(0, 0, 100, 20),
      role: ElementRole.control,
    );
    const slot = ElementSnapshot(id: slotId, rect: ShiftRect(0, 30, 120, 20));
    ElementSnapshot text(ShiftRect r) =>
        ElementSnapshot(id: textId, rect: r, role: ElementRole.paragraph);
    final pending = Frame(0, [button, slot, text(const ShiftRect(0, 30, 10, 20)),
      const ElementSnapshot(id: 'tail', rect: ShiftRect(0, 80, 100, 20))]);

    void run(Frame after) => checkGrowingTail(
          scenario: Scenario(
            viewport: const ShiftRect(0, 0, 390, 844),
            frames: [pending, after],
          ),
          pending: pending,
          tailTop: 80,
          route: 'readout',
        );

    test('a value that changes width inside its slot is allowed', () {
      run(Frame(1000, [
        button,
        slot,
        text(const ShiftRect(0, 30, 36, 20)),
        const ElementSnapshot(id: 'tail', rect: ShiftRect(0, 80, 100, 90)),
      ]));
    });

    test('readout text that moves while its slot holds still is a failure', () {
      expect(
        () => run(Frame(1000, [
          button,
          slot,
          text(const ShiftRect(0, 42, 36, 20)),
          const ElementSnapshot(id: 'tail', rect: ShiftRect(0, 80, 100, 90)),
        ])),
        throwsA(isA<TestFailure>()),
      );
    });

    test('readout text that outgrows its slot is a failure', () {
      expect(
        () => run(Frame(1000, [
          button,
          slot,
          text(const ShiftRect(0, 30, 140, 20)),
          const ElementSnapshot(id: 'tail', rect: ShiftRect(0, 80, 100, 90)),
        ])),
        throwsA(isA<TestFailure>()),
      );
    });

    test('readout text that disappears is a failure', () {
      expect(
        () => run(Frame(1000, [
          button,
          slot,
          const ElementSnapshot(id: 'tail', rect: ShiftRect(0, 80, 100, 90)),
        ])),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
