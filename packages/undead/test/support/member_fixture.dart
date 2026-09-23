import 'dart:convert';

import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/undead.dart';

Future<UndeadReport> memberFixture(
  String source, {
  String? tests,
  Map<String, String> files = const {},
  bool memberLevel = true,
}) async {
  await d.dir('app', [
    d.file('pubspec.yaml', 'name: app\nenvironment:\n  sdk: ^3.12.0\n'),
    d.dir('.dart_tool', [
      d.file(
        'package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'app',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.12',
            },
          ],
        }),
      ),
    ]),
    d.dir('lib', [
      d.file('main.dart', source),
      ...files.entries.map((e) => d.file(e.key, e.value)),
    ]),
    if (tests != null) d.dir('test', [d.file('app_test.dart', tests)]),
  ]).create();
  return UndeadEngine(
    UndeadOptions(
      packagePath: d.path('app'),
      mode: AnalysisMode.closedApp,
      exampleMode: ExampleMode.skip,
      workspaceDiscovery: false,
      memberLevel: memberLevel,
    ),
  ).analyze();
}

Set<String> findingNames(UndeadReport report) =>
    report.undead.map((f) => f.name).toSet();
