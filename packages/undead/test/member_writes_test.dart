import 'package:test/test.dart';

import 'support/member_fixture.dart';

const _types = '''
abstract interface class Channel { void send(); }
class Before implements Channel { void send() {} }
class After implements Channel { void send() { delivered(); } }
void delivered() {}
class Decoy { void send() { unrelated(); } void close() {} }
void unrelated() {}
''';

void main() {
  const writes = {
    'record assignment': '(channel,) = (After(),);',
    'nested list assignment': '([channel],) = (<Channel>[After()],);',
    'existing for-in variable': 'for (channel in <Channel>[After()]) {}',
    'collection for-in variable':
        'final values = [for (channel in <Channel>[After()]) channel];',
    'await for-in variable':
        'await for (channel in Stream<Channel>.value(After())) {}',
    'ordinary assignment control': 'channel = After();',
  };
  for (final entry in writes.entries) {
    test('${entry.key} preserves the new receiver and dependencies', () async {
      final report = await memberFixture('''
$_types
Future<void> main() async {
  Channel channel = Before();
  ${entry.value}
  channel.send();
  Decoy().close();
}
''');
      expect(
        report.coverageLimitations.where(
          (item) =>
              item.code == 'resolutionError' || item.code == 'unresolvedUnit',
        ),
        isEmpty,
      );
      expect(findingNames(report), {
        'Decoy.send',
        'unrelated',
        // The ordinary write replaces Before before its only possible call.
        if (entry.key == 'ordinary assignment control') 'Before.send',
      });
    });
  }

  for (final write in [
    writes['record assignment']!,
    writes['existing for-in variable']!,
  ]) {
    test('parameter writes preserve their new receiver: $write', () async {
      final report = await memberFixture('''
$_types
void dispatch(Channel channel) { $write channel.send(); }
void main() { dispatch(Before()); Decoy().close(); }
''');
      expect(findingNames(report), {'Decoy.send', 'unrelated'});
    });
  }

  test('an uncalled local write does not widen an executed receiver', () async {
    final report = await memberFixture('''
$_types
void main() {
  Channel channel = Before();
  void abandoned() { (channel,) = (After(),); }
  channel.send();
  After();
  Decoy().close();
}
''');
    expect(findingNames(report), {
      'After.send',
      'delivered',
      'Decoy.send',
      'unrelated',
    });
  });

  test('test-side writes do not widen production receivers', () async {
    final report = await memberFixture(
      '''
$_types
void dispatch(Channel channel) { channel.send(); }
void main() { dispatch(Before()); After(); Decoy().close(); }
''',
      tests: '''
import 'package:app/main.dart';
void main() {
  Channel channel = Before();
  for (channel in <Channel>[After()]) {}
  dispatch(channel);
}
''',
    );
    expect(findingNames(report), {
      'After.send',
      'delivered',
      'Decoy.send',
      'unrelated',
    });
    expect(
      report.undead
          .singleWhere((f) => f.name == 'After.send')
          .classification
          .jsonValue,
      'testedUndead',
    );
  });
}
