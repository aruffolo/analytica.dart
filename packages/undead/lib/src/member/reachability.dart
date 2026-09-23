import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../reachability_engine_helpers.dart';
import '../root_harvester.dart';
import 'graph.dart';

Future<UndeadReport> analyzeMembers(
  UndeadOptions options,
  PackageTopology topology,
  AnalysisContextHelper context,
) async {
  final graph = MemberGraph(options, topology);
  final included = topology.allFiles.toSet();
  // Filters suppress findings, not dependency transit through local source.
  final transit = RootHarvester(
    UndeadOptions(
      packagePath: options.packagePath,
      mode: options.mode,
      exampleMode: options.exampleMode,
      ignoreGenerated: false,
      workspaceDiscovery: false,
      frameworkAdapter: options.frameworkAdapter,
    ),
  ).harvestTopology();
  for (final file in {...included, ...transit.allFiles}) {
    final path = p.isAbsolute(file)
        ? file
        : p.join(p.absolute(options.packagePath), file);
    final unit = await context.getResolvedUnit(path);
    if (unit == null) {
      graph.limitation(
        'unresolvedUnit',
        file,
        1,
        'Could not resolve this input; '
            'findings require review of its references.',
      );
      continue;
    }
    for (final error in unit.diagnostics) {
      if (error.diagnosticCode.severity == DiagnosticSeverity.ERROR) {
        graph.limitation(
          'resolutionError',
          file,
          unit.lineInfo.getLocation(error.offset).lineNumber,
          'Resolved input contains an error: ${error.message}',
        );
      }
    }
    graph.addUnit(unit, file, reportable: included.contains(file));
  }
  graph.connect();
  final production = MemberReachability(graph)..run(graph.productionRoots);
  final tests = MemberReachability(graph)..run(graph.testRoots);
  final witnesses = <TestBlockSite, MemberReachability>{};
  for (final entry in graph.testSites.entries) {
    final reachability = MemberReachability(graph)..addEdges(entry.value);
    reachability.run(const {});
    witnesses[entry.key] = reachability;
  }
  return _report(graph, production, tests, witnesses);
}

/// Rapid type analysis: allocations and invoked interface slots grow to a fixed
/// point. Each run owns its state; tests cannot allocate production receivers.
class MemberReachability {
  final MemberGraph graph;
  final Set<String> live = {};
  final Set<InterfaceElement> allocated = {};
  final Set<DispatchSlot> slots = {};
  final Set<InterfaceElement> escaped = {};
  final List<String> _queue = [];
  final Set<InterfaceElement> _checkedProtocols = {};
  final Set<InterfaceElement> _checkedEscapes = {};
  final Set<(InterfaceElement, DispatchSlot)> _dispatched = {};
  MemberReachability(this.graph);

  void _add(String key) {
    if (graph.nodes.containsKey(key) && live.add(key)) _queue.add(key);
  }

  void addEdges(MemberEdges edges) {
    edges.direct.forEach(_add);
    slots.addAll(edges.slots);
    for (final runtimeType in edges.runtimeTypes) {
      allocated.addAll(
        graph.implementations[elementKey(runtimeType)] ?? const {},
      );
    }
    escaped.addAll(edges.escapedTypes);
    for (final constructor in edges.constructions) {
      _add(elementKey(constructor));
      _add(elementKey(constructor.enclosingElement));
      if (!constructor.isFactory &&
          graph.nodes.containsKey(elementKey(constructor.enclosingElement))) {
        allocated.add(constructor.enclosingElement);
      }
    }
  }

  void run(Set<String> roots) {
    roots.forEach(_add);
    var head = 0;
    while (true) {
      while (head < _queue.length) {
        addEdges(graph.nodes[_queue[head++]]!.edges);
      }
      for (final type in allocated.toList()) {
        _retainExternalOverrides(type);
        _retainEscapedSurface(type);
      }
      final previousSlotCount = slots.length;
      for (final slot in slots.toList()) {
        _dispatchSlot(slot);
      }
      if (head == _queue.length && slots.length == previousSlotCount) break;
    }
  }

  void _dispatchSlot(DispatchSlot slot) {
    final receivers = slot.owner == null
        ? allocated
        : graph.implementations[elementKey(slot.owner!)] ??
              const <InterfaceElement>{};
    for (final type in receivers) {
      if (!allocated.contains(type) || !_dispatched.add((type, slot))) continue;
      final target = _lookup(type, slot);
      if (target == null) continue;
      _add(elementKey(target));
      _invokeGetterResult(target, slot);
    }
  }

  void _invokeGetterResult(ExecutableElement target, DispatchSlot slot) {
    if (slot.kind != DispatchKind.method || target is! GetterElement) return;
    final result = target.returnType;
    // Function bodies/tear-offs are already traversed through the getter. An
    // object returned from it instead executes its call member. Unknown result
    // types conservatively admit all allocated callable receivers.
    if (result is FunctionType) return;
    slots.add(
      DispatchSlot(
        result is InterfaceType ? result.element : null,
        'call',
        slot.library,
        DispatchKind.method,
      ),
    );
  }

  void _retainEscapedSurface(InterfaceElement type) {
    if (_checkedEscapes.contains(type) ||
        !escaped.any((owner) => _compatible(type, owner))) {
      return;
    }
    _checkedEscapes.add(type);
    for (final node in graph.nodes.values) {
      final element = node.element;
      if (element is! ExecutableElement ||
          element.isStatic ||
          element.isPrivate) {
        continue;
      }
      final owner = element.enclosingElement;
      if (owner is! InterfaceElement || !_compatible(type, owner)) continue;
      _add(node.key);
      graph.limitation(
        'externalEscape',
        node.declaration.relativeFilePath,
        node.declaration.line,
        'Retained the public surface of a receiver passed to external code.',
      );
    }
  }

  void _retainExternalOverrides(InterfaceElement type) {
    if (!_checkedProtocols.add(type)) return;
    final overrides = graph.protocolCache.putIfAbsent(
      type,
      () => _externalOverrides(type),
    );
    for (final node in overrides) {
      _add(node.key);
      graph.limitation(
        'externalProtocol',
        node.declaration.relativeFilePath,
        node.declaration.line,
        'Retained an external protocol override on an allocated receiver.',
      );
    }
  }

  List<MemberNode> _externalOverrides(InterfaceElement type) {
    final result = <MemberNode>{};
    for (final supertype in type.allSupertypes) {
      final external = supertype.element;
      if (graph.nodes.containsKey(elementKey(external))) continue;
      for (final member in [
        ...external.methods,
        ...external.getters,
        ...external.setters,
      ]) {
        final target = _lookup(
          type,
          DispatchSlot(
            external,
            member is MethodElement ? member.lookupName! : member.name!,
            external.library,
            DispatchKind.of(member),
          ),
        );
        if (target == null) continue;
        final local = graph.nodes[elementKey(target)];
        if (local != null) result.add(local);
      }
    }
    return result.toList();
  }

  bool _compatible(InterfaceElement type, InstanceElement? owner) =>
      owner == null ||
      (graph.implementations[elementKey(owner)]?.contains(type) ?? false);

  ExecutableElement? _mixinSuper(InterfaceElement type, DispatchSlot slot) {
    for (final applied in [type, ...type.allSupertypes.map((t) => t.element)]) {
      final index = applied.mixins.indexWhere(
        (m) => elementKey(m.element) == elementKey(slot.owner!),
      );
      if (index < 0) continue;
      for (final mixin in applied.mixins.take(index).toList().reversed) {
        final method = switch (slot.kind) {
          DispatchKind.superGetter => mixin.element.getGetter(slot.name),
          DispatchKind.superSetter => mixin.element.getSetter(slot.name),
          _ => mixin.element.getMethod(slot.name),
        };
        if (method != null) return method;
      }
      final parent = applied.supertype?.element;
      return parent == null
          ? null
          : _lookup(
              parent,
              DispatchSlot(
                parent,
                slot.name,
                slot.library,
                slot.kind.asOrdinary,
              ),
            );
    }
    return null;
  }

  ExecutableElement? _lookup(InterfaceElement type, DispatchSlot slot) =>
      graph.dispatchCache.putIfAbsent(
        (type, slot),
        // A property read can tear off a method, and a method-style invocation
        // can invoke a callable getter/field. Preserve either Dart lookup form.
        () => switch (slot.kind) {
          DispatchKind.superMethod ||
          DispatchKind.superGetter ||
          DispatchKind.superSetter => _mixinSuper(type, slot),
          DispatchKind.getter =>
            type.lookUpGetter(name: slot.name, library: slot.library) ??
                type.lookUpMethod(name: slot.name, library: slot.library),
          DispatchKind.setter => type.lookUpSetter(
            name: slot.name,
            library: slot.library,
          ),
          DispatchKind.method =>
            type.lookUpMethod(name: slot.name, library: slot.library) ??
                type.lookUpGetter(name: slot.name, library: slot.library),
        },
      );
}

UndeadReport _report(
  MemberGraph graph,
  MemberReachability production,
  MemberReachability tests,
  Map<TestBlockSite, MemberReachability> witnesses,
) {
  final candidates = graph.nodes.values
      .where((node) => _candidate(graph, node, production.live))
      .toList();
  final candidateKeys = candidates.map((n) => n.key).toSet();
  final findings = <UndeadFinding>[];
  for (final node in candidates) {
    if (candidateKeys.contains(node.owner?.key)) continue;
    final sites = _orphanSites(node, graph, production, witnesses);
    final tested = tests.live.contains(node.key);
    if (tested && _testSupport(graph, node)) continue;
    final classification = !tested
        ? UndeadClassification.pureUndead
        : sites.any((s) => s.coInvokedHazard)
        ? UndeadClassification.coInvokedHazard
        : UndeadClassification.testedUndead;
    final decl = node.declaration;
    findings.add(
      UndeadFinding(
        id: '${decl.relativeFilePath}#${decl.kind.jsonValue}#${decl.name}',
        name: decl.name,
        kind: decl.kind,
        file: decl.relativeFilePath,
        line: decl.line,
        column: decl.column,
        length: decl.length,
        classification: classification,
        suggestedAction: SuggestedAction.review,
        orphanTests: sites,
        isExternalBinding: decl.isExternalBinding,
        hasInheritedContract: _hasInheritedContract(node.element),
      ),
    );
  }
  findings.sort(compareFindings);
  int count(UndeadClassification kind) =>
      findings.where((f) => f.classification == kind).length;
  return UndeadReport(
    version: '0.1.2-wip',
    memberLevel: true,
    package: graph.topology.packageName,
    totalDeclarations: graph.nodes.values.where((n) => n.reportable).length,
    pureUndeadFound: count(UndeadClassification.pureUndead),
    testedUndeadFound: count(UndeadClassification.testedUndead),
    coInvokedHazardsFound: count(UndeadClassification.coInvokedHazard),
    undead: findings,
    coverageLimitations: graph.limitations,
  );
}

List<OrphanTestSite> _orphanSites(
  MemberNode node,
  MemberGraph graph,
  MemberReachability production,
  Map<TestBlockSite, MemberReachability> witnesses,
) {
  final sites = <OrphanTestSite>[];
  for (final entry in witnesses.entries) {
    if (!entry.value.live.contains(node.key)) continue;
    final hazard = entry.value.live.any(
      (key) => production.live.contains(key) && graph.nodes[key]!.isExecution,
    );
    final site = entry.key;
    sites.add(
      OrphanTestSite(
        file: site.relativeFilePath,
        line: site.line,
        column: site.column,
        description: site.description,
        coInvokedHazard: hazard,
      ),
    );
  }
  return sites;
}

bool _candidate(MemberGraph graph, MemberNode node, Set<String> live) {
  if (!node.reportable || live.contains(node.key)) return false;
  final decl = node.declaration;
  if (decl.isIgnored ||
      graph.options.ignoreExternalBindings && decl.isExternalBinding) {
    return false;
  }
  final patterns = graph.options.ignoreNamePatterns
      .map(WildcardPattern.new)
      .toList();
  if (WildcardPattern.anyMatch(patterns, decl.name)) return false;
  final role = graph.topology.roleOf(decl.relativeFilePath);
  return switch (role) {
    FileRole.publicLib || FileRole.internalSrc => true,
    FileRole.executable || FileRole.auxiliary => decl.name != 'main',
    FileRole.demonstration =>
      graph.options.exampleMode == ExampleMode.strict && decl.name != 'main',
    _ => false,
  };
}

bool _hasInheritedContract(Element element) {
  final owner = element.enclosingElement;
  if (element is! MethodElement ||
      element.isStatic ||
      owner is! InterfaceElement) {
    return false;
  }
  return owner.allSupertypes.any(
    (type) => type.element.getMethod(element.lookupName!) != null,
  );
}

bool _testSupport(MemberGraph graph, MemberNode node) =>
    node.declaration.isTestSupport ||
    (node.owner?.declaration.isTestSupport ?? false) ||
    WildcardPattern.anyMatch(
      graph.options.testSupportPatterns.map(WildcardPattern.new).toList(),
      node.declaration.name,
    );
