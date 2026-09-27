import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/src/cli.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _source = '''
void main() { Service().ping(); }
abstract class Contract { void unused(); }
class Service extends Contract {
  void ping() {}
  @override void unused() { dependency(); }
}
void dependency() {}
''';

void main() {
  _registrationWitnessTests();

  test('excluded tests do not contribute independent witnesses', () async {
    await memberFixture(
      _source,
      tests: '''
import 'package:app/main.dart';
import 'excluded_test.dart';
void test(String name, void Function() body) { body(); }
void main() { test('included', () { exercise(); }); }
''',
    );
    await d.dir('app/test', [
      d.file('excluded_test.dart', '''
import 'package:app/main.dart';
void exercise() { Service().unused(); }
void test(String name, void Function() body) { body(); }
void main() {
  test('excluded', () { Service().unused(); Service().ping(); });
}
'''),
    ]).create();
    final report = await UndeadEngine(
      UndeadOptions(
        packagePath: d.path('app'),
        mode: AnalysisMode.closedApp,
        memberLevel: true,
        exampleMode: ExampleMode.skip,
        workspaceDiscovery: false,
        excludePatterns: ['test/excluded_test.dart'],
      ),
    ).analyze();
    final finding = report.undead.singleWhere(
      (f) => f.name == 'Service.unused',
    );
    expect(finding.classification, UndeadClassification.testedUndead);
    expect(finding.orphanTests!.map((s) => s.description), ['included']);
    expect(findingNames(report), {'Service.unused', 'dependency'});
  });

  for (final assumed in [false, true]) {
    test('unnamed extension IDs remain unique with assumed=$assumed', () async {
      final report = await memberFixture('''
extension on int { void live() {} void unused() {} }
extension on String { void live() {} void unused() {} }
class Protocol {
  @override String toString() { 1.unused(); ''.unused(); return ''; }
}
void main() { 1.live(); ''.live(); ${assumed ? 'Protocol();' : ''} }
''');
      final findings = (assumed ? report.uncertainCandidates : report.undead)
          .where((f) => f.name == 'anonymous.unused')
          .toList();
      expect(findings, hasLength(2));
      expect(findings.map((f) => f.id).toSet(), hasLength(2));
    });
  }

  for (final form in ['closure', 'parenthesized', 'named', 'assigned']) {
    test(
      '$form callback aliases preserve only selected test witnesses',
      () async {
        final unrelated = switch (form) {
          'parenthesized' => 'final unrelated = (() { Service().ping(); });',
          'named' => 'final unrelated = callback;',
          'assigned' => 'void Function()? unrelated; unrelated = callback;',
          _ => 'final unrelated = () { Service().ping(); };',
        };
        final report = await memberFixture(
          _source,
          tests:
              '''
import 'package:app/main.dart';
void test(String name, void Function() body) { body(); }
void callback() { Service().ping(); }
void main() {
  final isolated = () { Service().unused(); };
  final mixed = () { Service().unused(); Service().ping(); };
  $unrelated
  final alias = mixed;
  test('isolated', isolated);
  test('mixed', alias);
}
''',
        );
        final finding = report.undead.singleWhere(
          (f) => f.name == 'Service.unused',
        );
        expect(finding.orphanTests!.map((s) => s.description), [
          'isolated',
          'mixed',
        ]);
        expect(finding.orphanTests!.map((s) => s.coInvokedHazard), [
          false,
          true,
        ]);
        expect(findingNames(report), {'Service.unused', 'dependency'});
      },
    );
  }

  test('CLI and API produce the same member report', () async {
    final expected = await memberFixture(_source);
    final output = StringBuffer();
    final errors = StringBuffer();
    final status = await UndeadCliRunner(outSink: output, errSink: errors).run([
      '--member-level',
      '--mode=closed-app',
      '--example-mode=skip',
      '--no-workspace-discovery',
      '--format=json',
      d.path('app'),
    ]);
    expect(status, 0, reason: errors.toString());
    expect(jsonDecode(output.toString()), expected.toJson());
  });

  test('unsupported option combinations fail clearly', () async {
    await memberFixture(_source);
    for (final flags in [
      ['--member-level'],
      ['--member-level', '--mode=closed-app', '--suggest-private'],
    ]) {
      final errors = StringBuffer();
      final status = await UndeadCliRunner(
        outSink: StringBuffer(),
        errSink: errors,
      ).run([...flags, d.path('app')]);
      expect(status, 64);
      expect(errors.toString(), contains('--member-level requires'));
    }
    expect(
      () => UndeadEngine(
        UndeadOptions(packagePath: d.path('app'), memberLevel: true),
      ).analyze(),
      throwsArgumentError,
    );
  });

  test(
    'member metadata round-trips and never promises safe deletion',
    () async {
      final report = await memberFixture(_source);
      final finding = report.undead.singleWhere(
        (f) => f.name == 'Service.unused',
      );
      expect(finding.kind, DeclarationKind.method);
      expect(finding.id, 'lib/main.dart#method#Service.unused');
      expect(finding.hasInheritedContract, isTrue);
      expect(report.undead.map((f) => f.suggestedAction).toSet(), {
        SuggestedAction.review,
      });
      expect(UndeadReport.fromJson(report.toJson()).toJson(), report.toJson());
      final markdown = const MarkdownFormatter().format(report);
      expect(markdown, contains('inherited contract'));
      expect(markdown, isNot(contains('Safe to Delete')));
      expect(markdown, isNot(contains('Delete declaration')));
    },
  );

  test('default reports retain their original JSON schema', () async {
    final report = await memberFixture(_source, memberLevel: false);
    expect(report.toJson(), isNot(contains('memberLevel')));
    expect(report.toJson(), isNot(contains('coverageLimitations')));
    expect(findingNames(report), isEmpty);
  });

  test('homonymous owners in different libraries have distinct IDs', () async {
    final report = await memberFixture(
      '''
import 'first.dart' as first;
import 'second.dart' as second;
void main() { first.Service().live(); second.Service().live(); }
''',
      files: {
        'first.dart': 'class Service { void live() {} void unused() {} }',
        'second.dart': 'class Service { void live() {} void unused() {} }',
      },
    );
    expect(report.undead.map((f) => f.name), everyElement('Service.unused'));
    expect(report.undead.map((f) => f.id).toSet(), hasLength(2));
  });

  test(
    'body co-invocation is a hazard; constructing a live owner alone is not',
    () async {
      final report = await memberFixture(
        _source,
        tests: '''
import 'package:app/main.dart';
void test(String description, void Function() body) { body(); }
void main() {
  test('isolated', () { Service().unused(); });
  test('mixed', () { Service().unused(); Service().ping(); });
}
''',
      );
      final finding = report.undead.singleWhere(
        (f) => f.name == 'Service.unused',
      );
      expect(finding.classification, UndeadClassification.coInvokedHazard);
      expect(
        finding.orphanTests!
            .singleWhere((s) => s.description == 'isolated')
            .coInvokedHazard,
        isFalse,
      );
      expect(
        finding.orphanTests!
            .singleWhere((s) => s.description == 'mixed')
            .coInvokedHazard,
        isTrue,
      );
    },
  );
  test(
    'analyzePackage propagates memberLevel through path normalization',
    () async {
      await memberFixture(_source);
      final report = await analyzePackage(
        d.path('app'),
        options: UndeadOptions(
          packagePath: '',
          mode: AnalysisMode.closedApp,
          memberLevel: true,
          workspaceDiscovery: false,
          exampleMode: ExampleMode.skip,
        ),
      );
      expect(report.memberLevel, isTrue);
      expect(findingNames(report), contains('Service.unused'));
    },
  );
  test('member comments and test-support patterns suppress findings', () async {
    final report = await memberFixture(
      '''
void main() { Service().live(); }
class Service {
  void live() {}
  // undead:ignore
  void ignored() {}
  void candidate() {}
}
class FakeService { void run() {} }
''',
      tests: '''
import 'package:app/main.dart';
void main() { FakeService().run(); }
''',
    );
    expect(findingNames(report), {'Service.candidate'});
  });
}

void _registrationWitnessTests() {
  for (final registration in ['fixture', 'local']) {
    test('$registration receivers preserve isolated test witnesses', () async {
      final declaration = registration == 'fixture'
          ? 'late Service service;'
          : '';
      final creation = registration == 'fixture'
          ? 'setUp(() { service = Service(); });'
          : 'final service = Service();';
      final report = await memberFixture(
        _source,
        tests:
            '''
import 'package:app/main.dart';
void setUp(void Function() body) { body(); }
void test(String description, void Function() body) { body(); }
void group(String description, void Function() body) { body(); }
$declaration
void main() {
  $creation
  test('isolated', () { service.unused(); });
  test('mixed', () { service.unused(); service.ping(); });
  group('with fixture work', () {
    setUp(() { service.ping(); });
    test('fixture-live', () { service.unused(); });
  });
  group('without fixture work', () {
    test('sibling-isolated', () { service.unused(); });
  });
}
''',
      );
      expect(findingNames(report), {'Service.unused', 'dependency'});
      final finding = report.undead.singleWhere(
        (f) => f.name == 'Service.unused',
      );
      expect(finding.classification, UndeadClassification.coInvokedHazard);
      expect(finding.orphanTests!.map((s) => s.description), [
        'isolated',
        'mixed',
        'fixture-live',
        'sibling-isolated',
      ]);
      expect(finding.orphanTests!.map((s) => s.coInvokedHazard), [
        false,
        true,
        true,
        false,
      ]);
    });
  }
}
