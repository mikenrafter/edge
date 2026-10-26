import 'band_buzzer.dart';

class DefaultBandBuzzer implements BandBuzzer {
  DefaultBandBuzzer({
    required this.transport,
    required this.now,
    required this.delay,
    this.settleGap = const Duration(milliseconds: 600),
  });

  final BandBuzzTransport transport;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  final Duration settleGap;

  Future<void> _tail = Future<void>.value();
  final _stopped = <String>{};

  @override
  Future<BandBuzzResult> play(BandBuzzRequest request) {
    final result = _tail.then((_) => _play(request));
    _tail = result.then((_) {});
    return result;
  }

  Future<BandBuzzResult> _play(BandBuzzRequest request) async {
    final pulses = request.kind == BandBuzzKind.rampStep ? request.pulses : 1;
    if (pulses <= 0) return BandBuzzResult.refused;
    var sent = 0;
    try {
      for (var i = 0; i < pulses; i++) {
        if (_stopped.contains(request.scope) ||
            !now().isBefore(request.expiresAt)) {
          return sent == 0 ? BandBuzzResult.refused : BandBuzzResult.partial;
        }
        bool ok;
        try {
          ok = await (request.kind == BandBuzzKind.alarm
              ? transport.runAlarmChecked() : transport.buzzChecked());
        } finally {
          // Include the last pulse so the next queued cue also settles.
          await delay(settleGap);
        }
        if (!ok) {
          return sent == 0 ? BandBuzzResult.failed : BandBuzzResult.partial;
        }
        sent++;
      }
      return BandBuzzResult.complete;
    } catch (_) {
      return BandBuzzResult.uncertain;
    }
  }

  @override
  void stop(String scope) => _stopped.add(scope);
}
