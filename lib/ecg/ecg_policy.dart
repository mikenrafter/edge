// WHOOP MG ECG — the official foreground R17 state machine as a PURE reducer
// (docs/mg/05 §4, docs/mg/06 §6). No I/O, no clock, no BLE: one packet in,
// a new state plus a list of effects out. The controller performs the
// effects (restart command, persistence, cleanup); the UI renders the state.
//
// Transport frames are not the reading. Entering ECG produces zero /
// progress-zero packets for tens of seconds before the fingers touch; the
// accepted window starts at the first presence-positive, positive, non-255
// progress packet, clears on contact loss / progress regression, and ends at
// the first terminal packet. The frozen official capture is the oracle: 86
// transport frames → 30 accepted → 3,000 samples.

import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_models.dart';
import 'ecg_outcome.dart';

enum EcgPhase { waiting, active, contactLost, done }

/// The reducer's whole memory. Immutable; every step returns a new one.
class EcgReducerState {
  final EcgPhase phase;

  /// The accepted window so far, placeholders included, in order.
  final List<EcgAcceptedPacket> accepted;

  /// The last ACCEPTED packet (progress regression and sequence gaps are
  /// judged against it). Null after every clear — like the official
  /// accumulator, a window that restarts has no previous packet.
  final LabradorR17? previous;

  /// ACTIVE → CONTACT_LOST transitions so far. Once per transition, never per
  /// bad packet; a later loss while already lost does not count.
  final int interruptions;

  /// Inconclusive retries already offered and taken (0 or 1).
  final int retriesUsed;

  const EcgReducerState({
    required this.phase,
    required this.accepted,
    required this.previous,
    required this.interruptions,
    required this.retriesUsed,
  });

  /// A fresh WAITING state. [retriesUsed] is 1 on the single inconclusive
  /// retry, which is what makes a second inconclusive terminal final.
  const EcgReducerState.initial({int retriesUsed = 0})
    : this(
        phase: EcgPhase.waiting,
        accepted: const [],
        previous: null,
        interruptions: 0,
        retriesUsed: retriesUsed,
      );

  EcgReducerState _with({
    EcgPhase? phase,
    List<EcgAcceptedPacket>? accepted,
    LabradorR17? previous,
    bool clearPrevious = false,
    int? interruptions,
  }) => EcgReducerState(
    phase: phase ?? this.phase,
    accepted: accepted ?? this.accepted,
    previous: clearPrevious ? null : (previous ?? this.previous),
    interruptions: interruptions ?? this.interruptions,
    retriesUsed: retriesUsed,
  );
}

/// What the controller must do after a step, in order.
sealed class EcgEffect {
  const EcgEffect();
}

/// The packet was appended to the accepted window.
class EcgAppend extends EcgEffect {
  final LabradorR17 packet;
  const EcgAppend(this.packet);
}

/// One empty segment was inserted at [sequence] (previous + 1) before the
/// packet that jumped — never one per missing sequence.
class EcgAppendPlaceholder extends EcgEffect {
  final int sequence;
  const EcgAppendPlaceholder(this.sequence);
}

/// The accepted window was cleared.
class EcgClear extends EcgEffect {
  const EcgClear();
}

/// Send the explicit RESTART list (opcode 20, then 124 body 01 03). Only the
/// exact predicate reaches this: active, presence, positive nondecreasing
/// nonterminal progress, current-S2-state-1 flag clear.
class EcgSendRestart extends EcgEffect {
  const EcgSendRestart();
}

/// The reading failed; the window is gone.
class EcgFail extends EcgEffect {
  final String reason;
  const EcgFail(this.reason);
}

enum EcgTerminalKind {
  /// A band-reported category.
  completed,

  /// Band says unreadable (or its code / average rate maps to nothing); the
  /// mask says why. Saved as an attempt (design 04 R2).
  unreadable,

  /// Inconclusive on the first attempt: offer ONE retry. Saved as an attempt.
  inconclusiveOfferRetry,

  /// Inconclusive on the retry: the final reading.
  inconclusiveFinal,
}

/// The terminal packet's verdict. The heart rate that decides is the packet's
/// AVERAGE (offset 19), the one stored; the live rate (offset 20) is recorded
/// and shown but never branches anything (design 04: the live and the saved
/// verdict used to disagree). [persistedCategory] is the band's category for
/// that average, as stored with a saved reading.
class EcgTerminalOutcome {
  final EcgTerminalKind kind;
  final EcgCategory persistedCategory;
  final LabradorR17 terminal;

  /// Design 04 R2'': the window this terminal ended, terminal packet included,
  /// handed over BEFORE it is cleared, so every attempt (unreadable, first
  /// inconclusive, final) can be saved.
  final List<EcgAcceptedPacket> window;

  const EcgTerminalOutcome({
    required this.kind,
    required this.persistedCategory,
    required this.terminal,
    this.window = const [],
  });

  int get resultCode => terminal.result;
  int get averageHr => terminal.averageHr;
  int get liveHr => terminal.liveHr;
  int get unreadableMask => terminal.unreadable.raw;
  int get quality => terminal.quality;
}

/// The reading reached a terminal packet.
class EcgTerminal extends EcgEffect {
  final EcgTerminalOutcome outcome;
  const EcgTerminal(this.outcome);
}

class EcgReducerStep {
  final EcgReducerState state;
  final List<EcgEffect> effects;
  const EcgReducerStep(this.state, this.effects);
}

bool _acceptableStart(LabradorR17 f) =>
    f.presence && f.progress > 0 && f.progress != 255;

/// Append [f] to [s]'s window, inserting the single official placeholder on
/// a sequence jump. Returns the new packet list and the effects to report.
(List<EcgAcceptedPacket>, List<EcgEffect>) _append(
  EcgReducerState s,
  LabradorR17 f,
) {
  final out = List<EcgAcceptedPacket>.from(s.accepted);
  final effects = <EcgEffect>[];
  final prev = s.previous;
  if (prev != null && f.sequence != prev.sequence + 1) {
    out.add(EcgAcceptedPacket.placeholder(prev.sequence + 1));
    effects.add(EcgAppendPlaceholder(prev.sequence + 1));
  }
  out.add(EcgAcceptedPacket.of(f));
  effects.add(EcgAppend(f));
  return (out, effects);
}

/// One R17 packet through the official state machine.
EcgReducerStep reduceEcg(EcgReducerState s, LabradorR17 f) {
  switch (s.phase) {
    case EcgPhase.done:
      // A repeated terminal (the band re-sends it) is not part of the result.
      return EcgReducerStep(s, const []);

    case EcgPhase.waiting:
      if (!_acceptableStart(f)) return EcgReducerStep(s, const []);
      final (accepted, effects) = _append(s._with(accepted: const []), f);
      return EcgReducerStep(
        s._with(phase: EcgPhase.active, accepted: accepted, previous: f),
        [const EcgClear(), ...effects],
      );

    case EcgPhase.active:
      final prev = s.previous;
      final lost =
          !f.presence ||
          f.progress == 0 ||
          (prev != null && f.progress < prev.progress);
      if (lost) {
        return EcgReducerStep(
          s._with(
            phase: EcgPhase.contactLost,
            accepted: const [],
            clearPrevious: true,
            interruptions: s.interruptions + 1,
          ),
          const [EcgClear()],
        );
      }
      if (f.isTerminal) return _terminal(s, f);
      if (f.isInvalid) {
        return EcgReducerStep(
          s._with(
            phase: EcgPhase.done,
            accepted: const [],
            clearPrevious: true,
          ),
          const [EcgClear(), EcgFail('progress_255')],
        );
      }
      if (f.flags.currentS2One) {
        final (accepted, effects) = _append(s, f);
        return EcgReducerStep(
          s._with(accepted: accepted, previous: f),
          effects,
        );
      }
      // Valid, nondecreasing, nonterminal, presence set, S2-state-1 flag
      // clear: the distinct explicit-RESTART branch. Only the unfinished
      // window is discarded; interruptions and the retry budget stay.
      return EcgReducerStep(
        s._with(accepted: const [], clearPrevious: true),
        const [EcgClear(), EcgSendRestart()],
      );

    case EcgPhase.contactLost:
      if (_acceptableStart(f)) {
        final (accepted, effects) = _append(s, f);
        return EcgReducerStep(
          s._with(phase: EcgPhase.active, accepted: accepted, previous: f),
          effects,
        );
      }
      if (f.isInvalid || s.interruptions >= 3) {
        return EcgReducerStep(
          s._with(
            phase: EcgPhase.done,
            accepted: const [],
            clearPrevious: true,
          ),
          [
            const EcgClear(),
            EcgFail(f.isInvalid ? 'progress_255' : 'interruptions'),
          ],
        );
      }
      return EcgReducerStep(s, const []);
  }
}

EcgReducerStep _terminal(EcgReducerState s, LabradorR17 f) {
  // The band's own verdict on its bytes, decided by the one outcome function
  // (never a second table lookup here). The reason MASK is not part of this:
  // it spans the whole window and is folded by the controller into the saved
  // reading, where ecgOutcome applies it; the flow below follows what the band
  // said, so a stored status/category is always the band's.
  final band = ecgOutcomeOf(
    resultCode: f.result,
    avgHr: f.averageHr,
    mask: 0,
  );
  final category = ecgBandCategory(f.result, f.averageHr);
  // The window this terminal ends, terminal packet included, handed over
  // BEFORE it is cleared so an unreadable or first-inconclusive attempt can be
  // saved as what it was. A finished reading's window is the official
  // accumulator's (a sequence jump gets its one placeholder); an attempt's is
  // exactly the packets accepted plus the terminal one.
  final (appended, appendEffects) = _append(s, f);
  final isFinal = band.kind == EcgOutcomeKind.bandResult ||
      (band.kind == EcgOutcomeKind.inconclusive && s.retriesUsed != 0);
  final window = isFinal
      ? appended
      : [...s.accepted, EcgAcceptedPacket.of(f)];
  EcgReducerStep finish(
    EcgTerminalKind kind,
    List<EcgAcceptedPacket> accepted,
    List<EcgEffect> pre,
  ) {
    return EcgReducerStep(
      s._with(phase: EcgPhase.done, accepted: accepted, previous: f),
      [
        ...pre,
        EcgTerminal(
          EcgTerminalOutcome(
            kind: kind,
            persistedCategory: category,
            terminal: f,
            window: window,
          ),
        ),
      ],
    );
  }

  switch (band.kind) {
    case EcgOutcomeKind.notReadable:
      return finish(EcgTerminalKind.unreadable, const [], const [EcgClear()]);
    case EcgOutcomeKind.inconclusive when s.retriesUsed == 0:
      return finish(EcgTerminalKind.inconclusiveOfferRetry, const [], const [
        EcgClear(),
      ]);
    case EcgOutcomeKind.inconclusive:
      return finish(EcgTerminalKind.inconclusiveFinal, window, appendEffects);
    case EcgOutcomeKind.bandResult:
    case EcgOutcomeKind.partial:
      return finish(EcgTerminalKind.completed, window, appendEffects);
  }
}
