import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _declarations = <String>[
  'class Live { void run() {} void dormant() { A().run(); } }',
  'class A { void run() { B().run(); } }',
  'class B { void run() { A().run(); } }',
  'class Other { void run() {} void dormant() {} }',
];

String _rename(String source) {
  for (final pair in {
    'Live': 'Alpha',
    'A': 'Beta',
    'B': 'Gamma',
    'Other': 'Delta',
    'run': 'execute',
    'dormant': 'quiet',
  }.entries) {
    source = source.replaceAll(RegExp('\\b${pair.key}\\b'), pair.value);
  }
  return source;
}

Future<UndeadReport> _variantReport(String variant) {
  final declarations =
      (variant == 'reverse' ? _declarations.reversed : _declarations).join(
        '\n',
      );
  const entry = 'void main() { Live().run(); Other().run(); }';
  return switch (variant) {
    'rename' => memberFixture(_rename('$entry\n$declarations')),
    'move' => memberFixture(
      "import 'moved.dart';\n$entry",
      files: {'moved.dart': declarations},
    ),
    'part' => memberFixture(
      "part 'moved.dart';\n$entry",
      files: {'moved.dart': "part of 'main.dart';\n$declarations"},
    ),
    _ => memberFixture('$entry\n$declarations'),
  };
}

Future<void> _checkVariant(String variant) async {
  final report = await _variantReport(variant);
  final expected = variant == 'rename'
      ? {'Alpha.quiet', 'Beta', 'Gamma', 'Delta.quiet'}
      : {'Live.dormant', 'A', 'B', 'Other.dormant'};
  expect(findingNames(report), expected);
  expect(
    report.coverageLimitations.where((l) => l.code == 'resolutionError'),
    isEmpty,
  );
}

Future<void> _checkPromotion(String sourceOfCall) async {
  final report = await memberFixture(
    '''
void main() { Live().run(); ${sourceOfCall == 'production' ? 'Live().dormant();' : ''} }
${_declarations.take(3).join('\n')}
''',
    tests: sourceOfCall == 'test'
        ? '''
import 'package:app/main.dart';
void main() { Live().dormant(); }
'''
        : null,
  );
  if (sourceOfCall == 'production') {
    expect(findingNames(report), isEmpty);
  } else {
    expect(findingNames(report), {'Live.dormant', 'A', 'B'});
    expect(report.undead.map((f) => f.classification).toSet(), {
      sourceOfCall == 'test'
          ? UndeadClassification.testedUndead
          : UndeadClassification.pureUndead,
    });
  }
}

void main() {
  for (final variant in ['original', 'rename', 'reverse', 'move', 'part']) {
    test('finding invariance under $variant', () => _checkVariant(variant));
  }
  for (final sourceOfCall in ['absent', 'test', 'production']) {
    test(
      'call promotion from $sourceOfCall has the expected classification',
      () => _checkPromotion(sourceOfCall),
    );
  }
}
