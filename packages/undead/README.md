Deterministic reachability and dead/unused declaration analysis for Dart and
Flutter packages.

`undead` performs whole-package AST analysis using `package:analyzer` to build a
reachability graph from known entrypoints to all internal declarations,
identifying unused top-level declarations, classes, functions, and variables.

## ✨ Features

- **Dual Analysis Modes**:
  - **Open-World** (Default): Treats all non-`src` `lib/**` exports as public
    API roots. Ideal for reusable libraries and packages.
  - **Closed-App** (`--mode=closed-app`): Traces execution strictly from
    executable entrypoints (`bin/**`, `lib/main.dart`, `lib/main_*.dart`).
- **Framework Adapters**:
  - **Flutter**: Discovers entrypoints, widget main targets, and
    `@pragma('vm:entry-point')` annotations.
  - **Build Runner**: Harvests builder factories and generator entrypoints from
    `build.yaml`.
  - **Package Test**: Identifies test suites and test runner entrypoints.
  - **JS Interop**: Preserves external JS interop bindings (`@JS()`).
- **Co-Invoked Test Hazard Protection**:
  - Distinguishes isolated dead tests from tests that co-invoke both live and
    dead code, preventing false-positive test deletions.
- **Sealed Hierarchy Awareness**:
  - Preserves subtypes of live `sealed` classes to maintain Dart 3 pattern match
    exhaustiveness.
- **Granular Suppressions**:
  - Supports `// undead:ignore` (declaration-level) and
    `// undead:ignore_for_file` (file-level) directives.

## ⚡ Quick Start

### CLI

Run the analyzer directly in any Dart or Flutter project:

```bash
dart run undead@
```

Analyze a closed standalone application:

```bash
dart run undead@ --mode=closed-app
```

Output results as JSON or Markdown:

```bash
dart run undead@ --format=json
dart run undead@ --format=markdown
```

### Member body analysis (development)

The opt-in `--member-level` mode separates ordinary method bodies from their
owner classes. For example, calling `Live.run` no longer keeps dependencies
referenced only by `Live.unusedMethod` alive. Run the development source from
this repository:

```bash
dart run packages/undead/bin/undead.dart --mode=closed-app --member-level --example-mode=skip --format=json /path/to/app
```

The API equivalent is
`UndeadOptions(memberLevel: true, mode: AnalysisMode.closedApp, packagePath: ...)`.
The option requires closed-app mode and cannot be combined with
`suggestPrivate`. Defaults and library analysis retain their existing behavior.

Member reports use qualified names and file-qualified IDs, `kind: "method"`,
`memberLevel: true`, and `suggestedAction: "review"`. A
`hasInheritedContract: true` finding may need its declaration/signature to
satisfy a live interface; an unreachable body is not permission to delete the
method. Constructors, fields and accessors participate in reachability but do
not receive member removal findings. Whole-owner findings suppress redundant
child findings.

Member reports also include `uncertainCandidates`: declarations kept alive only
by conservative assumptions, together with their exclusive dependencies. Each
has classification `uncertain`, action `review`, and `retentionReasons` such as
`externalProtocol`, `externalEscape`, `implicitJsonProtocol` or
`unresolvedReceiver`. These may be live at runtime. They appear separately in
Markdown and JSON and do not contribute to ordinary undead counts or
`--fail-on-undead`. An independently modeled live path removes a declaration
from this list.

Production and tests have independent receiver allocations and dispatch.
Test-only findings include transitive test witnesses; a test that also executes
a production callable is a co-invocation hazard. Merely constructing a live
owner does not create that hazard. Tests are never recommended for automatic
removal in member mode.

This is a conservative static model, not complete runtime analysis:

- Reachable callbacks/tear-offs and eager constructor initialization are
  retained. Receiver dispatch follows compatible allocated types, including
  inheritance, mixins and interfaces. Generic identity comes from the resolved
  declaration. Named local function bodies are traversed only when their
  function is reached, including calls and escaped tear-offs.
- Bounded receiver origins follow local assignments, actual arguments and simple
  returned values. Only reached callers contribute, and tests cannot widen
  production receivers. Origins are unioned across branches and calls; this is
  not a flow-sensitive or context-sensitive analysis. Unknown values, omitted
  argument defaults and heap/global storage use conservative fallback.
- Overrides of external protocols on allocated receivers are retained. This
  covers Flutter lifecycle hooks such as `createState`, `initState`, `build`,
  and `dispose`, but can retain overrides that the runtime never invokes.
- Unknown selectors retain matching members on allocated receivers. Objects
  exposed to arbitrary foreign code retain their public surface; SDK/Flutter
  protocol hooks and supplied callbacks are modeled separately.
- Property reads can retain method tear-offs; invocations can retain callable
  getters/fields and the `call` method of objects they return.
- Reachable SDK JSON codec/encoder references retain `toJson` on allocated
  receivers, including objects nested in containers or produced by another
  conversion. `implicitJsonProtocol` discloses this conservative approximation:
  explicit converters, decode-only codec use and unrelated allocated receivers
  can retain unused `toJson` methods. Encoder configuration and container value
  flow are not tracked precisely.
- Resolvable excluded/generated local files are read for dependency transit but
  do not produce findings. They do not become new entrypoints merely through
  transit. Files that the analyzer cannot resolve are reported as coverage
  limitations.
- `coverageLimitations` records resolution errors and conservative boundaries.
  Markdown groups these diagnostics; JSON includes each source location.
  Configure actual runtime roots with adapters, pragmas and `--extra-roots`.
  Reflection, arbitrary runtime registries and full points-to analysis are not
  supported. Missing or unresolved input requires additional review.

The portable real-Flutter check requires an installed Flutter SDK and fails if
it is unavailable:

```bash
dart run packages/undead/tool/verify_member_flutter.dart
```

See [the architecture](doc/approach.md#member-body-reachability) for the graph
invariants and [the Phase 2 taxonomy](doc/taxonomy_phase2.md) for deferred work.

### CLI Options

<!-- CLI_README_START -->

```console
$ undead --help
undead - Reachability and dead declaration analysis for Dart packages.

Usage: undead [options] [target_path]

-f, --format                               Output formatting mode for stdout (json for agents/CI, markdown for humans).
                                           [markdown (default), json, github]
    --json-output=<path/to/report.json>    Write machine-readable JSON analysis report to the specified file (recommended for agents and CI pipelines alongside human stdout).
    --example-mode                         How code in example/ is treated during reachability analysis.
                                           [demonstration (default), strict, skip]
-m, --mode                                 Package analysis mode.
                                           [library (default), closed-app]
    --[no-]member-level                    Review ordinary method bodies separately (requires --mode=closed-app).
    --exclude=<glob>                       Glob patterns of files/directories to exclude (repeatable or comma-separated).
    --[no-]ignore-generated                Exclude generated files (*.g.dart, *.freezed.dart, *.mocks.dart, etc.).
                                           (defaults to on)
    --[no-]fail-on-undead                  Exit with non-zero code (1) if any undead declaration is detected.
    --test-support-patterns                Comma-separated naming wildcard patterns for test fixtures and hooks.
                                           (defaults to "Fake*,Mock*")
    --ignore-name-patterns                 Comma-separated naming wildcard patterns for declaration names to ignore.
                                           (defaults to "")
    --extra-roots=<dir1,dir2>              Comma-separated list of additional root/test directories or companion packages to include in reachability analysis.
                                           (defaults to "")
    --[no-]ignore-external-bindings        Ignore unreferenced external platform and FFI/interop facade declarations.
    --[no-]workspace-discovery             Automatically discover and ingest consumer roots from sibling packages in the enclosing workspace.
                                           (defaults to on)
    --[no-]suggest-private                 Detect and suggest making internal lib/src declarations private if only used within their declaring library.
    --sdk-path                             Path to the Dart SDK root (overrides auto-discovery).
    --pub-get                              Automatically run "dart pub get" (or "flutter pub get") if dependencies are unresolved.
-h, --help                                 Print usage information.
    --version                              Print undead version.
```

<!-- CLI_README_END -->

### Library API

```dart
import 'package:undead/undead.dart';

void main() async {
  final options = UndeadOptions(
    packagePath: '.',
    mode: AnalysisMode.library,
  );
  final engine = UndeadEngine(options);
  final report = await engine.analyze();

  for (final finding in report.undead) {
    print('Unused: ${finding.name} (${finding.file}:L${finding.line})');
  }
}
```

## 🧠 AI Agent Integration

This repository packages an agent skill (`dart-undead`) to train AI pair
programmers on dead code audits, reachability analysis, and safe deletion
protocols:

Install using either the dart skills CLI:

```bash
dart run skills@ add kevmoo/analytica.dart --skill dart-undead
```

Or npx skills:

```bash
npx skills add kevmoo/analytica.dart --skill dart-undead
```
