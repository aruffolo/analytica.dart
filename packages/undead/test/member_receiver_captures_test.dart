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
  test('callback alias sees the cell at invocation, not declaration', () async {
    final report = await memberFixture('''
$_types
void main(){ Port receiver=North(); void callback(){ receiver.run(); }
final action=callback; receiver=South(); action(); }
''');
    expect(findingNames(report), {'North.run', 'northEffect'});
    expect(report.uncertainCandidates, isEmpty);
  });
  const controls = {
    'before and after':
        'void read(){receiver.run();} read(); receiver=South(); read();',
    'two aliases of same cell':
        'void read(){receiver.run();} final a=read; final b=read; '
        'a(); receiver=South(); b();',
    'writer then reader':
        'void read(){receiver.run();} void write(){receiver=South();}'
        ' read(); write(); read();',
    'caller observes callback write':
        'void write(){receiver=South();} receiver.run(); write(); '
        'receiver.run();',
    'captured value alias is independent':
        'final saved=receiver; void read(){saved.run();} '
        'receiver=South(); read(); receiver.run();',
    'callback parameter then capture':
        'void read(Port value){value.run();receiver.run();} '
        'receiver=South(); read(North());',
    'callback invoked in loop':
        'void read(){receiver.run();} for(var '
        'i=0;i<2;i++){read();receiver=South();}',
    'unknown callback invocation order':
        'void read(){receiver.run();} invoke(read); receiver=South();'
        ' invoke(read);',
    'return prevents captured write':
        'void write(){return; receiver=South();} write(); '
        'receiver.run(); South().run();',
  };
  for (final entry in controls.entries) {
    test(entry.key, () async {
      final report = await memberFixture('''
$_types
${entry.value.contains('invoke(') ? 'void invoke(void Function() callback){callback();}' : ''}
void main(){ Port receiver=North(); ${entry.value} }
''');
      expect(findingNames(report), isEmpty);
    });
  }
  test('separate activations preserve both captured values', () async {
    final report = await memberFixture('''
$_types
void outer(Port receiver){ void read(){receiver.run();} read(); }
void main(){outer(North());outer(South());}
''');
    expect(findingNames(report), isEmpty);
  });
  test('captured writes after await remain conservative', () async {
    final report = await memberFixture('''
$_types
Future<void> main() async { Port receiver=North();
void read(){receiver.run();} read();
await Future<void>.value(); receiver=South(); read(); }
''');
    expect(findingNames(report), isEmpty);
  });
  const fallbackControls = {
    'recursive reader':
        'void read(int n){receiver.run(); if(n>0) read(n-1);} '
        'read(1); receiver=South(); read(1);',
    'mutually recursive readers':
        'void a(int n){receiver.run();if(n>0)b(n-1);} '
        'void b(int n){receiver.run();if(n>0)a(n-1);} '
        'a(1);receiver=South();b(1);',
    'callback targets change across zero-trip loop':
        'void a(){North().run();} void b(){South().run();} '
        'var action=a; for(var i=0;i<args.length;i++){action=b;} action();',
    'callback target escapes through storage':
        'void read(){receiver.run();} final actions=[read]; '
        'actions.single(); receiver=South(); actions.single();',
  };
  for (final entry in fallbackControls.entries) {
    test(entry.key, () async {
      final report = await memberFixture('''
$_types
void main(List<String> args){Port receiver=North(); ${entry.value}}
''');
      expect(findingNames(report), isEmpty);
    });
  }
  test(
    'callback locals do not accumulate across enclosing iterations',
    () async {
      final report = await memberFixture('''
$_types
void main() {
  Port receiver=North();
  void write(){final next=South();void assign(){receiver=next;}assign();}
  for(var i=0;i<2;i++){write();} receiver.run();
}
''');
      expect(findingNames(report), {'North.run', 'northEffect'});
    },
  );
}
