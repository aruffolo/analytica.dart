import 'package:test/test.dart';
import 'support/member_fixture.dart';

const _types = '''
abstract interface class Port { void run(); }
class North implements Port { void run(){ northEffect(); } }
class South implements Port { void run(){ southEffect(); } }
void northEffect() {}
void southEffect() {}
''';
void main() {
  test(
    'nested-loop work limit keeps reachable receiver alternatives',
    () async {
      var body = 'receiver.run(); receiver=South();';
      for (var depth = 0; depth < 14; depth++) {
        body = 'for(var i$depth=0;i$depth<2;i$depth++){$body}';
      }
      final report = await memberFixture('''
$_types
void main(){Port receiver=North();$body receiver.run();}
''');
      expect(findingNames(report), isEmpty);
    },
  );
  const precision = {
    'known for first entry': 'for(var i=0; i<1; i++) { receiver=South(); }',
    'different counter and bound':
        'for(var round=2; round<4; round++) { receiver=South(); }',
    'do loop first entry': 'do { receiver=South(); } while(false);',
  };
  for (final entry in precision.entries) {
    test(entry.key, () async {
      final report = await memberFixture('''
$_types
void main(){ Port receiver=North(); ${entry.value} receiver.run(); }
''');
      expect(findingNames(report), {'North.run', 'northEffect'});
      expect(report.uncertainCandidates, isEmpty);
    });
  }
  const preservation = {
    'zero trips possible':
        'for(var i=0; i<args.length; i++) { receiver=South(); } '
        'receiver.run();',
    'break before write':
        'for(var i=0; i<2; i++) { if(args.isEmpty) break; '
        'receiver=South(); } receiver.run();',
    'continue before write':
        'for(var i=0; i<2; i++) { if(args.isEmpty) continue; '
        'receiver=South(); } receiver.run();',
    'read then write in repeated body':
        'for(var i=0; i<2; i++) { receiver.run(); receiver=South(); }',
    'unknown while predicate':
        'while(args.isNotEmpty) { receiver=South(); break; } receiver.run();',
    'conditional write in entered loop':
        'for(var i=0; i<1; i++) { if(args.isNotEmpty) '
        'receiver=South(); } receiver.run();',
    'exception before overwrite':
        'try { if(args.isEmpty) throw StateError("stop"); '
        'receiver=South(); } catch(e) {} finally { receiver.run(); }',
    'nested loops':
        'for(var i=0; i<2; i++) { for(var j=0; j<args.length; j++) { '
        'receiver=South(); } receiver.run(); }',
  };
  for (final entry in preservation.entries) {
    test(entry.key, () async {
      final report = await memberFixture('''
$_types
void main(List<String> args){ Port receiver=North(); ${entry.value} }
''');
      expect(findingNames(report), isEmpty);
    });
  }
  test('literal zero trip keeps initial receiver', () async {
    final report = await memberFixture('''
$_types
void main(){ Port receiver=North(); for(var i=0; i<0; i++){ receiver=South(); } receiver.run(); }
''');
    expect(findingNames(report), isNot(contains('North.run')));
    expect(findingNames(report), isNot(contains('northEffect')));
  });
  test(
    'external writes invalidate assumptions about a global loop bound',
    () async {
      final report = await memberFixture('''
$_types
int bound = 0;
void reset() { bound = 0; }
void main() {
  bound = 1; reset(); Port receiver = North();
  for (var i = 0; i < bound; i++) { receiver = South(); }
  receiver.run();
}
''');
      expect(findingNames(report), isNot(contains('North.run')));
      expect(findingNames(report), isNot(contains('northEffect')));
    },
  );
}
