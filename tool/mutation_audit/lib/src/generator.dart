import 'dart:convert';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'mutant.dart';

/// All mutants of [source] (the text of [file]), in deterministic order:
/// ascending byte offset, then operator id, then replacement text.
///
/// One mutant per executable site and replacement; never inside comments,
/// string literals (interpolations included), import / export / part
/// directives or annotations. Source that does not parse yields no mutants.
List<Mutant> generateMutants(String source, {required String file}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  if (parsed.errors.isNotEmpty) return const [];
  final collector = _Collector(source, file, parsed.lineInfo);
  parsed.unit.accept(collector);
  collector.mutants.sort((a, b) {
    final byOffset = a.byteOffset.compareTo(b.byteOffset);
    if (byOffset != 0) return byOffset;
    final byOperator = a.operator.id.compareTo(b.operator.id);
    return byOperator != 0 ? byOperator : a.mutated.compareTo(b.mutated);
  });
  return collector.mutants;
}

/// The stable id of a mutant: `<file>:<byteOffset>:<operator id>:<hash>` where
/// hash is 8 lowercase hex digits of the FNV-1a 32-bit hash of the UTF-8
/// bytes of [mutated].
String mutantId({
  required String file,
  required int byteOffset,
  required MutationOperator operator,
  required String mutated,
}) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(mutated)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '$file:$byteOffset:${operator.id}:${hash.toRadixString(16).padLeft(8, '0')}';
}

/// [source] with [mutant] applied (replaces the bytes at its byte offset).
String mutatedSource(String source, Mutant mutant) {
  final bytes = utf8.encode(source);
  final out = <int>[
    ...bytes.sublist(0, mutant.byteOffset),
    ...utf8.encode(mutant.mutated),
    ...bytes.sublist(mutant.byteOffset + mutant.byteLength),
  ];
  return utf8.decode(out);
}

const _relationalSwap = {
  TokenType.LT: '<=',
  TokenType.LT_EQ: '<',
  TokenType.GT: '>=',
  TokenType.GT_EQ: '>',
  TokenType.EQ_EQ: '!=',
  TokenType.BANG_EQ: '==',
};

final _minInt64 = BigInt.parse('-9223372036854775808');
final _maxInt64 = BigInt.parse('9223372036854775807');

class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.source, this.file, this.lineInfo) {
    var ascii = true;
    for (final unit in source.codeUnits) {
      if (unit > 0x7f) {
        ascii = false;
        break;
      }
    }
    if (!ascii) {
      // Byte offset of every UTF-16 index (a surrogate pair is one 4-byte
      // character: its first unit carries 4 bytes, its second none).
      final map = Int32List(source.length + 1);
      var bytes = 0;
      for (var i = 0; i < source.length; i++) {
        map[i] = bytes;
        final unit = source.codeUnitAt(i);
        if (unit < 0x80) {
          bytes += 1;
        } else if (unit < 0x800) {
          bytes += 2;
        } else if (unit >= 0xD800 && unit <= 0xDBFF) {
          bytes += 4;
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
          // second half of a pair
        } else {
          bytes += 3;
        }
      }
      map[source.length] = bytes;
      _bytes = map;
    }
  }

  final String source;
  final String file;
  final LineInfo lineInfo;
  Int32List? _bytes;
  final List<Mutant> mutants = [];

  int _byteOffset(int index) => _bytes == null ? index : _bytes![index];

  void _add(MutationOperator op, int offset, int end, String mutated) {
    final original = source.substring(offset, end);
    final byteOffset = _byteOffset(offset);
    final location = lineInfo.getLocation(offset);
    mutants.add(Mutant(
      id: mutantId(file: file, byteOffset: byteOffset, operator: op, mutated: mutated),
      file: file,
      line: location.lineNumber,
      column: location.columnNumber,
      byteOffset: byteOffset,
      byteLength: _byteOffset(end) - byteOffset,
      operator: op,
      original: original,
      mutated: mutated,
    ));
  }

  // Nothing below these is executable code to mutate.
  @override
  void visitAnnotation(Annotation node) {}
  @override
  void visitImportDirective(ImportDirective node) {}
  @override
  void visitExportDirective(ExportDirective node) {}
  @override
  void visitPartDirective(PartDirective node) {}
  @override
  void visitPartOfDirective(PartOfDirective node) {}
  @override
  void visitLibraryDirective(LibraryDirective node) {}
  @override
  void visitStringInterpolation(StringInterpolation node) {}

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final op = node.operator;
    final swap = _relationalSwap[op.type];
    if (swap != null) {
      _add(MutationOperator.relational, op.offset, op.end, swap);
      _literalOperand(node.leftOperand);
      _literalOperand(node.rightOperand);
    } else if (op.type == TokenType.AMPERSAND_AMPERSAND) {
      _add(MutationOperator.logical, op.offset, op.end, '||');
    } else if (op.type == TokenType.BAR_BAR) {
      _add(MutationOperator.logical, op.offset, op.end, '&&');
    }
    super.visitBinaryExpression(node);
  }

  void _literalOperand(Expression operand) {
    var e = operand;
    while (e is ParenthesizedExpression) {
      e = e.expression;
    }
    if (e is! IntegerLiteral) return;
    final lexeme = e.literal.lexeme;
    if (!RegExp(r'^\d+$').hasMatch(lexeme)) return;
    final value = e.value;
    if (value == null) return;
    // BigInt: `value + 1` on the largest 64-bit literal wraps to the smallest
    // and would be "a different mutant" that is really nonsense. A replacement
    // outside the signed 64-bit range is skipped.
    for (final delta in const [-1, 1]) {
      final replacement = BigInt.from(value) + BigInt.from(delta);
      if (replacement < _minInt64 || replacement > _maxInt64) continue;
      _add(MutationOperator.intLiteral, e.offset, e.end, '$replacement');
    }
  }

  void _negate(Expression condition) {
    _add(MutationOperator.negateCondition, condition.offset, condition.end,
        '!(${source.substring(condition.offset, condition.end)})');
  }

  @override
  void visitIfStatement(IfStatement node) {
    _negate(node.expression);
    _removeReturns(node);
    super.visitIfStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _negate(node.condition);
    super.visitWhileStatement(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _negate(node.condition);
    super.visitConditionalExpression(node);
  }

  /// A `return` that is a direct statement of this if's then / else branch,
  /// when the outermost `if` of the else-if chain has a statement after it in
  /// its block.
  void _removeReturns(IfStatement node) {
    var outermost = node;
    while (outermost.parent is IfStatement &&
        (outermost.parent as IfStatement).elseStatement == outermost) {
      outermost = outermost.parent as IfStatement;
    }
    final block = outermost.parent;
    if (block is! Block) return;
    final at = block.statements.indexOf(outermost);
    if (at < 0 || at == block.statements.length - 1) return;
    for (final branch in [node.thenStatement, node.elseStatement]) {
      if (branch == null) continue;
      final direct = branch is Block ? branch.statements : [branch];
      for (final statement in direct) {
        if (statement is ReturnStatement) {
          _add(MutationOperator.removeReturn, statement.offset, statement.end, ';');
        }
      }
    }
  }
}
