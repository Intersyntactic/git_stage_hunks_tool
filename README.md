# git_stage_hunks_tool

The `git_stage_hunks` tool, as a package.

`git add -p` for agents. `git add -p` asks questions, and an agent has no
terminal to answer them. This package does the same job with two plain calls:

1. `{"path": "lib/a.dart"}` lists the file's unstaged hunks, numbered.
2. `{"path": "lib/a.dart", "hunks": [1, 3]}` stages exactly those.

It takes the file's `git diff`, keeps the chosen hunks, recomputes their
new-side line numbers (the index lacks the unchosen hunks, so git's original
`+start` would describe a file that will not exist) and runs
`git apply --cached`.

## Use

```dart
import 'package:git_stage_hunks_tool/git_stage_hunks_tool.dart';

// The one seam: how git gets run. Put consent, containment and timeouts here.
Future<GitResult> git(List<String> argv) async {
  final r = await Process.run('git', ['-C', repoRoot, ...argv]);
  return GitResult(
    exitCode: r.exitCode,
    stdout: r.stdout as String,
    failure: r.stderr as String,
  );
}

final reply = await stageHunks(git, {'path': 'lib/a.dart'});
```

Register the tool with `stageHunksName`, `stageHunksDescription` and
`stageHunksInputSchema`. The package depends on no agent framework and starts
no process of its own.

The pure half (`parseFileDiff`, `listHunks`, `partialPatch`) is exported too,
and testable without git.

## License

Apache-2.0. See [LICENSE](LICENSE).
