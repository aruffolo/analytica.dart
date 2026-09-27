import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'flow.dart';
import 'graph.dart';
import 'origins.dart';

/// Collects body effects without collapsing a member into its declaring class.
/// Shape walks retain signatures but never walk executable bodies/initializers.
class MemberReferences extends RecursiveAstVisitor<void> {
  final MemberGraph graph;
  final MemberEdges edges;
  final LibraryElement library;
  final bool shapeOnly;
  final Element? sourceElement;
  late final origins = ReceiverOrigins(graph, edges, sourceElement);
  MemberReferences(
    this.graph,
    this.edges,
    this.library, {
    this.shapeOnly = false,
    this.sourceElement,
  });

  void reference(
    Element? raw, {
    bool direct = false,
    ReceiverOrigin? receiver,
    List<CallArgument> arguments = const [],
    String? result,
  }) {
    if (raw == null) return;
    final element = raw.baseElement;
    _sdkJsonProtocol(element);
    if (element is MultiplyDefinedElement) {
      for (final conflicting in element.conflictingElements) {
        reference(
          conflicting,
          direct: direct,
          receiver: receiver,
          arguments: arguments,
          result: result,
        );
      }
      return;
    }
    if (element is ConstructorElement) {
      _constructor(element, direct);
      return;
    }
    if (element is ExecutableElement &&
        _dispatch(element, direct, receiver, arguments, result)) {
      return;
    }
    origins.bindCall(element, arguments);
    if (receiver != null && element is ExecutableElement && !element.isStatic) {
      edges.bind('this#${elementKey(element)}', receiver);
    }
    if (element is LocalVariableElement ||
        element is FormalParameterElement ||
        element is TypeParameterElement) {
      return;
    }
    edges.direct.add(elementKey(element));
  }

  void _sdkJsonProtocol(Element element) {
    if (element.library?.uri.toString() != 'dart:convert') return;
    final owner = element.enclosingElement;
    final exposesEncoder = switch (element) {
      TopLevelFunctionElement(name: 'jsonEncode') => true,
      GetterElement(name: 'json') => true,
      ExecutableElement() when owner is InterfaceElement => const {
        'JsonCodec',
        'JsonEncoder',
        'JsonUtf8Encoder',
      }.contains(owner.name),
      _ => false,
    };
    if (!exposesEncoder) return;
    // SDK JSON's default converter invokes object.toJson() dynamically, even
    // for objects nested in containers or returned by another toJson(). The
    // graph has no value flow for encoder configuration/container contents, so
    // conservatively retain this selector on allocated receivers. Keeping the
    // edge on the referencing node preserves production/test separation.
    edges.slots.add(
      DispatchSlot(null, 'toJson', library, DispatchKind.method, assumed: true),
    );
    final source =
        graph.nodes[sourceElement == null ? '' : elementKey(sourceElement!)];
    graph.limitation(
      'implicitJsonProtocol',
      source?.declaration.relativeFilePath ?? library.uri.toString(),
      source?.declaration.line ?? 1,
      'SDK JSON codec/encoder use conservatively retains toJson on allocated '
          'receivers, including nested values; custom converters and unused '
          'encoder configurations may retain extra methods.',
    );
  }

  void _constructor(ConstructorElement element, bool direct) {
    if (direct) {
      edges.direct.add(elementKey(element));
    } else {
      edges.constructions.add(element);
    }
  }

  bool _dispatch(
    ExecutableElement element,
    bool direct,
    ReceiverOrigin? receiver,
    List<CallArgument> arguments,
    String? result,
  ) {
    final sourceOwner = sourceElement?.enclosingElement;
    if (direct && sourceOwner is MixinElement) {
      edges.slots.add(
        DispatchSlot(
          sourceOwner,
          element is MethodElement ? element.lookupName! : element.name!,
          library,
          DispatchKind.of(element).asSuper,
          receiver: receiver ?? ReceiverOrigin.unknownValue,
          arguments: arguments,
          result: result,
        ),
      );
      return true;
    }
    final owner = element.enclosingElement;
    if (!element.isStatic &&
        owner is InterfaceElement &&
        owner is! ExtensionTypeElement &&
        !direct) {
      edges.slots.add(
        DispatchSlot(
          owner,
          element is MethodElement ? element.lookupName! : element.name!,
          library,
          DispatchKind.of(element),
          receiver: receiver ?? ReceiverOrigin.unknownValue,
          arguments: arguments,
          result: result,
        ),
      );
      return true;
    }
    return false;
  }

  @override
  void visitComment(Comment node) {}

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element is LocalFunctionElement && element != sourceElement) return;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitNamedType(NamedType node) {
    reference(node.element);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inDeclarationContext()) return;
    final parent = node.parent;
    if (parent is MethodInvocation && parent.methodName == node) return;
    final direct =
        parent is PropertyAccess && parent.realTarget is SuperExpression;
    final target = switch (parent) {
      PropertyAccess(:final realTarget) => realTarget,
      PrefixedIdentifier(:final prefix) => prefix,
      _ => null,
    };
    reference(
      node.element,
      direct: direct,
      receiver: target == null
          ? origins.implicitReceiver
          : origins.value(target),
      result: graph.resultKey(
        parent is PropertyAccess || parent is PrefixedIdentifier
            ? parent as Expression
            : node,
      ),
    );
    if (node.element == null &&
        (parent is PrefixedIdentifier || parent is PropertyAccess)) {
      _dynamicProperty(node, origins.value(target));
    }
    super.visitSimpleIdentifier(node);
  }

  void _dynamicProperty(SimpleIdentifier node, ReceiverOrigin receiver) {
    if (node.inGetterContext()) {
      edges.slots.add(
        DispatchSlot(
          null,
          node.name,
          library,
          DispatchKind.getter,
          receiver: receiver,
        ),
      );
    }
    if (node.inSetterContext()) {
      edges.slots.add(
        DispatchSlot(
          null,
          node.name,
          library,
          DispatchKind.setter,
          receiver: receiver,
        ),
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
    final receiver = node.realTarget == null
        ? origins.implicitReceiver
        : origins.value(node.realTarget);
    final arguments = origins.arguments(node.argumentList);
    if (node.methodName.element is VariableElement ||
        node.methodName.name == 'call' && node.realTarget != null) {
      edges.constructorCalls.add(
        ConstructorCall(
          origins.value(
            node.methodName.name == 'call' ? node.realTarget : node.methodName,
          ),
          arguments,
        ),
      );
    }
    reference(
      node.methodName.element,
      direct: node.realTarget is SuperExpression,
      receiver: receiver,
      arguments: arguments,
      result: graph.resultKey(node),
    );
    if (node.methodName.element == null && node.realTarget != null) {
      edges.slots.add(
        DispatchSlot(
          null,
          node.methodName.name,
          library,
          DispatchKind.method,
          receiver: receiver,
          arguments: arguments,
        ),
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
      _escapeArgument(argument, retainSurface: !protocolLibrary);
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

  void _escapeArgument(AstNode argument, {required bool retainSurface}) {
    final expression = ReceiverOrigins.argumentExpression(argument);
    if (expression == null) return;
    if (!retainSurface) return;
    final type = expression.staticType;
    if (type is InterfaceType &&
        graph.nodes.containsKey(elementKey(type.element))) {
      edges.escapedTypes.add(type.element);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    origins.bindCall(
      node.constructorName.element,
      origins.arguments(node.argumentList),
    );
    _externalBoundary(
      node.constructorName.element,
      node.argumentList.arguments,
      node.staticType,
    );
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    edges.constructorCalls.add(
      ConstructorCall(
        origins.value(node.function),
        origins.arguments(node.argumentList),
      ),
    );
    reference(
      node.element,
      receiver: origins.value(node.function),
      arguments: origins.arguments(node.argumentList),
      result: graph.resultKey(node),
    );
    if (node.element == null && node.function.staticType is DynamicType) {
      edges.slots.add(
        DispatchSlot(
          null,
          'call',
          library,
          DispatchKind.method,
          receiver: origins.value(node.function),
          arguments: origins.arguments(node.argumentList),
        ),
      );
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
    if (!shapeOnly) {
      origins.variable(node);
      super.visitVariableDeclaration(node);
    }
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    origins.returned(node.expression, node);
    super.visitReturnStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    origins.returned(node.expression, node);
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    origins.bindCall(
      node.element,
      origins.arguments(node.argumentList),
      forwardSuperParameters: true,
    );
    reference(node.element, direct: true);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    origins.bindCall(node.element, origins.arguments(node.argumentList));
    reference(node.element, direct: true);
    super.visitRedirectingConstructorInvocation(node);
  }

  bool _isSuperAccess(Expression expression) => switch (expression) {
    PropertyAccess(:final realTarget) => realTarget is SuperExpression,
    IndexExpression(:final realTarget) => realTarget is SuperExpression,
    _ => false,
  };

  ReceiverOrigin _accessReceiver(Expression expression) => switch (expression) {
    PropertyAccess(:final realTarget) => origins.value(realTarget),
    PrefixedIdentifier(:final prefix) => origins.value(prefix),
    IndexExpression(:final realTarget) => origins.value(realTarget),
    SimpleIdentifier() => origins.implicitReceiver,
    _ => ReceiverOrigin.unknownValue,
  };

  void _operator(
    Element? element,
    Expression receiver,
    String operator, {
    bool unary = false,
    DartType? readType,
  }) {
    reference(
      element,
      direct: receiver is SuperExpression,
      receiver: origins.value(receiver),
    );
    if (element != null || (readType ?? receiver.staticType) is! DynamicType) {
      return;
    }
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
    edges.slots.add(
      DispatchSlot(
        null,
        name,
        library,
        DispatchKind.method,
        receiver: origins.value(receiver),
      ),
    );
    _dynamicLimitation();
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    // Destructuring writes each resolved variable, including nested patterns.
    if (!shapeOnly) origins.invalidate(node.element);
    super.visitAssignedVariablePattern(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    // Iteration can overwrite an existing local or parameter without an
    // AssignmentExpression. Container element origins are not modeled.
    if (!shapeOnly) origins.update(node.identifier);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (!shapeOnly) origins.assignment(node);
    _operator(
      node.element,
      node.leftHandSide,
      node.operator.lexeme,
      readType: node.readType,
    );
    reference(
      node.readElement,
      direct: _isSuperAccess(node.leftHandSide),
      receiver: _accessReceiver(node.leftHandSide),
    );
    reference(
      node.writeElement,
      direct: _isSuperAccess(node.leftHandSide),
      receiver: _accessReceiver(node.leftHandSide),
    );
    super.visitAssignmentExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _operator(node.element, node.leftOperand, node.operator.lexeme);
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (const {'++', '--'}.contains(node.operator.lexeme)) {
      origins.update(node.operand);
    }
    _operator(
      node.element,
      node.operand,
      node.operator.lexeme,
      unary: true,
      readType: node.readType,
    );
    reference(
      node.readElement,
      direct: _isSuperAccess(node.operand),
      receiver: _accessReceiver(node.operand),
    );
    reference(
      node.writeElement,
      direct: _isSuperAccess(node.operand),
      receiver: _accessReceiver(node.operand),
    );
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (const {'++', '--'}.contains(node.operator.lexeme)) {
      origins.update(node.operand);
    }
    _operator(
      node.element,
      node.operand,
      node.operator.lexeme,
      readType: node.readType,
    );
    reference(
      node.readElement,
      direct: _isSuperAccess(node.operand),
      receiver: _accessReceiver(node.operand),
    );
    reference(
      node.writeElement,
      direct: _isSuperAccess(node.operand),
      receiver: _accessReceiver(node.operand),
    );
    super.visitPostfixExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    reference(
      node.element,
      direct: node.realTarget is SuperExpression,
      receiver: origins.value(node.realTarget),
    );
    if (node.element == null) {
      if (node.inGetterContext()) {
        edges.slots.add(
          DispatchSlot(
            null,
            '[]',
            library,
            DispatchKind.method,
            receiver: origins.value(node.realTarget),
          ),
        );
      }
      if (node.inSetterContext()) {
        edges.slots.add(
          DispatchSlot(
            null,
            '[]=',
            library,
            DispatchKind.method,
            receiver: origins.value(node.realTarget),
          ),
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
