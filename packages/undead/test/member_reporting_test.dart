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
