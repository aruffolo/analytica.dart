import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'graph.dart';

/// Collects body effects without collapsing a member into its declaring class.
/// Shape walks retain signatures but never walk executable bodies/initializers.
class MemberReferences extends RecursiveAstVisitor<void> {
  final MemberGraph graph;
  final MemberEdges edges;
  final LibraryElement library;
  final bool shapeOnly;
  final Element? sourceElement;
  MemberReferences(
    this.graph,
    this.edges,
    this.library, {
    this.shapeOnly = false,
    this.sourceElement,
  });

  void reference(Element? raw, {bool direct = false}) {
    if (raw == null) return;
    final element = raw.baseElement;
    if (element is MultiplyDefinedElement) {
      for (final conflicting in element.conflictingElements) {
        reference(conflicting, direct: direct);
      }
      return;
    }
    if (element is ConstructorElement) {
      _constructor(element, direct);
      return;
    }
    if (element is ExecutableElement && _dispatch(element, direct)) return;
    if (element is LocalVariableElement ||
        element is FormalParameterElement ||
        element is LocalFunctionElement ||
        element is TypeParameterElement) {
      return;
    }
    edges.direct.add(elementKey(element));
  }

  void _constructor(ConstructorElement element, bool direct) {
    if (direct) {
      edges.direct.add(elementKey(element));
    } else {
      edges.constructions.add(element);
    }
  }

  bool _dispatch(ExecutableElement element, bool direct) {
    final sourceOwner = sourceElement?.enclosingElement;
    if (direct && sourceOwner is MixinElement) {
      edges.slots.add(
        DispatchSlot(
          sourceOwner,
          element is MethodElement ? element.lookupName! : element.name!,
          library,
          DispatchKind.of(element).asSuper,
        ),
      );
      return true;
    }
    final owner = element.enclosingElement;
    if (!element.isStatic && owner is InterfaceElement && !direct) {
      edges.slots.add(
        DispatchSlot(
          owner,
          element is MethodElement ? element.lookupName! : element.name!,
          library,
          DispatchKind.of(element),
        ),
      );
      return true;
    }
    return false;
  }

  @override
  void visitComment(Comment node) {}
  @override
  void visitNamedType(NamedType node) {
    reference(node.element);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext()) {
      final parent = node.parent;
      final direct =
          (parent is MethodInvocation &&
              parent.realTarget is SuperExpression) ||
          (parent is PropertyAccess && parent.realTarget is SuperExpression);
      reference(node.element, direct: direct);
      if (node.element == null &&
          (parent is PrefixedIdentifier || parent is PropertyAccess)) {
        _dynamicProperty(node);
      }
    }
    super.visitSimpleIdentifier(node);
  }

  void _dynamicProperty(SimpleIdentifier node) {
    if (node.inGetterContext()) {
      edges.slots.add(
        DispatchSlot(null, node.name, library, DispatchKind.getter),
      );
    }
    if (node.inSetterContext()) {
      edges.slots.add(
        DispatchSlot(null, node.name, library, DispatchKind.setter),
      );
    }
    _dynamicLimitation();
  }

  void _dynamicLimitation() {
    final source =
        graph.nodes[sourceElement == null ? '' : elementKey(sourceElement!)];
    graph.limitation(
      'dynamicDispatch',
      source?.declaration.relativeFilePath ?? library.uri.toString(),
      source?.declaration.line ?? 1,
      'Unresolved selector retains matching members on allocated receivers.',
    );
  }

  @override
  void visitPatternField(PatternField node) {
    reference(node.element);
    super.visitPatternField(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    reference(node.constructorElement);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.element == null && node.realTarget != null) {
      edges.slots.add(
        DispatchSlot(null, node.methodName.name, library, DispatchKind.method),
      );
      _dynamicLimitation();
    }
    _externalBoundary(
      node.methodName.element,
      node.argumentList.arguments,
      node.staticType,
    );
    super.visitMethodInvocation(node);
  }

  void _externalBoundary(
    Element? target,
    Iterable<AstNode> arguments,
    DartType? resultType,
  ) {
    if (target == null) return;
    if (graph.nodes.containsKey(elementKey(target)) &&
        !(target is ExecutableElement && target.isExternal)) {
      return;
    }
    // SDK/framework protocols invoke declared interface hooks, already modeled
    // on allocations. Arbitrary foreign functions can use dynamic receivers.
    final uri = target.library?.uri;
    final protocolLibrary =
        uri?.scheme == 'dart' ||
        uri?.toString().startsWith('package:flutter/') == true;
    for (final argument in arguments) {
      final expression = argument is Expression
          ? argument
          : argument.childEntities.whereType<Expression>().firstOrNull;
      final type = expression?.staticType;
      if (!protocolLibrary &&
          type is InterfaceType &&
          graph.nodes.containsKey(elementKey(type.element))) {
        edges.escapedTypes.add(type.element);
      }
    }
    if (resultType is InterfaceType &&
        graph.nodes.containsKey(elementKey(resultType.element))) {
      edges.runtimeTypes.add(resultType.element);
      edges.direct.add(elementKey(resultType.element));
      final source =
          graph.nodes[sourceElement == null ? '' : elementKey(sourceElement!)];
      graph.limitation(
        'externalResult',
        source?.declaration.relativeFilePath ?? library.uri.toString(),
        source?.declaration.line ?? 1,
        'External result conservatively admits compatible local receivers.',
      );
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _externalBoundary(
      node.constructorName.element,
      node.argumentList.arguments,
      node.staticType,
    );
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    reference(node.element);
    if (node.element == null && node.function.staticType is DynamicType) {
      edges.slots.add(DispatchSlot(null, 'call', library, DispatchKind.method));
      _dynamicLimitation();
    }
    _externalBoundary(
      node.element,
      node.argumentList.arguments,
      node.staticType,
    );
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitImplicitCallReference(ImplicitCallReference node) {
    reference(node.element);
    super.visitImplicitCallReference(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    reference(node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    reference(node.element);
    super.visitAnnotation(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!shapeOnly) {
      super.visitMethodDeclaration(node);
      return;
    }
    node.returnType?.accept(this);
    node.typeParameters?.accept(this);
    node.parameters?.accept(this);
    for (final annotation in node.metadata) {
      annotation.accept(this);
    }
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (!shapeOnly) {
      super.visitConstructorDeclaration(node);
      return;
    }
    node.parameters.accept(this);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (!shapeOnly) super.visitVariableDeclaration(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    reference(node.element, direct: true);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    reference(node.element);
    super.visitRedirectingConstructorInvocation(node);
  }

  bool _isSuperAccess(Expression expression) => switch (expression) {
    PropertyAccess(:final realTarget) => realTarget is SuperExpression,
    IndexExpression(:final realTarget) => realTarget is SuperExpression,
    _ => false,
  };

  void _operator(
    Element? element,
    Expression receiver,
    String operator, {
    bool unary = false,
  }) {
    reference(element, direct: receiver is SuperExpression);
    if (element != null || receiver.staticType is! DynamicType) return;
    var name = switch (operator) {
      '++' || '+=' => '+',
      '--' || '-=' => '-',
      '!=' => '==',
      _ => operator,
    };
    if (name.endsWith('=') && name != '==' && name != '<=' && name != '>=') {
      name = name.substring(0, name.length - 1);
    }
    if (unary && operator == '-') name = 'unary-';
    const selectors = {
      '+',
      '-',
      'unary-',
      '~',
      '*',
      '/',
      '~/',
      '%',
      '<',
      '<=',
      '>',
      '>=',
      '==',
      '&',
      '|',
      '^',
      '<<',
      '>>',
      '>>>',
    };
    if (!selectors.contains(name)) return;
    edges.slots.add(DispatchSlot(null, name, library, DispatchKind.method));
    _dynamicLimitation();
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _operator(node.element, node.leftHandSide, node.operator.lexeme);
    reference(node.readElement, direct: _isSuperAccess(node.leftHandSide));
    reference(node.writeElement, direct: _isSuperAccess(node.leftHandSide));
    super.visitAssignmentExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _operator(node.element, node.leftOperand, node.operator.lexeme);
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _operator(node.element, node.operand, node.operator.lexeme, unary: true);
    reference(node.readElement, direct: _isSuperAccess(node.operand));
    reference(node.writeElement, direct: _isSuperAccess(node.operand));
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _operator(node.element, node.operand, node.operator.lexeme);
    reference(node.readElement, direct: _isSuperAccess(node.operand));
    reference(node.writeElement, direct: _isSuperAccess(node.operand));
    super.visitPostfixExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    reference(node.element, direct: node.realTarget is SuperExpression);
    if (node.element == null) {
      if (node.inGetterContext()) {
        edges.slots.add(DispatchSlot(null, '[]', library, DispatchKind.method));
      }
      if (node.inSetterContext()) {
        edges.slots.add(
          DispatchSlot(null, '[]=', library, DispatchKind.method),
        );
      }
      _dynamicLimitation();
    }
    super.visitIndexExpression(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    reference(node.element);
    super.visitRelationalPattern(node);
  }
}
