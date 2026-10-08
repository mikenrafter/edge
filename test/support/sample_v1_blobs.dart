// Codec VERSION 1 blobs (the lossy-DCT generation), frozen from the encoder as
// it stood before the codec swap. They pin that a build which writes a newer
// version still READS these: decode, summary, header, runs. Never regenerate.
//
// Series (400 slots, a gap at [130, 160)):
//   hr  = (70 + 8 sin(i/23) + (i % 5)).roundToDouble()
//   ax  = 0.3 + (i % 11) * 0.004
// Each entry: hex, decoded-sample sum (6 dp), samples at 0, 1, 129, 160, 399.
import 'dart:typed_data';

class V1Blob {
  const V1Blob(this.hex, this.sum, this.probes);
  final String hex;
  final double sum;
  final List<double>? probes;
  Uint8List get bytes => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ]);
}

const v1HrAdaptive = V1Blob(
    '4f5350580100026872f001000000000000e03f9003f202020829083b63686294fbc00800b3d9c6c4cf69a3ca23242725ce6fc328226023c92d6ca3c5c3a1a1cdc5f389494c54f81313039400006b62e4fac0280600536060606060d4666434646440003f4630086764647c20f986d1375e92575545546c82b283d721a64c436141764e76764e4143233e0e4e59392e00',
    26807.978627,
    [72.947118, 73.475904, 66.756101, 77.727416, 64.279953]);

const v1HrStatic = V1Blob(
    '4f5350580101026872f001000000000000e03f9003f2020308290a3963686294fbc00800b3d9c6c4cf69a3ca23242725ce6fc328226023c92d6ca3c5c3a1a1cdc5f389494c54f81313039400006b62e40ae058c0c80100936260606060d4666434640431a418654134038315a3fd03c9378cbef192bcaa2aa2620da233189d7965650485a6c818ce67d292d0d4900000',
    26802.444914,
    [72.947118, 73.475904, 66.756101, 77.784521, 63.933790]);

const v1AxLossless = V1Blob(
    '4f5350580102026178f001fca9f1d24d62703f9003f202000818021163686294fbc00800b359c0c8ca6ac3c0ca2ac700a16158838195f513130a01000300639cc6c80407c203c3641e40bb07820900',
    118.368000,
    [0.300000, 0.304000, 0.332000, 0.324000, 0.312000]);

const v1AxPyramid = V1Blob(
    '4f5350580103026178f001fca9f1d24d62703f9003f202000818020263686294fbc00800b359c0c8ca6ac3c0ca2ac700a16158838195f513130a010003000300',
    0.000000,
    null);
