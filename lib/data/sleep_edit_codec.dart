// sleep_edit_codec.dart — the one codec for the sleep-edit envelope.
//
// The envelope lives in the nullable `payload_json` of `sleep_override` and
// `sleep_nap`, under the namespaced key [kSleepEditKey], BESIDE the retained
// measurement keys the base already stores there (asleep minutes, confidence,
// stage ranges). Retained keys are kept verbatim; metadata never overwrites
// them. It goes through [JsonPayloadLane], so large JSON never lands on the UI
// isolate (spec §2, §5.2).
//
// Parse on read: a null, blank, wrong-typed, unknown-version or invalid-bounds
// payload is [EnvelopeUnavailable] (history-dependent actions disabled, safe
// retained keys still served). It is never guessed into a wrong value, and a
// failed encode throws instead of serializing `{}` over real history.

import 'json_payload_lane.dart';
import 'sleep_editor.dart';

/// The envelope's namespace inside a stored payload.
const String kSleepEditKey = 'sleep_edit';

class SleepEditCodec {
  const SleepEditCodec._();

  static Future<EnvelopeRead> read(String? payloadJson) async {
    if (payloadJson == null || payloadJson.trim().isEmpty) {
      return const EnvelopeUnavailable({}, 'blank payload');
    }
    final Object? decoded;
    try {
      decoded = await JsonPayloadLane.shared.decodeUncached(payloadJson);
    } catch (_) {
      return const EnvelopeUnavailable({}, 'malformed payload');
    }
    if (decoded is! Map) return const EnvelopeUnavailable({}, 'not an object');
    final retained = <String, Object?>{
      for (final e in decoded.entries)
        if (e.key is String && e.key != kSleepEditKey) e.key as String: e.value,
    };
    final raw = decoded[kSleepEditKey];
    if (raw == null) return EnvelopeUnavailable(retained, 'no history recorded');
    if (raw is! Map) return EnvelopeUnavailable(retained, 'envelope wrong type');
    if (raw['v'] != kSleepEditEnvelopeVersion) {
      return EnvelopeUnavailable(retained, 'unknown envelope version');
    }
    final detected = _detected(raw['detected']);
    final origin = _origin(raw['origin']);
    final stages = _stages(raw['stages']);
    if (detected == null || origin == null || stages == _bad) {
      return EnvelopeUnavailable(retained, 'invalid envelope contents');
    }
    return EnvelopeOk(
      retained,
      SleepEditEnvelope(
        origin: origin,
        detected: detected,
        stages: identical(stages, _none) ? null : stages as StageResult,
      ),
    );
  }

  /// [retained] plus the envelope as one stored text.
  static Future<String> write(
      Map<String, Object?> retained, SleepEditEnvelope envelope) async {
    final text = await JsonPayloadLane.shared.encode({
      for (final e in retained.entries)
        if (e.key != kSleepEditKey) e.key: e.value,
      kSleepEditKey: {
        'v': envelope.version,
        'origin': {
          'suppressed': [
            for (final s in envelope.origin.suppressed)
              {'day': s.day, 'start': s.startTs, 'end': s.endTs},
          ],
          if (envelope.origin.mergedInto != null)
            'merged_into': envelope.origin.mergedInto,
        },
        'detected': switch (envelope.detected) {
          DetectedKnown(
            :final startTs,
            :final endTs,
            :final sourceDay,
            :final measures,
          ) =>
            {
              'state': 'known',
              'start': startTs,
              'end': endTs,
              'day': sourceDay,
              if (measures.isNotEmpty) 'measures': measures,
            },
          DetectedAbsent() => {'state': 'absent'},
          // Unavailable is a READ state; writing it would invent history.
          DetectedUnavailable() => throw StateError(
              'cannot store unavailable history'),
        },
        if (envelope.stages != null)
          'stages': {
            'start': envelope.stages!.startTs,
            'end': envelope.stages!.endTs,
            'payload': envelope.stages!.payload,
          },
      },
    });
    if (text == null) throw StateError('sleep edit envelope did not encode');
    return text;
  }

  static const Object _none = Object();
  static const Object _bad = Object();

  static bool _interval(Object? s, Object? e) =>
      s is int && e is int && s > 0 && e > s;

  static DetectedHistory? _detected(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['state']) {
      case 'absent':
        return const DetectedAbsent();
      case 'known':
        final day = raw['day'];
        if (!_interval(raw['start'], raw['end']) || day is! String) return null;
        final m = raw['measures'];
        if (m != null && m is! Map) return null;
        return DetectedKnown(
          startTs: raw['start'] as int,
          endTs: raw['end'] as int,
          sourceDay: day,
          measures: {
            if (m is Map)
              for (final e in m.entries) '${e.key}': e.value,
          },
        );
    }
    return null;
  }

  static OriginRef? _origin(Object? raw) {
    if (raw == null) return const OriginRef();
    if (raw is! Map) return null;
    final list = raw['suppressed'];
    if (list != null && list is! List) return null;
    final out = <SuppressedInterval>[];
    for (final s in (list as List?) ?? const []) {
      if (s is! Map || s['day'] is! String || !_interval(s['start'], s['end'])) {
        return null;
      }
      out.add(SuppressedInterval(s['day'] as String, s['start'] as int,
          s['end'] as int));
    }
    final into = raw['merged_into'];
    if (into != null && into is! String) return null;
    return OriginRef(suppressed: out, mergedInto: into as String?);
  }

  /// [_none] when absent, [_bad] when present but invalid.
  static Object _stages(Object? raw) {
    if (raw == null) return _none;
    if (raw is! Map || !_interval(raw['start'], raw['end'])) return _bad;
    final p = raw['payload'];
    if (p != null && p is! Map) return _bad;
    return StageResult(
      startTs: raw['start'] as int,
      endTs: raw['end'] as int,
      payload: {
        if (p is Map) for (final e in p.entries) '${e.key}': e.value,
      },
    );
  }
}
