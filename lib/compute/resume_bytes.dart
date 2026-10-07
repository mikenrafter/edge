import 'dart:typed_data';

// Fixed-layout reader/writer for the resumable day state blob. Big-endian, no
// padding, no self-describing tags: the layout is the format version
// (`kDayCheckpointFmt`), and a reader that meets bytes it does not expect
// throws [FormatException] so the caller treats the blob as unusable rather
// than reading part of it.

class ResumeWriter {
  final BytesBuilder _out = BytesBuilder(copy: true);
  final ByteData _s = ByteData(8);

  void u8(int v) => _out.addByte(v & 0xff);
  void bool_(bool v) => u8(v ? 1 : 0);

  void i32(int v) {
    _s.setInt32(0, v);
    _out.add(_s.buffer.asUint8List(0, 4));
  }

  void i64(int v) {
    _s.setInt64(0, v);
    _out.add(_s.buffer.asUint8List(0, 8));
  }

  void f64(double v) {
    _s.setFloat64(0, v);
    _out.add(_s.buffer.asUint8List(0, 8));
  }

  /// A presence byte then the value, for a nullable int.
  void optI64(int? v) {
    bool_(v != null);
    if (v != null) i64(v);
  }

  void optF64(double? v) {
    bool_(v != null);
    if (v != null) f64(v);
  }

  Uint8List takeBytes() => _out.takeBytes();
}

class ResumeReader {
  ResumeReader(Uint8List bytes) : _d = ByteData.sublistView(bytes);
  final ByteData _d;
  int _at = 0;

  int get remaining => _d.lengthInBytes - _at;

  void _need(int n) {
    if (n < 0 || _at + n > _d.lengthInBytes) {
      throw const FormatException('resume state truncated');
    }
  }

  int u8() {
    _need(1);
    return _d.getUint8(_at++);
  }

  bool bool_() {
    final v = u8();
    if (v > 1) throw const FormatException('resume state: bad flag');
    return v == 1;
  }

  int i32() {
    _need(4);
    final v = _d.getInt32(_at);
    _at += 4;
    return v;
  }

  int i64() {
    _need(8);
    final v = _d.getInt64(_at);
    _at += 8;
    return v;
  }

  double f64() {
    _need(8);
    final v = _d.getFloat64(_at);
    _at += 8;
    return v;
  }

  int? optI64() => bool_() ? i64() : null;
  double? optF64() => bool_() ? f64() : null;

  /// A length for a list or map that must fit the bytes still unread at
  /// [bytesPerEntry] each, so a corrupt count cannot ask for gigabytes.
  int count(int bytesPerEntry) {
    final n = i32();
    if (n < 0 || n * bytesPerEntry > remaining) {
      throw const FormatException('resume state: bad count');
    }
    return n;
  }
}

/// 32-bit FNV-1a over [bytes] up to [end], to tell a torn or damaged blob from
/// a good one. Not a security measure.
int checksum32(Uint8List bytes, int end) {
  var h = 0x811c9dc5;
  for (var i = 0; i < end; i++) {
    h ^= bytes[i];
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}
