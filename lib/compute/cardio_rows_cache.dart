// Compatibility seam for the reviewed main checkpoint reader. The fork's
// registered staging worker and this reader use the same codec owner.
import 'dart:typed_data';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../util/heavy.dart';
import 'cardio_rows_blob.dart';
export 'cardio_rows_blob.dart' show CardioRowsChunk;

@heavy
ana.CardioRowCache decodeCardioRowsHeavy(List<Uint8List> chunks) =>
    mergeCardioRowChunksHeavy(chunks);
