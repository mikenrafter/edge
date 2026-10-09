/// The five mutation operators (one documented rule each; see README.md).
enum MutationOperator {
  /// `<`<->`<=`, `>`<->`>=`, `==`<->`!=` on a binary expression.
  relational('relational'),

  /// An integer literal that is a direct operand of a comparison, +1 and -1.
  intLiteral('int-literal'),

  /// An if / while / ternary condition `c` becomes `!(c)`.
  negateCondition('negate-condition'),

  /// `&&`<->`||`.
  logical('logical'),

  /// A `return ...;` that is a direct statement of an if-branch is replaced by
  /// an empty statement `;`.
  removeReturn('remove-return');

  const MutationOperator(this.id);

  /// The name used in mutant ids and reports.
  final String id;
}

/// One mutant: a single text replacement at one executable site.
class Mutant {
  const Mutant({
    required this.id,
    required this.file,
    required this.line,
    required this.column,
    required this.byteOffset,
    required this.byteLength,
    required this.operator,
    required this.original,
    required this.mutated,
  });

  /// `<file>:<byteOffset>:<operator id>:<8 hex of the replacement hash>`.
  final String id;

  /// Path as given to the generator (relative to the export root).
  final String file;

  /// 1-based line and column (in characters) of the replaced text.
  final int line, column;

  /// UTF-8 byte offset and byte length of the replaced text in the file.
  final int byteOffset, byteLength;

  final MutationOperator operator;

  /// The replaced text and its replacement.
  final String original, mutated;

  Map<String, Object?> toJson() => {
        'id': id,
        'file': file,
        'line': line,
        'column': column,
        'byteOffset': byteOffset,
        'byteLength': byteLength,
        'operator': operator.id,
        'original': original,
        'mutated': mutated,
      };

  @override
  String toString() => '$id $original -> $mutated';
}
