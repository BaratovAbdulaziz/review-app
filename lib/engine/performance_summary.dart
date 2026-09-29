import 'game_analyzer.dart';
import 'move_tags.dart';

/// A plain-language read on how the game went, for the side being reviewed.
///
/// This is written for the person who played, not for an engine: it avoids
/// centipawns and depth numbers and talks about what actually happened.
class PerformanceSummary {
  const PerformanceSummary({
    required this.headline,
    required this.overview,
    required this.points,
    required this.best,
    required this.good,
    required this.inaccuracies,
    required this.mistakes,
    required this.blunders,
    required this.accuracy,
    required this.averageCpl,
  });

  /// A short verdict, e.g. `A clean game`.
  final String headline;

  /// One or two sentences tying the game together.
  final String overview;

  /// The specific things worth knowing, most useful first.
  final List<String> points;

  final int best;
  final int good;
  final int inaccuracies;
  final int mistakes;
  final int blunders;

  /// The share of scored moves that were the engine's choice, from 0 to 1.
  final double accuracy;

  /// Average centipawn loss over the moves that count.
  final double averageCpl;
}

/// Reads the game as the reviewer played it.
///
/// Only the reviewer's own moves are counted: an honest review of your game
/// should not tell you what your opponent did.
PerformanceSummary summarise(
  GameAnalysis analysis, {
  required bool isReviewerWhite,
}) {
  final mine = analysis.moves
      .where((move) => move.isWhite == isReviewerWhite)
      .toList(growable: false);
  final scored = mine.where((move) => move.countsTowardAverage).toList();

  final best = _count(mine, MoveVerdict.best);
  final good = _count(mine, MoveVerdict.good);
  final inaccuracies = _count(mine, MoveVerdict.inaccuracy);
  final mistakes = _count(mine, MoveVerdict.mistake);
  final blunders = _count(mine, MoveVerdict.blunder);

  final accuracy = scored.isEmpty
      ? 0.0
      : scored
                .where(
                  (move) =>
                      move.verdict == MoveVerdict.best ||
                      move.verdict == MoveVerdict.good,
                )
                .length /
            scored.length;

  // Material, and the pieces left to be taken, come from the board rather than
  // from the evaluation, so a won pawn is never counted as a good move.
  var won = 0;
  var lost = 0;
  var freeTaken = 0;
  var freeLeft = 0;
  AnalyzedMove? worst;
  for (final move in mine) {
    // The opponent's reply is the next ply in the game, which exists for the
    // reviewer's last move too when the game did not end on it, so this asks the
    // game rather than the reviewer's own move list.
    final reply = _replyOf(analysis, move);
    won += materialWonBy(move);
    lost += materialLostTo(move, reply);
    for (final note in notesFor(move, who: 'you', next: reply)) {
      if (note.kind == MoveNoteKind.freePieceTaken ||
          note.kind == MoveNoteKind.freePawnTaken) {
        freeTaken++;
      }
      if (note.kind == MoveNoteKind.freePieceMissed ||
          note.kind == MoveNoteKind.freePawnMissed) {
        freeLeft++;
      }
    }
    if (!move.countsTowardAverage) continue;
    if (worst == null || move.cpl > worst.cpl) worst = move;
  }

  final averageCpl = scored.isEmpty
      ? 0.0
      : scored.fold<int>(0, (sum, move) => sum + move.cpl) / scored.length;

  return PerformanceSummary(
    headline: _headline(accuracy, scored.length),
    overview: _overview(
      accuracy: accuracy,
      scored: scored.length,
      mistakes: mistakes,
      blunders: blunders,
    ),
    points: _points(
      mine: mine,
      best: best,
      scored: scored,
      won: won,
      lost: lost,
      freeTaken: freeTaken,
      freeLeft: freeLeft,
      worst: worst,
    ),
    best: best,
    good: good,
    inaccuracies: inaccuracies,
    mistakes: mistakes,
    blunders: blunders,
    accuracy: accuracy,
    averageCpl: averageCpl,
  );
}

/// The move that answered [move], which is the next entry in the game.
AnalyzedMove? _replyOf(GameAnalysis analysis, AnalyzedMove move) {
  final index = analysis.moves.indexWhere((other) => other.ply == move.ply);
  if (index < 0 || index + 1 >= analysis.moves.length) return null;
  return analysis.moves[index + 1];
}

int _count(List<AnalyzedMove> moves, MoveVerdict verdict) =>
    moves.where((move) => move.verdict == verdict).length;

String _headline(double accuracy, int scored) {
  if (scored == 0) return 'Not much to score';
  if (accuracy >= 0.95) return 'You played the game you saw';
  if (accuracy >= 0.85) return 'A clean game';
  if (accuracy >= 0.7) return 'Solid, with a few slips';
  if (accuracy >= 0.55) return 'Uneven, but the ideas were there';
  return 'A rough one, with plenty to build on';
}

String _overview({
  required double accuracy,
  required int scored,
  required int mistakes,
  required int blunders,
}) {
  if (scored == 0) {
    return 'The opening book covered almost the whole game, so there is very '
        'little here to judge.';
  }
  final percent = (accuracy * 100).round();
  if (blunders == 0 && mistakes == 0) {
    return 'You found the best move in $percent percent of positions. Nothing '
        'in this game was really lost.';
  }
  final worst = mistakes + blunders;
  return 'You found the best move in $percent percent of positions, and the '
      '$worst moments where the game really turned were '
      '${blunders == 0 ? 'mistakes' : 'mistakes and blunders'}.';
}

List<String> _points({
  required List<AnalyzedMove> mine,
  required int best,
  required List<AnalyzedMove> scored,
  required int won,
  required int lost,
  required int freeTaken,
  required int freeLeft,
  required AnalyzedMove? worst,
}) {
  final points = <String>[];

  if (scored.isNotEmpty) {
    points.add(
      'You played the engine\'s move $best times out of ${scored.length}.',
    );
  }

  if (won > 0 || lost > 0) {
    points.add(
      'You won $won and gave up $lost on the board, so the material ended '
      '${_balance(won, lost)}.',
    );
  }

  if (freeTaken > 0 || freeLeft > 0) {
    final parts = <String>[
      if (freeTaken > 0)
        'took $freeTaken ${_plural(freeTaken, 'piece')} that '
            '${freeTaken == 1 ? 'was' : 'were'} there to take',
      if (freeLeft > 0)
        'left $freeLeft ${_plural(freeLeft, 'piece')} on the '
            'board',
    ];
    points.add('Against that, you ${parts.join(' and you ')}.');
  }

  final castled = mine.where((move) => move.san.startsWith('O-O')).firstOrNull;
  if (castled != null) {
    points.add('You got the king safe on move ${castled.moveNumber}.');
  } else if (mine.any(
    (move) => move.moveNumber > 12 && move.san.startsWith('K'),
  )) {
    points.add(
      'The king was still out in the middle late in the game, which is a risk '
      'you did not have to take.',
    );
  }

  if (worst != null && worst.cpl >= 100) {
    points.add(
      'The expensive moment was move ${worst.moveNumber}, ${worst.san}.',
    );
  }

  if (points.isEmpty) {
    points.add('Nothing stood out in this game, which is its own result.');
  }
  return points;
}

String _balance(int won, int lost) {
  if (won > lost) return '${_plural(won - lost, 'pawn')} up';
  if (lost > won) return '${_plural(lost - won, 'pawn')} down';
  return 'level';
}

String _plural(int count, String word) =>
    '$count $word${count == 1 ? '' : 's'}';
