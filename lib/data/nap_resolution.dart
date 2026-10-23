// nap_resolution.dart — what keeping a nap does when it overlaps sleep.
//
// A kept nap that overlaps the main sleep or another nap EXTENDS that block to
// the union instead of being refused. [NapResolution] is the preview the user
// sees; a commit re-resolves inside its transaction and throws
// [NapResolutionChanged] (writing nothing) when the result no longer matches.

/// One block a kept nap overlaps. [kind] is 'main_sleep' or 'nap'; [day] is the
/// day_id that owns it.
typedef NapBlock = ({String kind, String day, int startTs, int endTs});

/// The bounds a kept nap ends up with (the union with every block it overlaps,
/// transitively; touching counts, a gap never does) and the blocks it extends.
typedef NapResolution = ({int startTs, int endTs, List<NapBlock> extended});

/// Thrown by a keep path when the re-resolved result differs from the one the
/// caller previewed. [now] is the current resolution; nothing was written.
class NapResolutionChanged implements Exception {
  NapResolutionChanged(this.now);
  final NapResolution now;
}
