import 'dart:io';

import 'package:git_stage_hunks_tool/git_stage_hunks_tool.dart';
import 'package:test/test.dart';

/// Twenty numbered lines, so changes can sit far enough apart to be
/// separate hunks at the default context of 3.
String _lines(
  Map<int, String> changes, {
  Set<int> drop = const {},
  Map<int, String> insertAfter = const {},
}) {
  final out = StringBuffer();
  for (var i = 1; i <= 20; i++) {
    if (!drop.contains(i)) out.writeln(changes[i] ?? 'line $i');
    if (insertAfter[i] != null) out.writeln(insertAfter[i]);
  }
  return out.toString();
}

void main() {
  for (final inSubdir in [false, true]) {
    group('stageHunks (root ${inSubdir ? 'is a subdirectory' : 'is the repo'})', () {
      late Directory repo;
      late Directory root;
      late File f;

      // The plainest possible runner: git, in [root], no policy.
      Future<GitResult> git(List<String> argv) async {
        final r = await Process.run('git', ['-C', root.path, ...argv]);
        return GitResult(
          exitCode: r.exitCode,
          stdout: r.stdout as String,
          failure: r.stderr as String,
        );
      }

      setUp(() async {
        repo = Directory.systemTemp.createTempSync('stage_hunks_repo_');
        root = inSubdir ? (Directory('${repo.path}/sub')..createSync()) : repo;
        f = File('${root.path}/f.txt')..writeAsStringSync(_lines({}));
        await _git(repo, ['init', '-q']);
        await _git(repo, ['add', '.']);
        await _git(repo, [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          'commit',
          '-qm',
          'base',
        ]);
        // Three separate changes: an insertion near the top, an edit in the
        // middle, a deletion near the end.
        f.writeAsStringSync(
          _lines(
            {10: 'line 10 CHANGED'},
            insertAfter: {2: 'INSERTED'},
            drop: {18},
          ),
        );
      });

      tearDown(() => repo.deleteSync(recursive: true));

      Future<String> run(Map<String, Object?> input) => stageHunks(git, input);
      Future<String> staged() async =>
          (await Process.run('git', [
                '-C',
                root.path,
                'diff',
                '--cached',
                '-U0',
                '--',
                'f.txt',
              ])).stdout
              as String;

      test('lists the hunks, numbered', () async {
        final out = await run({'path': 'f.txt'});
        expect(out, contains('3 unstaged hunks'));
        expect(out, contains('[1] @@'));
        expect(out, contains('[3] @@'));
        expect(out, contains('+INSERTED'));
      });

      test(
        'stages only the chosen hunk, even when an earlier one is skipped',
        () async {
          // Hunk 3 sits after the insertion in hunk 1, which is NOT staged: its
          // new-side position has to be recomputed, not copied from the diff.
          final out = await run({
            'path': 'f.txt',
            'hunks': [3],
          });
          expect(out, contains('staged hunk 3'));
          final s = await staged();
          expect(s, contains('-line 18'));
          expect(s, isNot(contains('INSERTED')));
          expect(s, isNot(contains('CHANGED')));
          // The rest is still unstaged.
          expect(await run({'path': 'f.txt'}), contains('2 unstaged hunks'));
        },
      );

      test('stages a non-contiguous pair', () async {
        await run({
          'path': 'f.txt',
          'hunks': [1, 3],
        });
        final s = await staged();
        expect(s, contains('+INSERTED'));
        expect(s, contains('-line 18'));
        expect(s, isNot(contains('CHANGED')));
      });

      test('context 0 splits adjacent changes git would join', () async {
        // Two edits two lines apart: one hunk at context 3, two at context 0.
        f.writeAsStringSync(_lines({5: 'five X', 7: 'seven X'}));
        expect(await run({'path': 'f.txt'}), contains('1 unstaged hunk'));
        expect(
          await run({'path': 'f.txt', 'context': 0}),
          contains('2 unstaged hunks'),
        );
        await run({
          'path': 'f.txt',
          'context': 0,
          'hunks': [2],
        });
        final s = await staged();
        expect(s, contains('+seven X'));
        expect(s, isNot(contains('five X')));
      });

      test(
        'refuses a hunk number that does not exist, and stages nothing',
        () async {
          expect(
            await run({
              'path': 'f.txt',
              'hunks': [4],
            }),
            contains('refused'),
          );
          expect(await staged(), isEmpty);
        },
      );

      test('refuses a path outside the tree', () async {
        expect(await run({'path': '../x'}), contains('refused'));
      });

      test('a clean file says so', () async {
        await _git(repo, ['checkout', '--', '.']);
        expect(await run({'path': 'f.txt'}), contains('no unstaged changes'));
      });
    });
  }

  group('partialPatch arithmetic', () {
    FileDiff d(List<(int, int, int, int)> hs) => FileDiff(
      const ['--- a/f', '+++ b/f'],
      [
        for (final (os, oc, ns, nc) in hs)
          Hunk(
            oldStart: os,
            oldCount: oc,
            newStart: ns,
            newCount: nc,
            section: '',
            lines: const [],
          ),
      ],
    );

    test('a later hunk is shifted only by the chosen hunks before it', () {
      // Hunk 1 adds 2 lines; hunk 2 removes 1; hunk 3 is a plain edit.
      final diff = d([(3, 2, 3, 4), (10, 2, 12, 1), (15, 1, 16, 1)]);
      expect(partialPatch(diff, [3]), contains('@@ -15,1 +15,1 @@'));
      expect(partialPatch(diff, [1, 3]), contains('@@ -15,1 +17,1 @@'));
      expect(partialPatch(diff, [2, 3]), contains('@@ -15,1 +14,1 @@'));
    });

    test('zero-context insertion and deletion follow git -U0 positions', () {
      final diff = d([(4, 0, 5, 2), (9, 2, 10, 0)]);
      expect(partialPatch(diff, [1]), contains('@@ -4,0 +5,2 @@'));
      expect(partialPatch(diff, [2]), contains('@@ -9,2 +8,0 @@'));
      expect(partialPatch(diff, [1, 2]), contains('@@ -9,2 +10,0 @@'));
    });
  });
}

Future<void> _git(Directory repo, List<String> args) async {
  final r = await Process.run('git', ['-C', repo.path, ...args]);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}
