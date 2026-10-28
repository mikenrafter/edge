// What produced a night's stages when the experimental sleep model was asked
// (analytics d876c427). Read side only: the analytics package writes the keys,
// edge forwards them into the stored night and shows them. A value of the wrong
// type is dropped (unknown), never turned into another value; a fallback reason
// this build does not know is kept as text and shown generically.

/// Reasons this build can name. Anything else is "a reason we do not know".
const String kStagingFallbackDegenerate = 'hmm628_degenerate';

/// The staging keys of a stored `sleep` section that are safe to serve.
/// `staging_method` (the REQUESTED method), `staging_effective_method`,
/// `staging_fallback` and `staging_fallback_sec`, each only if well formed.
Map<String, Object> stagingProvenanceOf(Map<String, dynamic>? sleep) {
  if (sleep == null) return const {};
  final method = sleep['staging_method'];
  final effective = sleep['staging_effective_method'];
  final fallback = sleep['staging_fallback'];
  final sec = sleep['staging_fallback_sec'];
  return {
    if (method is String) 'staging_method': method,
    if (effective is String) 'staging_effective_method': effective,
    if (fallback is String) 'staging_fallback': fallback,
    // Seconds are only meaningful beside a reason.
    if (fallback is String && sec is num && sec.isFinite && sec >= 0)
      'staging_fallback_sec': sec.round(),
  };
}
