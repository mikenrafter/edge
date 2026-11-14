import 'package:flutter/painting.dart';

/// Plot painters declare their series pigment. Guide placeholders use the same
/// plot bounds and pigment, without axes, labels or data points.
abstract interface class GuidePlot {
  Color get guideLineColor;
}
