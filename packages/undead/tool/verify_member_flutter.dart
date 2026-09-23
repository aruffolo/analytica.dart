import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Runs the real Flutter fixture; missing Flutter is a failure, never a skip.
Future<void> main() async {
  final package = File.fromUri(Platform.script).parent.parent.path;
  final config = (await Isolate.packageConfig)!;
  final fixture = Directory(
    p.join(package, 'test', 'fixtures', 'member_flutter'),
  );
  final temporary = Directory.systemTemp.createTempSync('undead-flutter-');
  try {
    for (final source in fixture.listSync(recursive: true).whereType<File>()) {
      final relative = p.relative(source.path, from: fixture.path);
      if (!relative.endsWith('.txt')) continue;
      final target = File(
        p.join(temporary.path, relative.substring(0, relative.length - 4)),
      );
      target.parent.createSync(recursive: true);
      source.copySync(target.path);
    }
    await _run('flutter', ['pub', 'get'], temporary.path);
    await _run('dart', ['analyze', '--fatal-infos'], temporary.path);
    await _run('flutter', ['test'], temporary.path);
    final reports = <bool, Map<String, dynamic>>{};
    for (final enabled in [false, true]) {
      final output = await _run(
        Platform.resolvedExecutable,
        [
          '--packages=${config.toFilePath()}',
          p.join(package, 'bin', 'undead.dart'),
          '--mode=closed-app',
          '--example-mode=skip',
          '--no-workspace-discovery',
          '--format=json',
          if (enabled) '--member-level',
          temporary.path,
        ],
        package,
        printOutput: false,
      );
      reports[enabled] = jsonDecode(output) as Map<String, dynamic>;
    }
    final findings = (reports[true]!['undead'] as List)
        .cast<Map<String, dynamic>>();
    final names = findings.map((f) => f['name'] as String).toSet();
    const expected = {
      'ScreenState.unusedMember',
      'hiddenDependency',
      'DeadScreen',
      'deadBuildDependency',
    };
    if (names.length != expected.length || !names.containsAll(expected)) {
      throw StateError(
        'Unexpected member findings: $names; expected $expected',
      );
    }
    final coarse = (reports[false]!['undead'] as List)
        .cast<Map<String, dynamic>>();
    if (coarse.any((f) => f['name'] == 'hiddenDependency')) {
      throw StateError('Default graph unexpectedly changed.');
    }
    final limitations =
        (reports[true]!['coverageLimitations'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
    if (limitations.any(
      (l) => l['code'] == 'resolutionError' || l['code'] == 'unresolvedUnit',
    )) {
      throw StateError('Flutter source failed resolution: $limitations');
    }
    stdout.writeln(
      'PASS: lifecycle, mixin and callback dependencies preserved; '
      '$names detected.',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

Future<String> _run(
  String command,
  List<String> arguments,
  String cwd, {
  bool printOutput = true,
}) async {
  final result = await Process.run(command, arguments, workingDirectory: cwd);
  if (printOutput) stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw ProcessException(
      command,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
