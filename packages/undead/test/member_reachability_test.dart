import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _cycle = '''
void main() { Live().run(); }
class Live {
  void run() {}
  void unusedMethod() { HiddenA().run(); }
  void testedOnly() { TestA().run(); }
}
class HiddenA { void run() { HiddenB().run(); } }
class HiddenB { void run() { HiddenA().run(); } }
class TestA { void run() { TestB().run(); } }
class TestB { void run() { TestA().run(); } }
''';

void main() {
  test(
    'unused method does not keep its disconnected dependency cycle alive',
    () async {
      final report = await memberFixture(_cycle);
      expect(
        findingNames(report),
        containsAll(['Live.unusedMethod', 'HiddenA', 'HiddenB']),
      );
      expect(findingNames(report), isNot(contains('Live.run')));
      expect(findingNames(report), isNot(contains('Live')));
      expect(
        report.undead.where((f) => f.name.startsWith('HiddenA.')),
        isEmpty,
      );
    },
  );

  test('default graph remains coarse', () async {
    final report = await memberFixture(_cycle, memberLevel: false);
    expect(findingNames(report), isEmpty);
  });

  test('tests retain a separate transitive witness', () async {
    final report = await memberFixture(
      _cycle,
      tests: '''
import 'package:app/main.dart';
void test(String name, void Function() body) { body(); }
void helper() { Live().testedOnly(); }
void main() { test('obsolete behavior', helper); }
''',
    );
    for (final name in ['Live.testedOnly', 'TestA', 'TestB']) {
      final finding = report.undead.singleWhere((f) => f.name == name);
      expect(finding.classification, UndeadClassification.testedUndead);
      expect(finding.orphanTests, isNotEmpty);
    }
  });

  test('production call promotes the entire dependency cycle', () async {
    final report = await memberFixture(
      _cycle.replaceFirst(
        'Live().run();',
        'Live().run(); Live().unusedMethod();',
      ),
    );
    expect(
      findingNames(
        report,
      ).intersection({'Live.unusedMethod', 'HiddenA', 'HiddenB'}),
      isEmpty,
    );
  });

  test('generic and part references preserve owner identities', () async {
    final report = await memberFixture(
      '''
part 'other.dart';
void main() { Box<int>(1).read(); Other().run(); }
class Box<T> {
  Box(this.value);
  T value;
  T read() => value;
  void run() { Dead().run(); }
}
class Dead { void run() {} }
''',
      files: {
        'other.dart':
            "part of 'main.dart'; "
            'class Other { void run() {} void unused() {} }',
      },
    );
    expect(
      findingNames(report),
      containsAll(['Box.run', 'Dead', 'Other.unused']),
    );
    expect(
      findingNames(
        report,
      ).intersection({'Other.run', 'Other', 'Box', 'Box.read'}),
      isEmpty,
    );
    expect(
      report.undead.singleWhere((f) => f.name == 'Other.unused').file,
      'lib/other.dart',
    );
  });
}
