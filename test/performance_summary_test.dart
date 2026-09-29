import 'package:chess/chess.dart' show Chess, Move;
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/game_analyzer.dart';
import 'package:review_app/engine/performance_summary.dart';
import 'package:review_app/engine/pgn_parser.dart';
import 'package:review_app/engine/stockfish_engine.dart';

const _game = '''
[Event "Test"]
[Site "Local"]
[Date "2026.01.01"]
[White "alice"]
[Black "bob"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
''';

/// Replays [fen] and [moves] so the fake engine can offer a legal best move.
Chess _positionAt(String fen, List<String> moves) {
  final chess = Chess();
  chess.load(fen);
  for (final uci in moves) {
    final move = _legal(chess)
        .firstWhere((candidate) => _uciOf(candidate) == uci);
    chess.move(move);
  }
  return chess;
}

List<Move> _legal(Chess chess) => chess.moves({'asObjects': true}).cast<Move>();

String _uciOf(Move move) => move.fromAlgebraic + move.toAlgebraic;

/// A fake engine that either agrees with every move the game played, or always
/// prefers something else and reports a bad score for the position, so every
/// move comes out as a blunder.
class _ScriptedEngine implements ChessEngine {
  _ScriptedEngine(this.ladder, {required this.blunder});

  final GameLadder ladder;
  final bool blunder;

  @override
  void dispose() {}

  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) async {
    // The analyzer scores a move that fell outside the PV window on its own, and
    // that call comes with the default multiPv. A clean score there makes the
    // move look as bad as the best line said it was.
    if (multiPv == 1) {
      return EngineResult(
        depth: depth,
        nodes: 100,
        lines: [
          EngineInfoLine(
            depth: depth,
            multiPv: 1,
            scoreCp: 0,
            mateIn: null,
            nodes: 100,
            pv: const [],
          ),
        ],
      );
    }

    final played = ladder.plies[moves.length].uci;
    var pv = played;
    var score = 0;
    if (blunder) {
      score = 300;
      final legal = _legal(_positionAt(fen, moves))
          .map(_uciOf)
          .where((uci) => uci != played)
          .toList();
      pv = legal.isEmpty ? played : legal.first;
    }
    return EngineResult(
      depth: depth,
      nodes: 100,
      lines: [
        EngineInfoLine(
          depth: depth,
          multiPv: 1,
          scoreCp: score,
          mateIn: null,
          nodes: 100,
          pv: [pv],
        ),
      ],
    );
  }
}

Future<GameAnalysis> _analyse(bool blunder, {String game = _game}) {
  final ladder = parsePgn(game);
  return analyzeGame(
    engine: _ScriptedEngine(ladder, blunder: blunder),
    ladder: ladder,
    depth: 10,
    bookPlies: 0,
    maxSearchTime: const Duration(milliseconds: 1),
    concurrency: 1,
  );
}

/// A game where the opponent's final move is a capture, so the material the
/// reviewer's last move gave away is only found by looking at the reply.
const _lastMoveIsTaken = '''
[Event "Test"]
[Site "Local"]
[Date "2026.01.01"]
[White "alice"]
[Black "bob"]
[Result "*"]

1. e4 d5 2. exd5 Qxd5 *
''';

void main() {
  test('a game played the way the engine wanted reads as clean', () async {
    final summary = summarise(await _analyse(false), isReviewerWhite: true);
    expect(summary.headline, 'You played the game you saw');
    expect(summary.accuracy, 1.0);
    expect(summary.best, 3);
    expect(summary.blunders, 0);
    expect(
      summary.points.any((point) => point.contains('engine\'s move 3 times')),
      isTrue,
    );
  });

  test('a game where every move misses the mark reads as rough', () async {
    final summary = summarise(await _analyse(true), isReviewerWhite: true);
    expect(summary.accuracy, 0.0);
    expect(summary.blunders, 3);
    expect(summary.headline, 'A rough one, with plenty to build on');
    expect(summary.overview, contains('0 percent'));
    expect(summary.overview, contains('3 moments'));
  });

  test('only the side being reviewed is counted', () async {
    final asWhite = summarise(await _analyse(true), isReviewerWhite: true);
    final asBlack = summarise(await _analyse(true), isReviewerWhite: false);
    expect(asWhite.blunders, 3);
    expect(asBlack.blunders, 3);
    expect(
      asWhite.points.join(' '),
      isNot(contains('black')),
      reason: 'the review is written for the person playing, not the opponent',
    );
  });

  test('the expensive moment is named', () async {
    final summary = summarise(await _analyse(true), isReviewerWhite: true);
    expect(
      summary.points.any((point) => point.contains('expensive moment')),
      isTrue,
    );
  });

  test('material taken on the reply to the last move still counts', () async {
    // The reviewer's last move is the last one of theirs in their own list, but
    // the opponent still answered it, so the piece it gave up has to be counted.
    final summary = summarise(
      await _analyse(false, game: _lastMoveIsTaken),
      isReviewerWhite: true,
    );
    expect(
      summary.points.any(
        (point) => point.contains('won 1') && point.contains('gave up 1'),
      ),
      isTrue,
      reason:
          'the pawn won on move 2 and handed straight back is a wash: '
          '${summary.points.join(' | ')}',
    );
  });

  test('the summary always says something', () async {
    for (final blunder in [true, false]) {
      final summary = summarise(await _analyse(blunder), isReviewerWhite: true);
      expect(summary.headline, isNotEmpty);
      expect(summary.overview, isNotEmpty);
      expect(summary.points, isNotEmpty);
    }
  });
}
