enum BandBuzzKind { alarm, steadyStep, rampStep }

enum BandBuzzResult { complete, partial, refused, failed, uncertain }

class BandBuzzRequest {
  const BandBuzzRequest({
    required this.id,
    required this.scope,
    required this.expiresAt,
    required this.kind,
    required this.stepIndex,
    required this.stepCount,
    required this.pulses,
  });

  final String id;
  final String scope;
  final DateTime expiresAt;
  final BandBuzzKind kind;
  final int stepIndex;
  final int stepCount;
  final int pulses;
}

abstract interface class BandBuzzer {
  Future<BandBuzzResult> play(BandBuzzRequest request);
  void stop(String scope);
}

abstract interface class BandBuzzTransport {
  Future<bool> runAlarmChecked();
  Future<bool> buzzChecked();
}
