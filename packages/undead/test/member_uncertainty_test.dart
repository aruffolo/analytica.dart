import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/src/cli.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

List<Map<String, dynamic>> uncertain(UndeadReport report) =>
    ((report.toJson()['uncertainCandidates'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

void main() {
  test(
    'protocol-only bodies and exclusive helpers remain reviewable',
    () async {
      final report = await memberFixture('''
void main() { Service().run(); }
class Service {
  void run() {}
  @override String toString() => hidden();
  void unused() {}
}
String hidden() => 'hidden';
''');
      expect(findingNames(report), {'Service.unused'});
      final candidates = uncertain(report);
      expect(candidates.map((f) => f['name']).toSet(), {
        'Service.toString',
        'hidden',
      });
      for (final finding in candidates) {
        expect(finding['classification'], 'uncertain');
        expect(finding['suggestedAction'], 'review');
        expect(finding['retentionReasons'], contains('externalProtocol'));
      }
      expect(UndeadReport.fromJson(report.toJson()).toJson(), report.toJson());
      expect(
        const MarkdownFormatter().format(report),
        contains('Uncertain candidates'),
      );
    },
  );

  test('an explicit live path suppresses assumption-only candidates', () async {
    final report = await memberFixture('''
void main() { print(Service().toString()); }
class Service { @override String toString() => helper(); }
String helper() => 'live';
''');
    expect(findingNames(report), isEmpty);
    expect(uncertain(report), isEmpty);
  });

  test(
    'implicit JSON uncertainty follows exclusive dependency chains',
    () async {
      final report = await memberFixture('''
import 'dart:convert';
void main() { print(jsonEncode(Invoice(), toEncodable: (_) => 9)); }
class Invoice {
  Object toJson() => RetiredExporter().render();
  void unused() {}
}
class RetiredExporter { String render() => obsoleteText(); }
String obsoleteText() => 'old';
''');
      expect(findingNames(report), {'Invoice.unused'});
      final candidates = uncertain(report);
      expect(candidates.map((f) => f['name']).toSet(), {
        'Invoice.toJson',
        'RetiredExporter',
        'obsoleteText',
      });
      for (final finding in candidates) {
        expect(finding['retentionReasons'], contains('implicitJsonProtocol'));
      }
    },
  );

  test('default report schema does not acquire member uncertainty', () {
    const report = UndeadReport(
      version: 'test',
      package: 'app',
      totalDeclarations: 0,
      pureUndeadFound: 0,
      testedUndeadFound: 0,
      coInvokedHazardsFound: 0,
      undead: [],
    );
    expect(report.toJson(), isNot(contains('uncertainCandidates')));
    expect(report.toJson()['summary'], isNot(contains('uncertainCandidates')));
  });
  test('unknown dispatch records the reason on exclusive helpers', () async {
    final report = await memberFixture('''
abstract interface class Port { void send(); }
class Sender implements Port { void send() { helper(); } }
void main() { <Port>[Sender()].first.send(); }
void helper() {}
''');
    expect(findingNames(report), isEmpty);
    final candidates = uncertain(report);
    expect(candidates.map((f) => f['name']).toSet(), {'Sender.send', 'helper'});
    for (final finding in candidates) {
      expect(finding['retentionReasons'], contains('unresolvedReceiver'));
    }
  });

  test('independent helper use suppresses uncertainty transitively', () async {
    final report = await memberFixture('''
void main() { Service(); print(helper()); }
class Service { @override String toString() => helper(); }
String helper() => 'live';
''');
    expect(uncertain(report).map((f) => f['name']).toSet(), {
      'Service.toString',
    });
  });

  test('uncertain candidates respect comments and name suppression', () async {
    await memberFixture('''
void main() { Service(); }
class Service {
  // undead:ignore
  @override String toString() => helper();
}
String helper() => 'hidden';
''');
    final report = await UndeadEngine(
      UndeadOptions(
        packagePath: d.path('app'),
        mode: AnalysisMode.closedApp,
        exampleMode: ExampleMode.skip,
        workspaceDiscovery: false,
        memberLevel: true,
        ignoreNamePatterns: ['helper'],
      ),
    ).analyze();
    expect(report.uncertainCandidates, isEmpty);
  });

  test('uncertainty alone does not trip the CLI dead-code gate', () async {
    final report = await memberFixture('''
void main() { Service(); }
class Service { @override String toString() => 'maybe'; }
''');
    final output = StringBuffer();
    final errors = StringBuffer();
    final status = await UndeadCliRunner(outSink: output, errSink: errors).run([
      '--mode=closed-app',
      '--member-level',
      '--example-mode=skip',
      '--no-workspace-discovery',
      '--format=json',
      '--fail-on-undead',
      d.path('app'),
    ]);
    expect(status, 0, reason: errors.toString());
    expect(jsonDecode(output.toString()), report.toJson());
    expect(report.pureUndeadFound, 0);
    expect(report.uncertainCandidates.single.name, 'Service.toString');
  });
}
