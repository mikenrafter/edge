import 'dart:typed_data';

/// An append-only byte list that doubles a typed buffer, so a day's worth of
/// per-second values costs one byte each instead of a boxed int's eight.
class GrowableBytes {
  GrowableBytes() : _b = Uint8List(256);

  /// Takes [bytes] as the first [length] entries (the buffer is kept).
  GrowableBytes.of(Uint8List bytes)
      : _b = bytes.isEmpty ? Uint8List(256) : bytes,
        length = bytes.length;

  Uint8List _b;
  int length = 0;

  int operator [](int i) => _b[i];

  void add(int v) {
    if (length == _b.length) {
      _b = Uint8List(_b.length * 2)..setRange(0, length, _b);
    }
    _b[length++] = v;
  }

  void addAll(Uint8List v) {
    for (final b in v) {
      add(b);
    }
  }

  void clear() => length = 0;

  /// The entries as a view, for writing out.
  Uint8List get view => Uint8List.sublistView(_b, 0, length);
}
