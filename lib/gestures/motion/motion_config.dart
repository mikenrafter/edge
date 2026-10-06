// Every threshold the motion recognizer uses, in one place, with its unit and
// where the number came from. Values were chosen from the owner's 2026-10-06
// recordings (WHOOP MG, firmware 50.39.1.0, right wrist); the recorded
// evidence is in the phase-3 report, not here. They are starting points for
// on-device validation, not tuned constants.
//
// Pure Dart, isolate-safe.

class MotionConfig {
  const MotionConfig({
    // Segmentation.
    this.onsetDps = 150,
    this.offsetDps = 50,
    this.smoothSamples = 3,
    this.quietHoldSec = 0.35,
    this.mergeGapSec = 1.5,
    this.maxRemnantSec = 0.6,
    this.maxGroupSec = 6.0,
    // Twist lobes.
    this.lobeEdgeDps = 80,
    this.strongAngleDeg = 70,
    this.strongPeakDps = 800,
    this.minStrongLobes = 2,
    this.maxStrongLobes = 8,
    this.minTwistConcentration = 0.8,
    this.concentrationFloorDps = 100,
    // Claps.
    this.clapImpulseG = 4.0,
    this.clapProminenceG = 2.5,
    this.clapMinSeparationSec = 0.15,
    this.clapApproachDps = 150,
    this.clapApproachSec = 0.25,
    this.clapMaxConcurrentDps = 800,
    this.maxClaps = 5,
    // Data sufficiency.
    this.minRunSec = 0.5,
    this.minValidFraction = 0.8,
    // Gyro bias.
    this.biasWindowSec = 0.5,
    this.biasMaxSpeedDps = 15,
    this.biasMaxAccelDevG = 0.08,
    // Gravity.
    this.gravityInitSec = 0.15,
    this.gravityInitMaxDps = 60,
    this.gravityTrustG = 0.12,
    this.gravityTauSec = 0.5,
    this.gravityMaxCoastSec = 0.6,
    // Movement energy.
    this.energyActiveDps = 40,
    this.energyMinCoverage = 0.7,
  });

  /// Smoothed angular speed that opens a motion window / keeps it open.
  /// Resting hands sit at 2-30 dps; the weakest recorded twist lobe is
  /// 1000+ dps.
  final double onsetDps;
  final double offsetDps;
  final int smoothSamples;

  /// Quiet needed below [offsetDps] to close a window.
  final double quietHoldSec;

  /// Windows closer than this belong to one gesture attempt (wind-up, then
  /// the motion; repeated twists).
  final double mergeGapSec;

  /// A window already running when the stream starts, shorter than this, is the
  /// tail of something that began before the stream: skipped.
  final double maxRemnantSec;

  /// A gesture attempt longer than this is sustained activity, not a gesture.
  final double maxGroupSec;

  /// Twist-axis speed below which a lobe ends.
  final double lobeEdgeDps;

  /// A lobe counts as a deliberate turn above both of these. The owner's
  /// out-lobes are 94-170 degrees at 1500-2000 (clipped) dps.
  final double strongAngleDeg;
  final double strongPeakDps;

  /// Out and back is two lobes; three repetitions are six.
  final int minStrongLobes;
  final int maxStrongLobes;

  /// Share of rotational energy (over samples above [concentrationFloorDps])
  /// that must lie along the twist axis. The owner's twists: 0.95-0.99.
  final double minTwistConcentration;
  final double concentrationFloorDps;

  /// A clap is a 1-2 sample spike of |accel| above this (g) at the end of a
  /// hand swing. Recorded claps: 5.3-8.8 g.
  final double clapImpulseG;

  /// The spike must rise this far above |accel| four samples either side.
  /// Recorded claps rise 4-7 g; the broadest circle bump rose 0.7.
  final double clapProminenceG;
  final double clapMinSeparationSec;
  final double clapApproachDps;
  final double clapApproachSec;

  /// A spike while the gyro is this fast is the centripetal kick of a twist.
  final double clapMaxConcurrentDps;
  final int maxClaps;

  /// Shortest run of valid samples a decision may rest on.
  final double minRunSec;

  /// Share of the observation that must be valid samples.
  final double minValidFraction;

  /// A still interval for bias: speed and |accel|-1 stay within these for
  /// [biasWindowSec].
  final double biasWindowSec;
  final double biasMaxSpeedDps;
  final double biasMaxAccelDevG;

  /// Gravity starts from a quiet moment (speed below [gravityInitMaxDps],
  /// |accel| within [gravityTrustG] of 1 g for [gravityInitSec]), is corrected
  /// toward trusted accel with time constant [gravityTauSec], and is dropped
  /// after [gravityMaxCoastSec] without trusted accel.
  final double gravityInitSec;
  final double gravityInitMaxDps;
  final double gravityTrustG;
  final double gravityTauSec;
  final double gravityMaxCoastSec;

  final double energyActiveDps;
  final double energyMinCoverage;
}
