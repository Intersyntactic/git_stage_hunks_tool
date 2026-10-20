/// Staging PART of a file -- what `git add -p` does, without the prompt.
///
/// `git add -p` is interactive, and an agent has no terminal to answer it.
/// The same effect is a patch: take the file's `git diff`, keep the hunks
/// that were chosen, and `git apply --cached` the result. This file is the
/// pure half -- parse a diff into numbered hunks, and assemble a patch from
/// a subset -- so the arithmetic is testable without git.
///
/// THE ARITHMETIC THAT MATTERS. A patch applies to the INDEX, which has none
/// of the unchosen hunks. Each hunk's OLD position is therefore unchanged, but
/// its NEW position must be recomputed from the chosen hunks before it only;
/// carrying git's original `+start` over describes a file that will not exist.
library;

/// One `@@ ... @@` section of a single file's diff.
class Hunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;

  /// Whatever followed the second `@@` (git's function-context hint).
  final String section;

  /// The body: ` `, `-`, `+` and `\ No newline at end of file` lines.
  final List<String> lines;

  const Hunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.section,
    required this.lines,
  });

  String get header =>
      '@@ -$oldStart,$oldCount +$newStart,$newCount @@$section';
}

/// One file's diff: the `diff --git` .. `+++` preamble, then its hunks.
class FileDiff {
  final List<String> preamble;
  final List<Hunk> hunks;
  const FileDiff(this.preamble, this.hunks);
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$');

/// Parses the output of `git diff -- <one file>`. Throws [FormatException]
/// when it is not exactly one file's text diff -- a directory, a binary file,
/// or nothing at all -- because a hunk number is only meaningful within one.
FileDiff parseFileDiff(String diff) {
  final lines = diff.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final files = lines.where((l) => l.startsWith('diff --git ')).length;
  if (files == 0) throw const FormatException('no unstaged changes');
  if (files > 1) {
    throw FormatException(
      'the path covers $files changed files; give one file',
    );
  }
  final preamble = <String>[];
  final hunks = <Hunk>[];
  List<String>? body;
  Match? head;
  void close() {
    if (head == null) return;
    hunks.add(
      Hunk(
        oldStart: int.parse(head[1]!),
        oldCount: int.parse(head[2] ?? '1'),
        newStart: int.parse(head[3]!),
        newCount: int.parse(head[4] ?? '1'),
        section: head[5]!,
        lines: body!,
      ),
    );
  }

  for (final l in lines) {
    final m = _hunkHeader.firstMatch(l);
    if (m != null) {
      close();
      head = m;
      body = [];
    } else if (head == null) {
      preamble.add(l);
    } else {
      body!.add(l);
    }
  }
  close();
  if (hunks.isEmpty) {
    throw FormatException(
      preamble.any((l) => l.startsWith('Binary files'))
          ? 'a binary file has no hunks; stage it whole with git add'
          : 'no hunks (a mode change or rename only?); stage it whole with git add',
    );
  }
  return FileDiff(preamble, hunks);
}

/// The diff, numbered from 1, for choosing from.
String listHunks(String path, FileDiff d) {
  final out = StringBuffer(
    '$path: ${d.hunks.length} unstaged '
    '${d.hunks.length == 1 ? 'hunk' : 'hunks'}\n',
  );
  for (var i = 0; i < d.hunks.length; i++) {
    final h = d.hunks[i];
    out
      ..writeln()
      ..writeln('[${i + 1}] ${h.header}');
    for (final l in h.lines) {
      out.writeln(l);
    }
  }
  return out.toString();
}

/// A patch of exactly the [chosen] hunks (1-based), positioned to apply to
/// the index. Throws [RangeError] for a number that is not a hunk.
String partialPatch(FileDiff d, Iterable<int> chosen) {
  final picked = chosen.toSet().toList()..sort();
  if (picked.isEmpty) throw ArgumentError('no hunks chosen');
  for (final n in picked) {
    RangeError.checkValueInInterval(n, 1, d.hunks.length, 'hunk');
  }
  final out = StringBuffer();
  for (final l in d.preamble) {
    out.writeln(l);
  }
  var offset = 0; // lines added minus removed, by the chosen hunks so far
  for (final n in picked) {
    final h = d.hunks[n - 1];
    // A hunk that removes nothing (`-a,0`) inserts AFTER line a; one that
    // adds nothing names the line before the gap. git's own -U0 convention.
    var newStart = (h.oldCount == 0 ? h.oldStart + 1 : h.oldStart) + offset;
    if (h.newCount == 0) newStart -= 1;
    final moved = Hunk(
      oldStart: h.oldStart,
      oldCount: h.oldCount,
      newStart: newStart,
      newCount: h.newCount,
      section: h.section,
      lines: h.lines,
    );
    out.writeln(moved.header);
    for (final l in h.lines) {
      out.writeln(l);
    }
    offset += h.newCount - h.oldCount;
  }
  return out.toString();
}
