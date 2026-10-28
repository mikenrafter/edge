// Red-phase stub: the synthetic exposure a taken-daily period stands for.
import '../data/track_model.dart';

class RangeExposures {
  RangeExposures({
    required Iterable<TrackSetupRange> ranges,
    required Iterable<TrackEvent> realEvents,
    required Iterable<({String trackId, String date})> absences,
  });

  /// The in-memory exposure for [trackId] on [date], or null.
  TrackEvent? on(String trackId, String date) =>
      throw UnimplementedError('RangeExposures.on');
}
