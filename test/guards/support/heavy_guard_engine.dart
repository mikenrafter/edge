// heavy_guard_engine.dart — the resolved-AST engine behind the heavy-calculation
// guard (design 02, revisions 1-7 plus the owner's step-1 decisions).
//
// One pass resolves every library under `<packageRoot>/lib` with package:analyzer
// (no lint plugin), collects per-declaration FACTS (every invocation, tear-off,
// loop, string, banned type), then evaluates the rules in heavy_guard.dart's
// [HeavyRule] over those facts. Findings carry no line numbers.
//
// Vocabulary
//   decl    a function, method, constructor, field initializer or top-level
//           variable initializer. Closures belong to their enclosing decl.
//   heavy   a decl whose override-group has an `@heavy` member (a base method
//           with a heavy override is heavy too).
//   use     one invocation / instance creation / tear-off inside a decl.
//   group   a method and everything it overrides or is overridden by.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:openstrap_edge/util/worker_entries.dart' show Dispatcher;

import 'dart_sdk.dart';
import 'heavy_guard.dart';

// ---------------------------------------------------------------------------
// Shared analysis collections
// ---------------------------------------------------------------------------

final Map<String, AnalysisContextCollection> _collections = {};

Future<void> disposeCaches() async {
  final all = _collections.values.toList();
  _collections.clear();
  for (final c in all) {
    await c.dispose();
  }
}

List<String> _packagesIn(String group) => [
      for (final e in Directory(group).listSync().whereType<Directory>())
        if (!e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('_') &&
            File('${e.path}/.dart_tool/package_config.json').existsSync())
          e.path,
    ];

Future<AnalysisContext> _contextFor(HeavyGuardConfig c) async {
  final key = c.contextGroup ?? c.packageRoot;
  final collection = _collections[key] ??= AnalysisContextCollection(
    includedPaths: c.contextGroup != null
        ? _packagesIn(c.contextGroup!)
        : ['${c.packageRoot}/lib'],
    sdkPath: dartSdkPath(),
  );
  final context = collection.contextFor('${c.packageRoot}/lib');
  if (c.contextGroup != null) {
    // Fixture sources are edited between runs; tell the analyzer.
    for (final f in Directory('${c.packageRoot}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      context.changeFile(f.path);
    }
    await context.applyPendingFileChanges();
  }
  return context;
}

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

enum _UseKind { call, create, tearoff }

class _Use {
  final _Decl decl;
  final AstNode node;
  final Element? element;
  final _UseKind kind;

  /// Source text of the invocation, whitespace collapsed (fingerprint input).
  final String src;

  /// Nearest enclosing function literal inside the decl, if any.
  final FunctionExpression? closure;

  /// This use is the direct entry of an approved dispatcher: either inside the
  /// dispatcher's closure literal (not nested deeper) or the tear-off passed as
  /// the dispatcher's first argument.
  final DispatcherRef? dispatcher;

  _Use(this.decl, this.node, this.element, this.kind, this.src, this.closure,
      this.dispatcher);
}

class _Loop {
  final AstNode node;
  final bool bounded;
  _Loop(this.node, this.bounded);
}

class _Dispatch {
  final _Decl decl;
  final MethodInvocation node;
  final DispatcherRef ref;
  final Expression? arg0;
  _Dispatch(this.decl, this.node, this.ref, this.arg0);
}

class _Decl {
  final String file;
  final String symbol;
  final String container;
  final Element? element; // null for variable initializers
  final AstNode node;
  final String content;
  bool isHeavy = false;
  bool isLive = false;
  bool markedHeavy = false;

  final uses = <_Use>[];
  final loops = <_Loop>[];
  final dispatches = <_Dispatch>[];
  final bannedSeen = <String>{};
  final strings = StringBuffer();
  final rowBatchIterations = <(AstNode, String)>[];

  /// Iterations of stored-data collections (label = `Type.member`).
  final storedIterations = <String>[];

  _Decl(this.file, this.symbol, this.container, this.element, this.node,
      this.content);
}

// ---------------------------------------------------------------------------
// Helpers on elements / types
// ---------------------------------------------------------------------------

final _ws = RegExp(r'\s+');
String _collapse(String s) => s.replaceAll(_ws, ' ').trim();

bool _hasMarker(Element e, String name) {
  for (final a in e.metadata.annotations) {
    final el = a.element;
    if (el == null) continue;
    final n = el is ConstructorElement ? el.enclosingElement.name : el.name;
    final uri = el.library?.uri.toString() ?? '';
    if (n == name && uri.endsWith('util/heavy.dart')) return true;
  }
  return false;
}

String _label(Element e) {
  final enc = e.enclosingElement;
  var n = e.name ?? '';
  if (e is ConstructorElement && n == 'new') n = 'new';
  if (enc is InterfaceElement || enc is ExtensionElement) {
    return '${enc!.name ?? '<ext>'}.$n';
  }
  return n;
}

bool _isFunctionish(Element? e) =>
    e is TopLevelFunctionElement ||
    e is MethodElement ||
    e is LocalFunctionElement;

bool _isRowBatch(DartType? t) =>
    t is InterfaceType &&
    t.element.name == 'RowBatch' &&
    (t.element.library.uri.toString().endsWith('util/raw_readers.dart'));

String _uri(Element e) => e.library?.uri.toString() ?? '';

// ---------------------------------------------------------------------------
// Scan: collects the facts of one decl body
// ---------------------------------------------------------------------------

class _Scan extends RecursiveAstVisitor<void> {
  final _Decl decl;
  final HeavyGuardConfig config;
  final List<FunctionExpression> closures = [];
  final Map<FunctionExpression, DispatcherRef> dispatcherClosures = {};
  final Set<AstNode> dispatcherTearoffs = {};
  final Map<AstNode, DispatcherRef> tearoffRef = {};

  _Scan(this.decl, this.config);

  DispatcherRef? _dispatcherFor(Element? e) {
    if (e is! ExecutableElement) return null;
    final label = _label(e);
    final uri = _uri(e);
    for (final d in config.approvedDispatchers) {
      if (d.name == label && uri.startsWith(d.libraryPrefix)) return d;
    }
    return null;
  }

  String _src(AstNode n) =>
      _collapse(decl.content.substring(n.offset, n.end));

  FunctionExpression? get _closure => closures.isEmpty ? null : closures.last;

  DispatcherRef? get _directDispatcher {
    final c = _closure;
    return c == null ? null : dispatcherClosures[c];
  }

  void _use(AstNode node, Element? el, _UseKind kind, {DispatcherRef? ref}) {
    decl.uses.add(_Use(decl, node, el, kind, _src(node), _closure,
        ref ?? (kind == _UseKind.tearoff ? tearoffRef[node] : _directDispatcher)));
  }

  void _banned(Element? e) {
    if (e is InterfaceElement && config.bannedPlatformTypes.contains(e.name)) {
      decl.bannedSeen.add(e.name!);
    }
  }

  void _bannedType(DartType? t) {
    if (t is InterfaceType) _banned(t.element);
  }

  // --- structure ---

  @override
  void visitAnnotation(Annotation node) {}

  @override
  void visitComment(Comment node) {}

  @override
  void visitFunctionExpression(FunctionExpression node) {
    closures.add(node);
    super.visitFunctionExpression(node);
    closures.removeLast();
  }

  // --- invocations ---

  void _noteDispatcher(InvocationExpression node, Element? el, SimpleIdentifier? name) {
    final ref = _dispatcherFor(el);
    if (ref == null) return;
    final args = node.argumentList.arguments;
    final positional = args.where((a) => a is! NamedExpression).toList();
    Expression? arg0 = positional.isEmpty ? null : positional.first;
    while (arg0 is ParenthesizedExpression) {
      arg0 = arg0.expression;
    }
    if (node is MethodInvocation) {
      decl.dispatches.add(_Dispatch(decl, node, ref, arg0));
    }
    if (arg0 is FunctionExpression) {
      dispatcherClosures[arg0] = ref;
    } else if (arg0 != null) {
      dispatcherTearoffs.add(arg0);
      tearoffRef[arg0] = ref;
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final el = node.methodName.element;
    _noteDispatcher(node, el, node.methodName);
    _use(node, el, _UseKind.call);
    _rowBatchMember(node.target, node.methodName.name, node);
    _storedMember(node.target, node.methodName.name);
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _use(node, null, _UseKind.call);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitDotShorthandInvocation(DotShorthandInvocation node) {
    _use(node, node.memberName.element, _UseKind.call);
    super.visitDotShorthandInvocation(node);
  }

  @override
  void visitDotShorthandConstructorInvocation(
      DotShorthandConstructorInvocation node) {
    _use(node, node.constructorName.element, _UseKind.create);
    super.visitDotShorthandConstructorInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _use(node, node.constructorName.element, _UseKind.create);
    super.visitInstanceCreationExpression(node);
  }

  // --- tear-offs ---

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final p = node.parent;
    _banned(node.element);
    _bannedType(node.staticType);
    if (node.inDeclarationContext()) return;
    if (p is MethodInvocation && p.methodName == node) return;
    if (p is PrefixedIdentifier && p.identifier == node) return;
    if (p is PropertyAccess && p.propertyName == node) return;
    if (p is ConstructorName || p is NamedType || p is Label) return;
    if (p is DotShorthandInvocation && p.memberName == node) return;
    if (_isFunctionish(node.element)) {
      _use(node, node.element, _UseKind.tearoff,
          ref: dispatcherTearoffs.contains(node) ? tearoffRef[node] : null);
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final el = node.identifier.element;
    _banned(el);
    _bannedType(node.staticType);
    if (_isFunctionish(el)) {
      _use(node, el, _UseKind.tearoff,
          ref: dispatcherTearoffs.contains(node) ? tearoffRef[node] : null);
    }
    _rowBatchMember(node.prefix, node.identifier.name, node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final el = node.propertyName.element;
    _banned(el);
    _bannedType(node.staticType);
    if (_isFunctionish(el)) {
      _use(node, el, _UseKind.tearoff,
          ref: dispatcherTearoffs.contains(node) ? tearoffRef[node] : null);
    }
    _rowBatchMember(node.target, node.propertyName.name, node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitNamedType(NamedType node) {
    _banned(node.element);
    super.visitNamedType(node);
  }

  // --- stored-data collections ---

  static const _iterating = {
    'forEach', 'map', 'where', 'whereType', 'fold', 'reduce', 'any', 'every',
    'expand', 'toList', 'toSet', 'firstWhere', 'lastWhere', 'singleWhere',
    'indexWhere', 'lastIndexWhere', 'contains', 'indexOf', 'lastIndexOf',
    'sort', 'join', 'sublist', 'followedBy', 'takeWhile', 'skipWhile',
    'getRange', 'cast', 'removeWhere', 'retainWhere',
  };

  bool _isSampleType(DartType? t) {
    if (t is! InterfaceType) return false;
    if (t.isDartCoreInt || t.isDartCoreDouble || t.isDartCoreNum) return true;
    if (_uri(t.element) == 'dart:typed_data' &&
        (t.element.name ?? '').endsWith('List')) {
      return true;
    }
    if ((t.isDartCoreList || t.isDartCoreIterable) &&
        t.typeArguments.isNotEmpty) {
      return _isSampleType(t.typeArguments.first);
    }
    return false;
  }

  bool _isSampleCollection(DartType? t) {
    if (t is! InterfaceType) return false;
    if (_uri(t.element) == 'dart:typed_data' &&
        (t.element.name ?? '').endsWith('List')) {
      return true;
    }
    return (t.isDartCoreList || t.isDartCoreIterable) &&
        t.typeArguments.isNotEmpty &&
        _isSampleType(t.typeArguments.first);
  }

  bool _isRecordCollection(DartType? t) =>
      t is InterfaceType &&
      (t.isDartCoreList || t.isDartCoreIterable) &&
      t.typeArguments.isNotEmpty &&
      t.typeArguments.first is InterfaceType &&
      (t.typeArguments.first as InterfaceType).isDartCoreMap;

  /// A label when [e] is a stored-data collection: a sample list/typed-data
  /// member of a configured stored-data type, or (in the configured files) a
  /// list of day-record maps.
  String? _storedLabel(Expression? e) {
    while (e is ParenthesizedExpression) {
      e = e.expression;
    }
    if (e == null) return null;
    final Element? el = e is PrefixedIdentifier
        ? e.identifier.element
        : e is PropertyAccess
            ? e.propertyName.element
            : e is SimpleIdentifier
                ? e.element
                : null;
    if (el is GetterElement || el is FieldElement) {
      final enc = el!.enclosingElement;
      if (enc is InterfaceElement &&
          config.storedDataTypes.contains(enc.name) &&
          _isSampleCollection(e.staticType)) {
        return '${enc.name}.${el.name}';
      }
    }
    if (config.storedDataFiles.contains(decl.file) &&
        _isRecordCollection(e.staticType)) {
      return 'day records';
    }
    return null;
  }

  void _storedMember(Expression? target, String member) {
    if (!_iterating.contains(member)) return;
    final l = _storedLabel(target);
    if (l != null) decl.storedIterations.add(l);
  }

  void _storedForEach(Expression iterable) {
    final l = _storedLabel(iterable);
    if (l != null) decl.storedIterations.add(l);
  }

  void _storedIndexLoop(Expression? condition) {
    if (condition is! BinaryExpression) return;
    for (final side in [condition.leftOperand, condition.rightOperand]) {
      Expression? target;
      if (side is PrefixedIdentifier && side.identifier.name == 'length') {
        target = side.prefix;
      } else if (side is PropertyAccess && side.propertyName.name == 'length') {
        target = side.target;
      }
      final l = _storedLabel(target);
      if (l != null) {
        decl.storedIterations.add(l);
        return;
      }
    }
  }

  // --- RowBatch iteration ---

  static const _rowBatchCheap = {'length', 'isEmpty', 'isNotEmpty'};

  void _rowBatchMember(Expression? target, String member, AstNode at) {
    if (target == null) return;
    if (!_isRowBatch(target.staticType)) return;
    if (_rowBatchCheap.contains(member)) return;
    decl.rowBatchIterations.add((at, member));
  }

  void _forEachParts(Expression iterable, AstNode at) {
    _storedForEach(iterable);
    if (_isRowBatch(iterable.staticType)) {
      decl.rowBatchIterations.add((at, 'for-in'));
    }
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    _forEachParts(node.iterable, node);
    super.visitForEachPartsWithDeclaration(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    _forEachParts(node.iterable, node);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    _forEachParts(node.iterable, node);
    super.visitForEachPartsWithPattern(node);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    _storedForEach(node.expression);
    if (_isRowBatch(node.expression.staticType)) {
      decl.rowBatchIterations.add((node, 'spread'));
    }
    super.visitSpreadElement(node);
  }

  // --- loops (for @live) ---

  bool _isConstOperand(Expression? e) {
    if (e == null) return false;
    if (e is IntegerLiteral) return true;
    if (e is ParenthesizedExpression) return _isConstOperand(e.expression);
    final el = e is SimpleIdentifier
        ? e.element
        : e is PrefixedIdentifier
            ? e.identifier.element
            : null;
    if (el is GetterElement) return el.variable.isConst;
    if (el is VariableElement) return el.isConst;
    return false;
  }

  bool _isConstIterable(Expression e) {
    if (e is ListLiteral) return e.isConst;
    if (e is SetOrMapLiteral) return e.isConst;
    return _isConstOperand(e);
  }

  @override
  void visitForStatement(ForStatement node) {
    final parts = node.forLoopParts;
    var bounded = false;
    if (parts is ForParts) {
      _storedIndexLoop(parts.condition);
      final c = parts.condition;
      if (c is BinaryExpression) {
        bounded = _isConstOperand(c.rightOperand) || _isConstOperand(c.leftOperand);
      }
    } else if (parts is ForEachParts) {
      bounded = _isConstIterable(parts.iterable);
    }
    decl.loops.add(_Loop(node, bounded));
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    final parts = node.forLoopParts;
    if (parts is ForParts) _storedIndexLoop(parts.condition);
    super.visitForElement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    decl.loops.add(_Loop(node, false));
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    decl.loops.add(_Loop(node, false));
    super.visitDoStatement(node);
  }

  // --- strings (raw-reader table names) ---

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    decl.strings.write(' ${node.value} ');
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    decl.strings.write(' ${node.value} ');
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    final e = node.expression;
    final el = e is SimpleIdentifier
        ? e.element
        : e is PrefixedIdentifier
            ? e.identifier.element
            : null;
    final v = el is GetterElement
        ? el.variable.computeConstantValue()?.toStringValue()
        : el is VariableElement
            ? el.computeConstantValue()?.toStringValue()
            : null;
    if (v != null) decl.strings.write(' $v ');
    super.visitInterpolationExpression(node);
  }
}

// ---------------------------------------------------------------------------
// Registry parsing
// ---------------------------------------------------------------------------

class _Entry {
  final String symbol;
  final String dispatcher;
  final String file;
  _Entry(this.symbol, this.dispatcher, this.file);
}

class _OkFingerprint {
  final String file, symbol, source;
  final int ordinal;
  bool used = false;
  _OkFingerprint(this.file, this.symbol, this.source, this.ordinal);
}

String _symbolLiteral(Expression e) {
  if (e is SymbolLiteral) return e.components.map((t) => t.lexeme).join('.');
  return '';
}

Expression? _named(InstanceCreationExpression n, String name) {
  for (final a in n.argumentList.arguments) {
    if (a is NamedExpression && a.name.label.name == name) return a.expression;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Union-find over override groups
// ---------------------------------------------------------------------------

class _Groups {
  final Map<Element, Element> _parent = {};

  Element _find(Element e) {
    var r = e;
    while (_parent[r] != null && _parent[r] != r) {
      r = _parent[r]!;
    }
    return r;
  }

  void add(MethodElement m) {
    _parent.putIfAbsent(m.baseElement, () => m.baseElement);
    final enc = m.enclosingElement;
    if (enc is! InterfaceElement) return;
    for (final st in enc.allSupertypes) {
      final sup = st.element.getMethod(m.name ?? '');
      if (sup == null) continue;
      _parent.putIfAbsent(sup.baseElement, () => sup.baseElement);
      final a = _find(m.baseElement), b = _find(sup.baseElement);
      if (a != b) _parent[a] = b;
    }
  }

  Element canon(Element e) {
    final b = e is ExecutableElement ? e.baseElement : e;
    return _parent.containsKey(b) ? _find(b) : b;
  }
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

Future<HeavyGuardResult> analyze(HeavyGuardConfig config) async {
  final context = await _contextFor(config);
  final session = context.currentSession;
  final libRoot = '${config.packageRoot}/lib/';

  // --- resolve ---
  final decls = <_Decl>[];
  final entries = <_Entry>[];
  final oks = <(String, _OkFingerprint)>[];
  final rawReaders = <String>[];
  final registryVars = <String, List<(String, VariableDeclaration)>>{};
  final seenPaths = <String>{};

  final files = [
    for (final f in Directory('${config.packageRoot}/lib')
        .listSync(recursive: true)
        .whereType<File>())
      if (f.path.endsWith('.dart')) f.path,
  ]..sort();

  for (final path in files) {
    if (seenPaths.contains(path)) continue;
    final res = await session.getResolvedLibrary(path);
    if (res is! ResolvedLibraryResult) continue; // part file: seen via its library
    for (final u in res.units) {
      seenPaths.add(u.path);
      if (!u.path.startsWith(libRoot)) continue;
      final rel = u.path.substring(libRoot.length);
      if (config.skipFilePrefixes.any(rel.startsWith)) continue;
      _collectUnit(u.unit, rel, u.content, config, decls, registryVars);
    }
  }

  // --- registry ---
  for (final e in registryVars['kWorkerEntries'] ?? const []) {
    final init = e.$2.initializer;
    if (init is! ListLiteral) continue;
    for (final el in init.elements) {
      if (el is! InstanceCreationExpression) continue;
      final args = el.argumentList.arguments;
      final sym = args.isEmpty ? '' : _symbolLiteral(args.first);
      final disp = _named(el, 'dispatcher');
      entries.add(_Entry(sym, disp == null ? '' : disp.toSource().split('.').last, e.$1));
    }
  }
  for (final e in registryVars['kUnresolvedOk'] ?? const []) {
    final init = e.$2.initializer;
    if (init is! ListLiteral) continue;
    for (final el in init.elements) {
      if (el is! InstanceCreationExpression) continue;
      String s(String n) {
        final x = _named(el, n);
        return x is StringLiteral ? (x.stringValue ?? '') : '';
      }

      final ord = _named(el, 'ordinal');
      oks.add((
        e.$1,
        _OkFingerprint(s('file'), s('symbol'), _collapse(s('source')),
            ord is IntegerLiteral ? (ord.value ?? 0) : 0),
      ));
    }
  }
  for (final e in registryVars['kRawReaders'] ?? const []) {
    final init = e.$2.initializer;
    if (init is! ListLiteral) continue;
    for (final el in init.elements) {
      if (el is! InstanceCreationExpression) continue;
      final args = el.argumentList.arguments;
      if (args.isNotEmpty) rawReaders.add(_symbolLiteral(args.first));
    }
  }

  final out = <HeavyViolation>[];
  void add(HeavyRule rule, String file, String symbol, String element,
          [String message = '']) =>
      out.add(HeavyViolation(
          rule: rule,
          file: file,
          symbol: symbol,
          element: element,
          message: message));

  // --- heavy classification ---
  final groups = _Groups();
  for (final d in decls) {
    final e = d.element;
    if (e is MethodElement) groups.add(e);
  }
  final heavyGroups = <Element>{};
  for (final d in decls) {
    final e = d.element;
    if (e == null) continue;
    d.markedHeavy = _hasMarker(e, 'heavy');
    d.isLive = _hasMarker(e, 'live');
    if (d.markedHeavy) heavyGroups.add(groups.canon(e));
  }
  for (final d in decls) {
    final e = d.element;
    if (e != null && heavyGroups.contains(groups.canon(e))) d.isHeavy = true;
  }
  bool isHeavyEl(Element? e) =>
      e != null && _isFunctionish(e) && heavyGroups.contains(groups.canon(e));

  // --- (b) naming, @live/@heavy exclusivity, @live budget tests ---
  final testNames = _testFileNames(config.packageRoot);
  for (final d in decls) {
    final e = d.element;
    if (e == null || e is ConstructorElement) continue;
    final name = e.name ?? '';
    if (d.markedHeavy &&
        !name.endsWith('Heavy') &&
        !config.nameAllow.any((a) => a.symbol == d.symbol && a.element == name)) {
      add(HeavyRule.nameMarkerMismatch, d.file, d.symbol, name,
          '@heavy function must be named …Heavy');
    } else if (!d.markedHeavy &&
        !d.isHeavy &&
        name.endsWith('Heavy') &&
        !config.nameAllow
            .any((a) => a.symbol == d.symbol && a.element == name)) {
      add(HeavyRule.nameMarkerMismatch, d.file, d.symbol, name,
          '…Heavy name without @heavy');
    }
    if (d.isLive && d.markedHeavy) {
      add(HeavyRule.liveAndHeavy, d.file, d.symbol, name,
          '@live and @heavy are exclusive');
    } else if (d.isLive) {
      final base = 'live_${d.symbol.replaceAll('.', '_')}_budget_test.dart';
      if (!testNames.contains(base)) {
        add(HeavyRule.liveBudgetTestMissing, d.file, d.symbol, name,
            'missing test/**/$base');
      }
    }
  }

  // --- registry resolution ---
  final bySymbol = <String, List<_Decl>>{};
  for (final d in decls) {
    final e = d.element;
    if (e != null && e is! ConstructorElement) {
      bySymbol.putIfAbsent(d.symbol, () => []).add(d);
    }
  }
  final registeredGroups = <Element, _Entry>{};
  final seenSymbols = <String>{};
  final resolvedEntries = <(_Entry, _Decl)>[];
  for (final e in entries) {
    if (!seenSymbols.add(e.symbol)) {
      add(HeavyRule.registryEntryDuplicate, e.file, e.symbol,
          e.symbol.split('.').last, 'registered twice');
      continue;
    }
    final cands = bySymbol[e.symbol] ?? const [];
    final name = e.symbol.split('.').last;
    if (cands.isEmpty) {
      add(HeavyRule.registryEntryUnresolved, e.file, e.symbol, name,
          'no function with this symbol');
    } else if (cands.length > 1) {
      add(HeavyRule.registryEntryAmbiguous, e.file, e.symbol, name,
          '${cands.length} functions share this symbol');
    } else if (!cands.single.isHeavy) {
      add(HeavyRule.registryEntryNotHeavy, e.file, e.symbol, name,
          'registered function is not @heavy');
    } else {
      registeredGroups[groups.canon(cands.single.element!)] = e;
      resolvedEntries.add((e, cands.single));
    }
  }

  // --- uses ---
  final okByKey = <String, _OkFingerprint>{
    for (final o in oks)
      '${o.$2.file}|${o.$2.symbol}|${o.$2.ordinal}|${o.$2.source}': o.$2,
  };
  final heavyCallers = <Element, int>{};
  final dispatchKinds = <Element, List<Dispatcher>>{};
  final firstDeclOfGroup = <Element, _Decl>{};
  for (final d in decls) {
    final e = d.element;
    if (e != null && d.isHeavy) {
      firstDeclOfGroup.putIfAbsent(groups.canon(e), () => d);
    }
  }

  bool allowed(_Decl d, Element e) {
    final l = _label(e);
    final n = e.name ?? '';
    if (config.lightApi.any((a) => a.element == l)) return true;
    for (final a in config.originAllow) {
      if (a.symbol == d.symbol && (a.element == l || a.element == n)) return true;
    }
    return false;
  }

  bool isOrigin(Element? e) {
    if (e == null) return false;
    final ok = e is TopLevelFunctionElement ||
        e is MethodElement ||
        (e is ConstructorElement && e.isFactory);
    if (!ok) return false;
    final u = _uri(e);
    return config.heavyOriginPrefixes.any(u.startsWith);
  }

  for (final d in decls) {
    var ordinal = 0;
    for (final u in d.uses) {
      final el = u.element;
      final heavyTarget = isHeavyEl(el);
      final inHeavy = d.isHeavy;

      // fail-closed unresolved invocations (non-heavy code only)
      if (u.kind != _UseKind.tearoff) {
        final resolved = el != null &&
            (el is MethodElement ||
                el is TopLevelFunctionElement ||
                el is LocalFunctionElement ||
                el is ConstructorElement);
        if (!resolved) {
          final myOrdinal = ordinal++;
          if (!inHeavy) {
            final fp = okByKey['${d.file}|${d.symbol}|$myOrdinal|${u.src}'];
            if (fp != null) {
              fp.used = true;
            } else {
              add(HeavyRule.unresolvedInvocation, d.file, d.symbol, u.src,
                  'cannot resolve the invoked function');
            }
          }
        }
      }

      if (inHeavy) {
        if (heavyTarget) {
          final g = groups.canon(el!);
          if (g != groups.canon(d.element!)) {
            heavyCallers[g] = (heavyCallers[g] ?? 0) + 1;
          }
        }
        continue;
      }

      final liveHere = d.isLive;
      final originHit = isOrigin(el) && !allowed(d, el!);

      if (heavyTarget) {
        if (liveHere) {
          add(HeavyRule.liveCallsHeavy, d.file, d.symbol, _label(el!),
              '@live code must not call heavy work');
          continue;
        }
        if (u.dispatcher != null && u.kind != _UseKind.create) {
          dispatchKinds
              .putIfAbsent(groups.canon(el!), () => [])
              .add(u.dispatcher!.kind);
        } else if (u.kind == _UseKind.tearoff) {
          add(HeavyRule.heavyReferenceEscapes, d.file, d.symbol, _label(el!),
              'tear-off of a heavy function outside a dispatcher');
        } else {
          add(HeavyRule.heavyCallOutsideApprovedContext, d.file, d.symbol,
              _label(el!), 'heavy call outside @heavy / a direct dispatcher');
        }
      } else if (originHit) {
        if (liveHere) {
          add(HeavyRule.liveCallsHeavy, d.file, d.symbol, _label(el),
              '@live code must not call heavy work');
        } else {
          add(HeavyRule.heavyOriginOutsideHeavy, d.file, d.symbol, _label(el),
              'heavy-origin API outside @heavy');
        }
      }
    }

    // stored-data iteration (outside @heavy)
    if (!d.isHeavy) {
      for (final label in d.storedIterations) {
        add(HeavyRule.heavyOriginOutsideHeavy, d.file, d.symbol, label,
            'iterating stored data ($label) outside @heavy');
      }
    }

    // RowBatch iteration (outside @heavy)
    if (!d.isHeavy) {
      for (final r in d.rowBatchIterations) {
        add(HeavyRule.rowBatchIterationOutsideHeavy, d.file, d.symbol,
            'RowBatch', 'iterating a RowBatch (${r.$2}) outside @heavy');
      }
    }

    // @live loops
    if (d.isLive && !d.markedHeavy) {
      for (final l in d.loops) {
        if (!l.bounded) {
          add(HeavyRule.liveUnboundedLoop, d.file, d.symbol, 'loop',
              '@live code may only loop over constant bounds');
        }
      }
    }

    // platform ban inside @heavy
    if (d.isHeavy) {
      for (final b in d.bannedSeen) {
        add(HeavyRule.platformInHeavy, d.file, d.symbol, b,
            '@heavy bodies must not touch $b');
      }
    }
  }

  // --- dispatcher closures: contract and captures ---
  for (final d in decls) {
    for (final disp in d.dispatches) {
      final arg = disp.arg0;
      if (arg == null) continue;
      if (arg is FunctionExpression) {
        _checkClosure(d, disp, arg, config, isHeavyEl, add);
      } else {
        // tear-off or a variable: must be a heavy function tear-off
        Element? el;
        if (arg is SimpleIdentifier) el = arg.element;
        if (arg is PrefixedIdentifier) el = arg.identifier.element;
        if (arg is PropertyAccess) el = arg.propertyName.element;
        if (!isHeavyEl(el)) {
          add(HeavyRule.dispatcherClosureContract, d.file, d.symbol,
              el == null ? arg.toSource() : _label(el),
              'dispatcher argument must be a closure or a heavy entry tear-off');
        }
      }
    }
  }

  // --- roots, registry vs dispatch, sendable grammar ---
  final depth = <Element>{};
  for (final entry in firstDeclOfGroup.entries) {
    final g = entry.key;
    final d = entry.value;
    final dispatched = (dispatchKinds[g] ?? const []).isNotEmpty;
    final required = dispatched || (heavyCallers[g] ?? 0) == 0;
    if (required && !registeredGroups.containsKey(g) && depth.add(g)) {
      add(HeavyRule.rootNotRegistered, d.file, d.symbol, d.element!.name ?? '',
          'heavy root is not in kWorkerEntries');
    }
  }
  for (final r in resolvedEntries) {
    final e = r.$1, d = r.$2;
    final g = groups.canon(d.element!);
    final kinds = dispatchKinds[g] ?? const [];
    final name = d.element!.name ?? '';
    if (kinds.isEmpty) {
      add(HeavyRule.registryEntryNeverDispatched, e.file, e.symbol, name,
          'no approved dispatcher runs this entry');
    } else if (kinds.any((k) => k.name != e.dispatcher)) {
      add(HeavyRule.registryDispatcherMismatch, e.file, e.symbol, name,
          'registered as ${e.dispatcher}, dispatched as ${kinds.map((k) => k.name).toSet().join('/')}');
    }

    // static + initialised-first
    final el = d.element;
    if (el is ConstructorElement ||
        (el is MethodElement && !el.isStatic)) {
      add(HeavyRule.workerEntryNotStatic, e.file, e.symbol, name,
          'worker entries are top-level or static functions');
    } else if (!_startsInitialised(d.node)) {
      add(HeavyRule.workerEntryNotInitialised, e.file, e.symbol, name,
          'body must start with WorkerInit.ensure(…) or assertWorker()');
    }

    // sendable grammar on the boundary types
    if (el is ExecutableElement) {
      final spawn = e.dispatcher == 'spawn';
      final shapes = <String>[];
      String? problem;
      for (final p in el.formalParameters) {
        problem ??= _sendProblem(p.type, {}, shapes, allowSendPort: spawn);
      }
      var rt = el.returnType;
      if (rt is InterfaceType &&
          (rt.isDartAsyncFuture || rt.isDartAsyncFutureOr) &&
          rt.typeArguments.isNotEmpty) {
        rt = rt.typeArguments.first;
      }
      problem ??= _sendProblem(rt, {}, shapes);
      if (problem != null) {
        add(HeavyRule.sendableGrammar, e.file, e.symbol, problem,
            'worker entry boundary type is not in the closed sendable grammar');
      }
      if (shapes.isNotEmpty) {
        final base = 'sendable_${e.symbol.replaceAll('.', '_')}_test.dart';
        if (!testNames.contains(base)) {
          add(HeavyRule.sendableShapeTestMissing, e.file, e.symbol, name,
              'missing test/**/$base for @SendableShape ${shapes.join(', ')}');
        }
      }
    }
  }

  // --- unresolved fingerprints that matched nothing ---
  for (final o in oks) {
    if (!o.$2.used) {
      add(HeavyRule.unresolvedOkStale, o.$1, o.$2.symbol, o.$2.source,
          'kUnresolvedOk fingerprint matches no unresolved invocation');
    }
  }

  // --- raw readers ---
  _rawReaders(decls, rawReaders, config, groups, add);

  return HeavyGuardResult(out);
}

// ---------------------------------------------------------------------------
// Collection of decls
// ---------------------------------------------------------------------------

void _collectUnit(
  CompilationUnit unit,
  String rel,
  String content,
  HeavyGuardConfig config,
  List<_Decl> decls,
  Map<String, List<(String, VariableDeclaration)>> registryVars,
) {
  void scan(_Decl d, AstNode? body) {
    if (body != null) body.accept(_Scan(d, config));
    decls.add(d);
  }

  unit.accept(_DeclCollector((node) {
    if (node is FunctionDeclaration) {
      final el = node.declaredFragment?.element;
      if (el == null) return;
      scan(_Decl(rel, _symbol(el), '', el, node, content),
          node.functionExpression.body);
    } else if (node is MethodDeclaration) {
      final el = node.declaredFragment?.element;
      if (el == null) return;
      scan(_Decl(rel, _symbol(el), el.enclosingElement?.name ?? '', el, node,
              content),
          node.body);
    } else if (node is ConstructorDeclaration) {
      final el = node.declaredFragment?.element;
      if (el == null) return;
      final d = _Decl(rel, _symbol(el), el.enclosingElement.name ?? '', el,
          node, content);
      final sc = _Scan(d, config);
      for (final i in node.initializers) {
        i.accept(sc);
      }
      node.body.accept(sc);
      decls.add(d);
    } else if (node is VariableDeclaration) {
      final el = node.declaredFragment?.element;
      if (el == null) return;
      final enc = el.enclosingElement;
      final isTop = el is TopLevelVariableElement;
      if (isTop) {
        registryVars
            .putIfAbsent(el.name ?? '', () => [])
            .add((rel, node));
      }
      final symbol = enc is InterfaceElement || enc is ExtensionElement
          ? '${enc!.name ?? '<ext>'}.${el.name}'
          : (el.name ?? '');
      scan(_Decl(rel, symbol, enc is InterfaceElement ? (enc.name ?? '') : '',
              null, node, content),
          node.initializer);
    }
  }));
}

String _symbol(ExecutableElement el) => _label(el);

class _DeclCollector extends RecursiveAstVisitor<void> {
  final void Function(AstNode) onDecl;
  _DeclCollector(this.onDecl);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit) onDecl(node);
    // do not descend: local functions belong to this decl
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) => onDecl(node);

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) => onDecl(node);

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    // Only field / top-level variable declarations reach here: locals live
    // inside bodies, which the collector never descends into.
    onDecl(node);
  }
}

Set<String> _testFileNames(String root) {
  // Fixture files are rewritten between runs: no cross-call cache.
  final dir = Directory('$root/test');
  if (!dir.existsSync()) return {};
  return {
    for (final f in dir.listSync(recursive: true).whereType<File>())
      f.uri.pathSegments.last,
  };
}

/// True when the function's body is a block whose FIRST statement is
/// `WorkerInit.ensure(…)` or `assertWorker()`.
bool _startsInitialised(AstNode decl) {
  FunctionBody? body;
  if (decl is FunctionDeclaration) body = decl.functionExpression.body;
  if (decl is MethodDeclaration) body = decl.body;
  if (body is! BlockFunctionBody) return false;
  final stmts = body.block.statements;
  if (stmts.isEmpty) return false;
  final first = stmts.first;
  if (first is! ExpressionStatement) return false;
  final call = first.expression;
  if (call is! MethodInvocation) return false;
  final el = call.methodName.element;
  if (el == null || !_uri(el).endsWith('util/worker_init.dart')) return false;
  final l = _label(el);
  return l == 'WorkerInit.ensure' || l == 'assertWorker';
}

// ---------------------------------------------------------------------------
// Dispatcher closures
// ---------------------------------------------------------------------------

void _checkClosure(
  _Decl d,
  _Dispatch disp,
  FunctionExpression closure,
  HeavyGuardConfig config,
  bool Function(Element?) isHeavyEl,
  void Function(HeavyRule, String, String, String, [String]) add,
) {
  bool inside(AstNode n) {
    for (AstNode? p = n; p != null; p = p.parent) {
      if (p == closure) return true;
    }
    return false;
  }

  // contract: at most one heavy entry call; other invocations only construct
  // sendable values.
  var entryCalls = 0;
  for (final u in d.uses) {
    if (!inside(u.node)) continue;
    final el = u.element;
    if (isHeavyEl(el)) {
      entryCalls++;
      continue;
    }
    if (u.kind == _UseKind.create && el is ConstructorElement) {
      final cls = el.enclosingElement;
      if ((_hasMarker(cls, 'sendable') ||
              _hasMarker(cls, 'SendableShape') ||
              cls.name == 'RowBatch')) {
        continue;
      }
    }
    add(HeavyRule.dispatcherClosureContract, d.file, d.symbol,
        el == null ? u.src : _label(el),
        'dispatcher closures may only bind values, build sendable values and call ONE heavy entry');
  }
  if (entryCalls > 1) {
    add(HeavyRule.dispatcherClosureContract, d.file, d.symbol,
        '$entryCalls entry calls',
        'a dispatcher closure calls at most one registered worker entry');
  }

  // captures
  final cap = _CaptureScan(closure);
  closure.body.accept(cap);
  if (cap.capturesThis) {
    add(HeavyRule.captureNotSendable, d.file, d.symbol, 'this',
        'dispatcher closure captures `this`');
  }
  for (final v in cap.captured.entries) {
    final t = v.value;
    final problem = _bannedOrUnsendable(t, config);
    if (problem != null) {
      add(HeavyRule.captureNotSendable, d.file, d.symbol, v.key, problem);
    }
  }
}

String? _bannedOrUnsendable(DartType t, HeavyGuardConfig config) {
  if (t is InterfaceType) {
    final names = {
      t.element.name,
      for (final s in t.element.allSupertypes) s.element.name,
    };
    final hit = names.intersection(config.bannedPlatformTypes);
    if (hit.isNotEmpty) return 'captures a ${hit.first}';
  }
  return _sendProblem(t, {}, []);
}

class _CaptureScan extends RecursiveAstVisitor<void> {
  final FunctionExpression closure;
  _CaptureScan(this.closure);

  bool capturesThis = false;
  final Map<String, DartType> captured = {};

  bool _declaredInside(Element e) {
    final off = e.firstFragment.nameOffset;
    return off != null && off >= closure.offset && off < closure.end;
  }

  @override
  void visitThisExpression(ThisExpression node) {
    capturesThis = true;
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    capturesThis = true;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inDeclarationContext()) return;
    final p = node.parent;
    final bare = !((p is PrefixedIdentifier && p.identifier == node) ||
        (p is PropertyAccess && p.propertyName == node) ||
        (p is MethodInvocation && p.methodName == node && p.target != null) ||
        p is Label);
    if (!bare) return;
    final e = node.element;
    if (e is LocalVariableElement || e is FormalParameterElement) {
      if (!_declaredInside(e!)) {
        captured[e.name ?? '?'] =
            e is LocalVariableElement ? e.type : (e as FormalParameterElement).type;
      }
    } else if (e is ExecutableElement || e is FieldElement) {
      final isInstance = e is FieldElement
          ? !e.isStatic
          : e is GetterElement
              ? !e.isStatic && e.enclosingElement is InterfaceElement
              : e is SetterElement
                  ? !e.isStatic && e.enclosingElement is InterfaceElement
                  : e is MethodElement
                      ? !e.isStatic && e.enclosingElement is InterfaceElement
                      : false;
      if (isInstance) capturesThis = true;
    }
  }
}

// ---------------------------------------------------------------------------
// The closed sendable grammar (transitive)
// ---------------------------------------------------------------------------

/// Returns a description of the first thing outside the grammar, or null.
/// Types annotated @SendableShape are accepted wholesale and recorded in
/// [shapes] (they require a round-trip test).
String? _sendProblem(
  DartType t,
  Set<Element> seen,
  List<String> shapes, {
  bool allowSendPort = false,
}) {
  if (t is DynamicType) return 'dynamic';
  if (t is VoidType || t is NeverType) return null;
  if (t is TypeParameterType) return 'type parameter ${t.element.name}';
  if (t is FunctionType) return 'function type ${t.getDisplayString()}';
  if (t is RecordType) {
    for (final f in [...t.positionalFields, ...t.namedFields]) {
      final p = _sendProblem(f.type, seen, shapes, allowSendPort: allowSendPort);
      if (p != null) return p;
    }
    return null;
  }
  if (t is! InterfaceType) return t.getDisplayString();
  final el = t.element;
  if (_hasMarker(el, 'SendableShape')) {
    shapes.add(el.name ?? '?');
    return null;
  }
  if (el.name == 'RowBatch') return null; // sendable by definition
  if (t.isDartCoreObject) return 'Object';
  if (t.isDartCoreNull ||
      t.isDartCoreBool ||
      t.isDartCoreInt ||
      t.isDartCoreDouble ||
      t.isDartCoreNum ||
      t.isDartCoreString) {
    return null;
  }
  if (_uri(el) == 'dart:typed_data' && (el.name ?? '').endsWith('List')) {
    return null;
  }
  if (t.isDartCoreList) {
    return _sendProblem(t.typeArguments.first, seen, shapes);
  }
  if (t.isDartCoreMap) {
    final k = t.typeArguments.first;
    if (!(k is InterfaceType &&
        k.isDartCoreString &&
        k.nullabilitySuffix == NullabilitySuffix.none)) {
      return 'Map key ${k.getDisplayString()} (only String keys)';
    }
    return _sendProblem(t.typeArguments[1], seen, shapes);
  }
  if (el is EnumElement) return null;
  if (allowSendPort && _uri(el) == 'dart:isolate' && el.name == 'SendPort') {
    return null;
  }
  if (_hasMarker(el, 'sendable')) {
    if (!seen.add(el)) return null;
    for (final f in el.fields) {
      if (f.isStatic || !f.isOriginDeclaration) continue;
      final p = _sendProblem(f.type, seen, shapes);
      if (p != null) return '${el.name}.${f.name}: $p';
    }
    for (final st in el.allSupertypes) {
      if (st.isDartCoreObject) continue;
      for (final f in st.element.fields) {
        if (f.isStatic || !f.isOriginDeclaration) continue;
        final p = _sendProblem(f.type, seen, shapes);
        if (p != null) return '${el.name}.${f.name}: $p';
      }
    }
    return null;
  }
  return 'not sendable: ${t.getDisplayString()}';
}

// ---------------------------------------------------------------------------
// Raw-row readers
// ---------------------------------------------------------------------------

void _rawReaders(
  List<_Decl> decls,
  List<String> registered,
  HeavyGuardConfig config,
  _Groups groups,
  void Function(HeavyRule, String, String, String, [String]) add,
) {
  final regSet = registered.toSet();
  final methods = [
    for (final d in decls)
      if (d.container == config.rawReaderClass && d.element is MethodElement) d,
  ];
  final bySymbol = {for (final m in methods) m.symbol: m};
  for (final r in registered) {
    if (!bySymbol.containsKey(r)) {
      add(HeavyRule.registryEntryUnresolved, 'util/raw_readers.dart', r, r,
          'kRawReaders names a method that does not exist');
    }
  }

  String? table(_Decl d) {
    final s = d.strings.toString();
    for (final t in config.rawTables) {
      if (RegExp('(^|[^A-Za-z0-9_])$t([^A-Za-z0-9_]|\$)').hasMatch(s)) return t;
    }
    return null;
  }

  bool callsRegistered(_Decl d) => d.uses.any((u) {
        final e = u.element;
        return e != null && _isFunctionish(e) && regSet.contains(_label(e));
      });

  // Only methods whose return type exposes ROWS are readers; scalar accessors
  // and migration/backfill/repair steps (by name) are not.
  bool exposesRows(MethodElement m) {
    var t = m.returnType;
    if (t is InterfaceType &&
        (t.isDartAsyncFuture || t.isDartAsyncFutureOr) &&
        t.typeArguments.isNotEmpty) {
      t = t.typeArguments.first;
    }
    if (t is! InterfaceType) return false;
    if (t.isDartAsyncStream) return true;
    return t.isDartCoreList ||
        t.isDartCoreIterable ||
        t.isDartCoreSet ||
        t.isDartCoreMap ||
        t.element.name == 'RowBatch';
  }

  final migrationName = RegExp(
      r'^_?(backfill|repair|ensure|migrate|upgrade|retire|create|drop|onUpgrade|onCreate|onOpen)',
      caseSensitive: false);
  bool migration(_Decl m) => migrationName.hasMatch(m.element?.name ?? '');

  final reaches = {
    for (final m in methods)
      m.symbol: (table(m) != null || callsRegistered(m)) &&
          exposesRows(m.element as MethodElement) &&
          !migration(m),
  };
  // private helpers whose every caller is registered (or itself exempt) hand
  // their rows only to a registered caller.
  final exempt = <String>{};
  var changed = true;
  while (changed) {
    changed = false;
    for (final m in methods) {
      final n = m.element!.name ?? '';
      if (!n.startsWith('_') || regSet.contains(m.symbol) || exempt.contains(m.symbol)) continue;
      final callers = [
        for (final o in methods)
          if (o != m &&
              o.uses.any((u) => u.element != null && _label(u.element!) == m.symbol))
            o.symbol,
      ];
      if (callers.isNotEmpty &&
          callers.every((c) => regSet.contains(c) || exempt.contains(c))) {
        exempt.add(m.symbol);
        changed = true;
      }
    }
  }

  for (final m in methods) {
    final isReg = regSet.contains(m.symbol);
    if (reaches[m.symbol] == true && !isReg && !exempt.contains(m.symbol)) {
      add(HeavyRule.rawReaderUnregistered, m.file, m.symbol,
          table(m) ?? 'registered reader',
          'reads raw rows but is not in kRawReaders');
    }
    if (isReg) {
      var rt = (m.element as MethodElement).returnType;
      if (rt is InterfaceType &&
          (rt.isDartAsyncFuture || rt.isDartAsyncFutureOr) &&
          rt.typeArguments.isNotEmpty) {
        rt = rt.typeArguments.first;
      }
      if (!(rt is InterfaceType && rt.element.name == 'RowBatch')) {
        add(HeavyRule.rawReaderWrongReturnType, m.file, m.symbol,
            rt.getDisplayString(), 'registered raw readers return RowBatch');
      }
    }
  }
}
