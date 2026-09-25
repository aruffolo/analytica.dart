import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' hide WildcardPattern;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../comment_parser.dart';
import '../models.dart';
import '../reachability_engine_helpers.dart';
import '../root_harvester.dart';
import 'flow.dart';
import 'origins.dart';
import 'references.dart';

/// Identity includes the declaring fragment, owner and element kind.
/// Substituted elements and synthetic accessors share declarations.
String elementKey(Element element) {
  var base = element.baseElement;
  if (base is PropertyAccessorElement && base.isOriginVariable) {
    base = base.variable.baseElement;
  }
  final source = base.firstFragment.libraryFragment?.source.fullName;
  final owner = base.enclosingElement;
  if (base is LocalFunctionElement ||
      base is LocalVariableElement ||
      base is FormalParameterElement) {
    return '$source#${base.kind}#${base.firstFragment.offset}';
  }
  final ownerName = owner is InstanceElement ? owner.name : '';
  return '$source#$ownerName#${base.kind}#${base.lookupName}';
}

class MemberNode {
  final DeclarationNode declaration;
  final AstNode? ast;
  final Element element;
  final MemberNode? owner;
  final bool reportable;
  final bool structural;
  final MemberEdges edges = MemberEdges();

  MemberNode({
    required this.declaration,
    required this.element,
    this.ast,
    this.owner,
    this.reportable = true,
    this.structural = false,
  });

  String get key => elementKey(element);
  bool get isMethod => element is MethodElement;
  bool get isExecution =>
      element is ExecutableElement && element is! ConstructorElement;
}

class MemberEdges {
  final Set<String> direct = {};
  final Set<ConstructorElement> constructions = {};
  final Set<DispatchSlot> slots = {};
  final Set<InterfaceElement> escapedTypes = {};
  final Set<InterfaceElement> runtimeTypes = {};
  final Map<String, Set<ReceiverOrigin>> bindings = {};

  void bind(String key, ReceiverOrigin value) =>
      bindings.putIfAbsent(key, () => {}).add(value);
}

enum DispatchKind {
  method,
  getter,
  setter,
  superMethod,
  superGetter,
  superSetter;

  DispatchKind get asSuper => switch (this) {
    getter => superGetter,
    setter => superSetter,
    _ => superMethod,
  };

  DispatchKind get asOrdinary => switch (this) {
    superGetter => getter,
    superSetter => setter,
    _ => method,
  };

  static DispatchKind of(ExecutableElement element) => switch (element) {
    GetterElement() => getter,
    SetterElement() => setter,
    _ => method,
  };
}

/// A selector anchored to a resolved declaring interface and library.
/// Null owner is reserved for an explicitly diagnosed dynamic operation.
class DispatchSlot {
  final InstanceElement? owner;
  final String name;
  final LibraryElement library;
  final DispatchKind kind;
  final ReceiverOrigin? receiver;
  final List<CallArgument> arguments;
  final bool assumed;
  const DispatchSlot(
    this.owner,
    this.name,
    this.library,
    this.kind, {
    this.receiver,
    this.arguments = const [],
    this.assumed = false,
  });

  DispatchSlot get selector => DispatchSlot(owner, name, library, kind);

  @override
  bool operator ==(Object other) =>
      other is DispatchSlot &&
      other.owner == owner &&
      other.name == name &&
      other.library == library &&
      other.kind == kind &&
      other.receiver == receiver &&
      other.arguments == arguments &&
      other.assumed == assumed;
  @override
  int get hashCode =>
      Object.hash(owner, name, library, kind, receiver, arguments, assumed);
}

class MemberGraph {
  final UndeadOptions options;
  final PackageTopology topology;
  final Map<String, MemberNode> nodes = {};
  final Map<String, Set<InterfaceElement>> implementations = {};
  final Map<(InterfaceElement, DispatchSlot), ExecutableElement?>
  dispatchCache = {};
  final Map<InterfaceElement, List<MemberNode>> protocolCache = {};
  final Map<Expression, ReceiverOrigin> receiverValues = {};
  final Set<String> productionRoots = {};
  final Set<String> testRoots = {};
  final Map<TestBlockSite, MemberEdges> testSites = {};
  final List<CoverageLimitation> limitations = [];
  final Set<(String, String, int)> _limitationKeys = {};
  final Map<String, Set<String>> conditionalTargets = {};

  MemberGraph(this.options, this.topology);

  void addUnit(ResolvedUnitResult unit, String file, {bool reportable = true}) {
    final collector = _Declarations(this, unit, file, reportable);
    unit.unit.accept(collector);
    unit.unit.accept(_LocalDeclarations(this, unit, file));
    collectConditionalImports(
      directives: unit.unit.directives,
      relPath: file,
      packageName: topology.packageName,
      conditionalTargets: conditionalTargets,
    );
    if (topology.roleOf(file) == FileRole.test) {
      unit.unit.accept(_TestSites(this, unit, file));
    }
  }

  void _collectReceiverValues() {
    // Collect lexical flow before connecting independently owned local nodes.
    for (final node in nodes.values) {
      if (node.element is! LocalFunctionElement &&
          (node.ast is FunctionDeclaration || node.ast is MethodDeclaration)) {
        receiverValues.addAll(
          ReceiverOrigins(this, node.edges, node.element).collectValues(),
        );
      }
    }
  }

  void connect() {
    _collectReceiverValues();
    for (final node in nodes.values) {
      final element = node.element;
      if (element is! InterfaceElement) continue;
      for (final ancestor in [
        element,
        ...element.allSupertypes.map((t) => t.element),
      ]) {
        implementations
            .putIfAbsent(elementKey(ancestor), () => {})
            .add(element);
      }
    }
    for (final node in nodes.values.toList()) {
      final ast = node.ast;
      if (ast != null) {
        ast.accept(
          MemberReferences(
            this,
            node.edges,
            node.element.library!,
            shapeOnly: node.structural,
            sourceElement: node.element,
          ),
        );
      }
      final owner = node.owner;
      if (owner != null) node.edges.direct.add(owner.key);
      _connectConstructor(node);
      if (node.element case ClassElement(isSealed: true)) {
        node.edges.direct.addAll(
          nodes.values
              .where(
                (child) =>
                    child.element is InterfaceElement &&
                    (child.element as InterfaceElement).allSupertypes.any(
                      (type) => elementKey(type.element) == node.key,
                    ),
              )
              .map((child) => child.key),
        );
      }
      _addRoots(node);
    }
    _connectConditionals();
    // Expression refinements are consumed only while connecting body edges.
    receiverValues.clear();
  }

  void _connectConstructor(MemberNode node) {
    final element = node.element;
    if (element is! ConstructorElement) return;
    final redirected = element.redirectedConstructor;
    if (redirected != null) {
      node.edges.constructions.add(redirected);
    } else {
      final parent = element.superConstructor;
      if (parent != null) node.edges.direct.add(elementKey(parent));
    }
    if (element.isFactory) return;
    final owner = element.enclosingElement;
    final fields = [
      ...owner.fields,
      for (final mixin in owner.mixins) ...mixin.element.fields,
    ];
    for (final field in fields) {
      if (!field.isStatic && !field.isLate) {
        node.edges.direct.add(elementKey(field));
      }
    }
  }

  void _addRoots(MemberNode node) {
    if (node.element is LocalFunctionElement) return;
    final decl = node.declaration;
    if (!topology.allFiles.contains(decl.relativeFilePath)) return;
    final role = topology.roleOf(decl.relativeFilePath);
    if (role == FileRole.test) testRoots.add(node.key);
    final demonstration =
        role == FileRole.demonstration &&
        (options.exampleMode == ExampleMode.demonstration ||
            options.exampleMode == ExampleMode.strict && decl.name == 'main');
    if (isExecutableRoot(decl, topology) ||
        isAuxiliaryRoot(decl, topology) ||
        isConfigOrNativeRoot(decl, topology) ||
        isExtraProductionRoot(decl, topology) ||
        demonstration) {
      productionRoots.add(node.key);
      final element = node.element;
      if (element is ExecutableElement &&
          !element.isStatic &&
          element.enclosingElement is InterfaceElement) {
        node.edges.runtimeTypes.add(
          element.enclosingElement as InterfaceElement,
        );
      }
      // Explicit class roots name a runtime surface, not just a type use.
      if (node.structural) {
        productionRoots.addAll(
          nodes.values.where((n) => n.owner == node).map((n) => n.key),
        );
      }
    }
  }

  void _connectConditionals() {
    for (final entry in conditionalTargets.entries) {
      final targets = nodes.values.where(
        (n) => entry.value.contains(n.declaration.relativeFilePath),
      );
      for (final source in nodes.values.where(
        (n) => n.declaration.relativeFilePath == entry.key,
      )) {
        source.edges.direct.addAll(targets.map((n) => n.key));
      }
    }
  }

  void limitation(String code, String file, int line, String message) {
    if (!_limitationKeys.add((code, file, line))) return;
    limitations.add(
      CoverageLimitation(code: code, file: file, line: line, message: message),
    );
  }
}

class _Declarations extends RecursiveAstVisitor<void> {
  final MemberGraph graph;
  final ResolvedUnitResult unit;
  final String file;
  final bool reportable;
  MemberNode? owner;
  _Declarations(this.graph, this.unit, this.file, this.reportable);

  MemberNode? _add(
    Declaration ast, {
    DeclarationKind? kind,
    bool structural = false,
    bool finding = true,
  }) {
    final element = ast.declaredFragment?.element;
    if (element == null) return null;
    final key = elementKey(element);
    final localName = element is MethodElement
        ? element.lookupName
        : element.name;
    final name = owner == null
        ? localName ?? 'anonymous'
        : '${owner!.declaration.name}.$localName';
    final loc = unit.lineInfo.getLocation(ast.offset);
    final annotated = ast;
    final parent = ast.parent;
    final annotations =
        parent is TopLevelVariableDeclaration || parent is FieldDeclaration
        ? parent as Declaration
        : annotated;
    final ignored =
        CommentParser.hasIgnoreForFile(unit.unit) ||
        CommentParser.isDeclarationIgnored(ast) ||
        (owner?.declaration.isIgnored ?? false);
    final decl = DeclarationNode(
      id: key,
      name: name,
      kind: kind ?? classifyDeclaration(ast).$1,
      relativeFilePath: file,
      offset: ast.offset,
      length: ast.length,
      line: loc.lineNumber,
      column: loc.columnNumber,
      element: element,
      isIgnored: ignored,
      isTestSupport: hasAnnotation(annotations, 'visibleForTesting'),
      isNativeRoot:
          isNativeOrEntryPoint(annotations) ||
          graph.options.frameworkAdapter.isFrameworkEntryPoint(
            annotations,
            element,
          ),
      isExternalBinding: graph.options.frameworkAdapter.isExternalBinding(
        annotations,
        element,
      ),
    );
    final node = MemberNode(
      declaration: decl,
      element: element,
      ast: ast,
      owner: owner,
      structural: structural,
      reportable: reportable && finding,
    );
    graph.nodes[key] = node;
    return node;
  }

  void _instance(Declaration ast, InstanceElement? element) {
    final node = _add(ast, structural: true);
    if (node == null) return;
    owner = node;
    ast.visitChildren(this);
    if (element is InterfaceElement) {
      for (final constructor in element.constructors) {
        final key = elementKey(constructor);
        graph.nodes.putIfAbsent(
          key,
          () => MemberNode(
            declaration: node.declaration,
            element: constructor,
            owner: node,
            reportable: false,
          ),
        );
      }
    }
    owner = null;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitMixinDeclaration(MixinDeclaration node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitEnumDeclaration(EnumDeclaration node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitClassTypeAlias(ClassTypeAlias node) =>
      _instance(node, node.declaredFragment?.element);
  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _add(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _add(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _add(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _add(
      node,
      kind: DeclarationKind.method,
      finding:
          !node.isGetter && !node.isSetter && node.body is! EmptyFunctionBody,
    );
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _add(node, finding: false);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _add(node, kind: DeclarationKind.variable, finding: owner == null);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    _add(node, finding: false);
  }
}

/// Local bodies are executable nodes, never findings or implicit roots.
class _LocalDeclarations extends RecursiveAstVisitor<void> {
  final MemberGraph graph;
  final ResolvedUnitResult unit;
  final String file;
  _LocalDeclarations(this.graph, this.unit, this.file);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element is LocalFunctionElement) {
      final location = unit.lineInfo.getLocation(node.offset);
      final declaration = DeclarationNode(
        id: elementKey(element),
        name: element.name ?? 'local',
        kind: DeclarationKind.function,
        relativeFilePath: file,
        offset: node.offset,
        length: node.length,
        line: location.lineNumber,
        column: location.columnNumber,
        element: element,
      );
      graph.nodes[declaration.id] = MemberNode(
        declaration: declaration,
        element: element,
        ast: node,
        reportable: false,
      );
    }
    super.visitFunctionDeclaration(node);
  }
}

class _TestSites extends RecursiveAstVisitor<void> {
  final MemberGraph graph;
  final ResolvedUnitResult unit;
  final String file;
  _TestSites(this.graph, this.unit, this.file);
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final adapter = graph.options.frameworkAdapter;
    if (adapter.isTestCallSite(node) || adapter.isTestHarnessSite(node)) {
      final location = unit.lineInfo.getLocation(node.offset);
      final arguments = node.argumentList.arguments;
      final first = arguments.firstOrNull;
      final site = TestBlockSite(
        relativeFilePath: file,
        line: location.lineNumber,
        column: location.columnNumber,
        description: first is StringLiteral
            ? first.stringValue
            : node.methodName.name,
      );
      final edges = MemberEdges();
      // The registration wrapper itself is not evidence of exercised live code.
      for (final argument in arguments) {
        argument.accept(MemberReferences(graph, edges, unit.libraryElement));
      }
      graph.testSites[site] = edges;
    }
    super.visitMethodInvocation(node);
  }
}
