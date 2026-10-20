/// The tool: list a file's unstaged hunks, or stage some of them.
///
/// It knows nothing about any agent framework or process runner. Hand it a
/// [GitRunner] and a decoded-JSON input map; it returns the text to show the
/// model. Wire [stageHunksName], [stageHunksDescription] and
/// [stageHunksInputSchema] into whatever tool registry you have.
library;

import 'dart:io';

import 'hunks.dart';

/// What a [GitRunner] reports back.
class GitResult {
  final int exitCode;
  final String stdout;

  /// What to show the model when [exitCode] is not 0 (usually stderr, or the
  /// reason a command was refused).
  final String failure;

  const GitResult({
    required this.exitCode,
    required this.stdout,
    this.failure = '',
  });
}

/// Runs `git` with these arguments, in the repository the tool works on.
///
/// This is the one seam. A runner is where consent, containment and timeouts
/// belong, so the tool never starts a process itself.
typedef GitRunner = Future<GitResult> Function(List<String> argv);

const stageHunksName = 'git_stage_hunks';

const stageHunksDescription =
    'Stage PART of one file, like `git add -p`. With only '
    '`path`: lists its unstaged hunks, numbered. With `hunks`: stages '
    'exactly those numbers, from a listing with the same `context`. '
    'Numbering changes after staging -- list again before the next call.';

const stageHunksInputSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description': 'One file, relative to the root.',
    },
    'hunks': {
      'type': 'array',
      'items': {'type': 'integer'},
      'description': 'Hunk numbers to stage. Omit to list.',
    },
    'context': {
      'type': 'integer',
      'description':
          'Lines of context, 0-3 (default 3). 0 splits '
          'changes into the most, smallest hunks.',
    },
  },
  'required': ['path'],
};

/// Lists a file's unstaged hunks, or stages some of them. Both git calls go
/// through [git]. It only builds the patch so nothing has to be typed by hand.
Future<String> stageHunks(GitRunner git, Map<String, Object?> input) async {
  final path = input['path']?.toString() ?? '';
  final outside = rootRelativeRefusal(path);
  if (outside != null) return 'refused: $outside';
  final context = (input['context'] as num?)?.toInt() ?? 3;
  if (context < 0 || context > 3) return 'refused: context must be 0-3';

  final diff = await git([
    'diff',
    '--no-color',
    '--no-ext-diff',
    '-U$context',
    '--',
    path,
  ]);
  if (diff.exitCode != 0) return diff.failure;
  final FileDiff parsed;
  try {
    parsed = parseFileDiff(diff.stdout);
  } on FormatException catch (e) {
    return '$path: ${e.message}';
  }

  final raw = input['hunks'];
  if (raw == null) return listHunks(path, parsed);
  if (raw is! List || raw.isEmpty) {
    return 'refused: hunks must be a non-empty list of numbers';
  }
  final chosen = [for (final h in raw) (h as num).toInt()];
  final String patch;
  try {
    patch = partialPatch(parsed, chosen);
  } on RangeError {
    return 'refused: $path has hunks 1-${parsed.hunks.length}; got $chosen';
  }

  // The patch goes through a file: a runner takes argv, not stdin.
  final dir = Directory.systemTemp.createTempSync('stage_hunks');
  try {
    final file = File('${dir.path}/hunks.patch')..writeAsStringSync(patch);
    final applied = await git([
      'apply',
      '--cached',
      if (context == 0) '--unidiff-zero',
      file.path,
    ]);
    if (applied.exitCode != 0) return applied.failure;
  } finally {
    dir.deleteSync(recursive: true);
  }
  final left = parsed.hunks.length - chosen.toSet().length;
  return 'staged ${chosen.length == 1 ? 'hunk' : 'hunks'} ${(chosen.toSet().toList()..sort()).join(', ')} '
      'of $path; $left unstaged ${left == 1 ? 'hunk remains' : 'hunks remain'} '
      '(list again: the numbers have changed)';
}

/// Why [path] cannot be a root-relative git pathspec, or null if it can.
String? rootRelativeRefusal(String path) {
  if (path.isEmpty) return 'path is empty; omit it to diff the whole tree';
  if (path.startsWith(':')) {
    return '$path is pathspec magic (`:`), which can reach outside the tree';
  }
  if (path.startsWith('/') || path.split('/').contains('..')) {
    return '$path is outside the working tree';
  }
  return null;
}
