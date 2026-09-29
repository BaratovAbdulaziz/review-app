import 'pgn_parser.dart';
import 'stockfish_engine.dart';

enum MoveVerdict {
  book,

  /// The mover was already lost by [alreadyLostCp] before the move, so the size
  /// of the loss says more about the game than about the move.
  wasLost,

  /// The engine saw a forced result for this move, so a centipawn loss against
  /// a mate score would be meaningless.
  decisive,
  best,
  good,
  inaccuracy,
  mistake,
  blunder,
}

extension MoveVerdictLabel on MoveVerdict {
  String get label => switch (this) {
    MoveVerdict.book => 'Book',
    MoveVerdict.wasLost => 'Already lost',
    MoveVerdict.decisive => 'Decisive',
    MoveVerdict.best => 'Best',
    MoveVerdict.good => 'Good',
    MoveVerdict.inaccuracy => 'Inaccuracy',
    MoveVerdict.mistake => 'Mistake',
    MoveVerdict.blunder => 'Blunder',
  };

  /// A short mark for the verdict, so a move can be read at a glance: a star for
  /// the moves worth copying, a tick for a good one, then the usual chess
  /// notation counting up to a cross for the ones that cost material.
  /// Book moves and moves from an already lost position are not the mover's
  /// doing, so they get no mark at all.
  String get symbol => switch (this) {
    MoveVerdict.book => '',
    MoveVerdict.wasLost => '',
    MoveVerdict.decisive => '★',
    MoveVerdict.best => '★',
    MoveVerdict.good => '✓',
    MoveVerdict.inaccuracy => '!',
    MoveVerdict.mistake => '!!',
    MoveVerdict.blunder => '✗',
  };
}

/// Folds an engine score into one signed number from the side to move's view.
int sideToMoveScore({required int? scoreCp, required int? mateIn}) {
  if (mateIn != null) {
    return (mateIn > 0 ? 1 : -1) * (10000 - mateIn.abs() * 20);
  }
  return scoreCp ?? 0;
}

/// A mover who is already this far down was never going to hold the position,
/// so grading the move would only measure how the game was lost.
const int alreadyLostCp = -300;

/// Clamps a mate-in score into a range an eval bar can display.
int clampEval(int value) => value.clamp(-1500, 1500).toInt();

/// Converts a side-to-move score to White's point of view.
int toWhitePov(int sideToMoveScore, {required bool whiteToMove}) =>
    whiteToMove ? sideToMoveScore : -sideToMoveScore;

/// Centipawns lost by the player who made the move.
///
/// Both scores are from the mover's point of view and come from the same
/// search, so the difference is directly comparable.
int centipawnLoss({required int bestScore, required int playedScore}) {
  final loss = bestScore - playedScore;
  return loss >= 0 ? loss : 0;
}

MoveVerdict verdictFor({required int cpl, required bool inBook}) {
  if (inBook) return MoveVerdict.book;
  if (cpl <= 10) return MoveVerdict.best;
  if (cpl <= 30) return MoveVerdict.good;
  if (cpl <= 60) return MoveVerdict.inaccuracy;
  if (cpl <= 120) return MoveVerdict.mistake;
  return MoveVerdict.blunder;
}

class AnalyzedMove {
  const AnalyzedMove({
    required this.ply,
    required this.san,
    required this.isWhite,
    required this.uci,
    required this.evalBefore,
    required this.evalAfter,
    required this.cpl,
    required this.verdict,
    required this.bestMoveSan,
    required this.bestMoveUci,
    required this.pv,
    required this.depth,
    required this.reachedDepth,
  });

  final Ply ply;
  final String san;
  final bool isWhite;
  final String uci;

  /// Best-play evaluation before the move, White's point of view.
  final int evalBefore;

  /// Best-play evaluation after the move, White's point of view.
  final int evalAfter;

  final int cpl;
  final MoveVerdict verdict;

  /// The engine's preferred move, in SAN.
  final String bestMoveSan;

  /// The engine's preferred move, in engine notation.
  final String bestMoveUci;

  final String pv;

  /// Depth that was asked for.
  final int depth;

  /// Depth the engine reported reaching.
  final int reachedDepth;

  /// True when the time limit stopped the search before the requested depth,
  /// so this move's numbers come from a shallower search than its neighbours.
  bool get truncated => reachedDepth < depth;

  int get moveNumber => ply.moveNumber;
  bool get isBestMove => bestMoveUci == uci;

  /// "White" or "Black", the side this move belongs to.
  String get moverName => isWhite ? 'White' : 'Black';

  /// Where the move fits, e.g. "22. Nf6".
  String get positionLabel => '$moveNumber${isWhite ? '.' : '..'} $san';

  /// [evalBefore] from the mover's point of view, so a sentence about the move
  /// does not have to change sign halfway.
  int get moverEvalBefore => isWhite ? evalBefore : -evalBefore;

  /// [evalAfter] from the mover's point of view.
  int get moverEvalAfter => isWhite ? evalAfter : -evalAfter;

  /// Whether the move counts towards the average centipawn loss.
  bool get countsTowardAverage =>
      verdict != MoveVerdict.book &&
      verdict != MoveVerdict.wasLost &&
      verdict != MoveVerdict.decisive;
}

class GameAnalysis {
  const GameAnalysis({
    required this.ladder,
    required this.moves,
    required this.depth,
    required this.finalEval,
  });

  final GameLadder ladder;
  final List<AnalyzedMove> moves;
  final int depth;

  /// White's best-play evaluation of the final position.
  final int finalEval;

  int get plies => moves.length;

  /// Plies whose search was cut short by the time limit.
  int get truncatedPlies => moves.where((move) => move.truncated).length;

  List<AnalyzedMove> get mistakes => moves
      .where(
        (move) =>
            move.verdict == MoveVerdict.mistake ||
            move.verdict == MoveVerdict.blunder,
      )
      .toList(growable: false);

  /// Average centipawn loss per side, ignoring the opening book and the moves
  /// played from an already lost position.
  double averageCplWhite() => _averageCpl(moves.where((move) => move.isWhite));

  double averageCplBlack() => _averageCpl(moves.where((move) => !move.isWhite));

  int countVerdict(MoveVerdict verdict, {required bool isWhite}) => moves
      .where((move) => move.isWhite == isWhite && move.verdict == verdict)
      .length;

  static double _averageCpl(Iterable<AnalyzedMove> moves) {
    final scored = moves
        .where((move) => move.countsTowardAverage)
        .toList(growable: false);
    if (scored.isEmpty) return 0;
    final total = scored.fold<int>(0, (sum, move) => sum + move.cpl);
    return total / scored.length;
  }
}

/// Runs [engine] over every position in the game.
///
/// The played move's score comes from the same multi-PV search as the best
/// move, which keeps the centipawn loss comparable. Moves the search never
/// returns are re-searched more shallowly on their own.
///
/// Every ply is an independent search, so [concurrency] of them run at once.
/// With a [StockfishEnginePool] as the engine that is what makes a full game
/// quick; with a single process the requests queue inside it and the result is
/// the same either way.
///
/// The review is also reported while the game is still being searched: each
/// move's "after" evaluation comes from the search of the position after it, so
/// a move is handed to [onPartial] as soon as the next one is done, and
/// [GameAnalysis.plies] grows as the review fills in.
Future<GameAnalysis> analyzeGame({
  required ChessEngine engine,
  required GameLadder ladder,
  int depth = 12,
  int multiPv = 5,
  int bookPlies = 8,
  Duration? maxSearchTime = StockfishEngine.defaultMaxSearchTime,
  int concurrency = 4,
  void Function(int completed, int total)? onProgress,
  void Function(GameAnalysis partial)? onPartial,
}) async {
  final plies = ladder.plies;
  final total = plies.length;
  final scores = _PlyScores(total);

  var next = 0;
  var completed = 0;
  var built = 0;
  final analyzed = <AnalyzedMove>[];

  var emitted = 0;

  /// Reports every move whose own search and the search after it are both in.
  void report() {
    while (built < total &&
        scores.done[built] &&
        (built + 1 == total || scores.done[built + 1])) {
      analyzed.add(_buildMove(ladder, scores, built, depth, bookPlies));
      built++;
    }
    // A search that lands out of order adds nothing, so the page is not
    // repainted for it.
    if (analyzed.length == emitted) return;
    emitted = analyzed.length;
    onPartial?.call(
      GameAnalysis(
        ladder: ladder,
        moves: List<AnalyzedMove>.unmodifiable(analyzed),
        depth: depth,
        finalEval: analyzed.last.evalAfter,
      ),
    );
  }

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= total) return;
      await _searchPly(
        engine,
        ladder,
        scores,
        i,
        depth,
        multiPv,
        maxSearchTime,
      );
      onProgress?.call(++completed, total);
      report();
    }
  }

  // One worker per ply at most: a short game has nothing to parallelise.
  final workers = total == 0 ? 0 : concurrency.clamp(1, total);
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  report();

  return GameAnalysis(
    ladder: ladder,
    moves: analyzed,
    depth: depth,
    finalEval: analyzed.isEmpty ? 0 : analyzed.last.evalAfter,
  );
}

/// The searches of one game, indexed by ply.
class _PlyScores {
  _PlyScores(this.total)
    : best = List<int>.filled(total, 0),
      bestEvalWhite = List<int>.filled(total, 0),
      bestIsMate = List<bool>.filled(total, false),
      bestMoveUci = List<String>.filled(total, ''),
      pv = List<List<String>>.filled(total, const []),
      played = List<int>.filled(total, 0),
      playedIsMate = List<bool>.filled(total, false),
      reached = List<int>.filled(total, 0),
      done = List<bool>.filled(total, false);

  final int total;
  final List<int> best;
  final List<int> bestEvalWhite;
  final List<bool> bestIsMate;
  final List<String> bestMoveUci;
  final List<List<String>> pv;
  final List<int> played;
  final List<bool> playedIsMate;

  /// Whether a ply has been searched all the way through.
  final List<bool> done;

  /// Depth the engine actually reached, which is below the requested depth when
  /// the per-search time limit cut it short.
  final List<int> reached;
}

/// Searches the position before ply [i] and the move that was played in it.
Future<void> _searchPly(
  ChessEngine engine,
  GameLadder ladder,
  _PlyScores scores,
  int i,
  int depth,
  int multiPv,
  Duration? maxSearchTime,
) async {
  final plies = ladder.plies;
  final result = await engine.analyse(
    fen: ladder.startFen,
    moves: [for (final ply in plies.take(i)) ply.uci],
    depth: depth,
    multiPv: multiPv,
    maxTime: maxSearchTime,
  );
  final best = result.lines.first;
  final bestScore = sideToMoveScore(scoreCp: best.scoreCp, mateIn: best.mateIn);
  scores.best[i] = bestScore;
  scores.bestEvalWhite[i] = clampEval(
    toWhitePov(bestScore, whiteToMove: i.isEven),
  );
  scores.bestIsMate[i] = best.mateIn != null;
  scores.bestMoveUci[i] = result.bestMove;
  scores.pv[i] = best.pv;

  final ply = plies[i];
  final played = _lineFor(result, ply.uci);
  if (played != null) {
    scores.played[i] = sideToMoveScore(
      scoreCp: played.scoreCp,
      mateIn: played.mateIn,
    );
    scores.playedIsMate[i] = played.mateIn != null;
  } else {
    // The move fell outside the multi-PV window: score it on its own, a few
    // plies shallower, since only the size of the loss matters here.
    final followUp = await engine.analyse(
      fen: ladder.startFen,
      moves: [for (final earlier in plies.take(i)) earlier.uci, ply.uci],
      depth: depth > 5 ? depth - 3 : depth,
      maxTime: maxSearchTime,
    );
    final line = followUp.lines.first;
    scores.played[i] = -sideToMoveScore(
      scoreCp: line.scoreCp,
      mateIn: line.mateIn,
    );
    scores.playedIsMate[i] = line.mateIn != null;
  }
  scores.reached[i] = result.depth;
  scores.done[i] = true;
}

AnalyzedMove _buildMove(
  GameLadder ladder,
  _PlyScores scores,
  int i,
  int depth,
  int bookPlies,
) {
  final ply = ladder.plies[i];
  final cpl = centipawnLoss(
    bestScore: scores.best[i],
    playedScore: scores.played[i],
  );
  final bestUci = scores.bestMoveUci[i];
  final evalAfter = i + 1 < scores.total
      ? scores.bestEvalWhite[i + 1]
      // The played score is in the mover's point of view.
      : clampEval(toWhitePov(scores.played[i], whiteToMove: ply.isWhite));
  // A loss between a mate score and a centipawn score is not comparable: the
  // two come from different searches and different scales.
  final mixedMateScores = scores.bestIsMate[i] != scores.playedIsMate[i];
  final verdict = i < bookPlies
      ? MoveVerdict.book
      : scores.best[i] <= alreadyLostCp
      ? MoveVerdict.wasLost
      : mixedMateScores
      ? MoveVerdict.decisive
      : verdictFor(cpl: cpl, inBook: false);
  return AnalyzedMove(
    ply: ply,
    san: ply.san,
    isWhite: ply.isWhite,
    uci: ply.uci,
    evalBefore: scores.bestEvalWhite[i],
    evalAfter: clampEval(evalAfter),
    cpl: cpl,
    verdict: verdict,
    bestMoveSan: bestUci.isEmpty ? '' : ladder.sanForUci(i, bestUci),
    bestMoveUci: bestUci,
    pv: ladder.pvToSan(i, scores.pv[i]),
    depth: depth,
    reachedDepth: scores.reached[i],
  );
}

EngineInfoLine? _lineFor(EngineResult result, String uci) {
  for (final line in result.lines) {
    if (line.pv.isNotEmpty && line.pv.first == uci) return line;
  }
  return null;
}
