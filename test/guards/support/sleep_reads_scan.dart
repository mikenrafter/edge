// AST-based whole-tree audit of projection readers. See phase2_5-spec §3.3.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import '../../step2/support/write_seam_scan.dart' show canonLocalDbMember;

typedef SleepReadSite = ({String table, String member, int line});
const sleepTables = {'sleep_nap','sleep_override'};
final _sql = RegExp(r'\b(?:FROM|JOIN)\s+(?:["`\[]?main["`\]]?\s*\.\s*)?["`\[]?(sleep_nap|sleep_override)["`\]]?(?![\w])',caseSensitive:false);
String _member(AstNode node) {
  AstNode? member; String? owner;
  for (AstNode? n=node; n!=null; n=n.parent) {
    if (n is MethodDeclaration || n is FieldDeclaration ||
        (n is FunctionDeclaration && n.parent is CompilationUnit) || n is TopLevelVariableDeclaration) { member=n; }
    owner ??= switch(n) {
      ClassDeclaration()=>n.namePart.typeName.lexeme,
      ExtensionDeclaration()=>n.name?.lexeme ?? 'extension',
      _=>null,
    };
  }
  final name = switch(member) {
    MethodDeclaration(:final name)=>name.lexeme,
    FunctionDeclaration(:final name)=>name.lexeme,
    FieldDeclaration(:final fields)=>fields.variables.first.name.lexeme,
    TopLevelVariableDeclaration(:final variables)=>variables.variables.first.name.lexeme,
    _=>'<top>',
  };
  return canonLocalDbMember(owner==null ? name : '$owner.$name');
}
class _Reads extends RecursiveAstVisitor<void> {
  _Reads(this.source,this.out);
  final String source; final List<SleepReadSite> out;
  void add(AstNode n,String table) => out.add((table:table,member:_member(n),line:'\n'.allMatches(source.substring(0,n.offset)).length+1));
  @override void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name=='query' && node.argumentList.arguments.isNotEmpty) {
      final first = node.argumentList.arguments.first;
      var literal = first;
      while (literal is ParenthesizedExpression) { literal = literal.expression; }
      if (literal is StringLiteral && sleepTables.contains(literal.stringValue)) { add(node,literal.stringValue!); }
    }
    super.visitMethodInvocation(node);
  }
  void sql(StringLiteral n) {
    // Adjacent literals and interpolated SQL must be read as one expression.
    if (n.parent is AdjacentStrings || n.parent is StringInterpolation) return;
    final text = n.stringValue ?? n.toSource();
    for (final m in _sql.allMatches(text)) {
      if (RegExp(r'DELETE\s*$',caseSensitive:false).hasMatch(text.substring(0,m.start))) continue;
      add(n,m[1]!.toLowerCase());
    }
  }
  @override void visitSimpleStringLiteral(SimpleStringLiteral node) { sql(node); }
  @override void visitAdjacentStrings(AdjacentStrings node) { sql(node); }
  @override void visitStringInterpolation(StringInterpolation node) { sql(node); }
}
List<SleepReadSite> scanSleepReads(String source) {
  final out=<SleepReadSite>[];
  parseString(content:source,throwIfDiagnostics:false).unit.accept(_Reads(source,out));
  return out;
}
