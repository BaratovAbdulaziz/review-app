import 'package:chess/chess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/game_analyzer.dart';
import 'package:review_app/engine/pgn_parser.dart';
import 'package:review_app/engine/stockfish_engine.dart';

/// One scripted engine line, in the side to move's point of view.
class _Line {
  const _Line(this.uci, this.cp) : mateIn = null;

  const _Line.mate(this.uci, this.mateIn) : cp = null;

  final String uci;
  final int? cp;
  final int? mateIn;
}

/// Returns scripted lines so the analyser's arithmetic can be checked without
/// spawning an engine.
class _FakeEngine implements ChessEngine {
  _FakeEngine(this._script);

  /// Engine lines per number of moves played.
  final Map<int, List<_Line>> _script;

  final List<List<String>> requests = [];

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
    requests.add(moves);
    final lines = _script[moves.length] ?? [const _Line('', 0)];
    return EngineResult(
      depth: 12,
      nodes: 1000,
      lines: [
        for (var i = 0; i < lines.length; i++)
          EngineInfoLine(
            depth: 12,
            multiPv: i + 1,
            scoreCp: lines[i].cp,
            mateIn: lines[i].mateIn,
            nodes: 1000,
            pv: [if (lines[i].uci.isNotEmpty) lines[i].uci],
          ),
      ],
    );
  }
}

const _shortGame = '''
[Event "Casual"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
''';

void main() {
  group('scoring helpers', () {
    test('folds mate scores into a large centipawn value', () {
      expect(sideToMoveScore(scoreCp: null, mateIn: 1), 9980);
      expect(sideToMoveScore(scoreCp: null, mateIn: -1), -9980);
      expect(sideToMoveScore(scoreCp: null, mateIn: 3), 9940);
      expect(sideToMoveScore(scoreCp: 42, mateIn: null), 42);
      expect(sideToMoveScore(scoreCp: null, mateIn: null), 0);
    });

    test('converts to the white point of view', () {
      expect(toWhitePov(120, whiteToMove: true), 120);
      expect(toWhitePov(120, whiteToMove: false), -120);
    });

    test('clamps for display', () {
      expect(clampEval(5000), 1500);
      expect(clampEval(-5000), -1500);
      expect(clampEval(120), 120);
    });

    test('centipawn loss is never negative', () {
      expect(centipawnLoss(bestScore: 100, playedScore: 40), 60);
      expect(centipawnLoss(bestScore: 100, playedScore: 100), 0);
      expect(centipawnLoss(bestScore: 100, playedScore: 180), 0);
      expect(centipawnLoss(bestScore: -50, playedScore: 400), 0);
    });

    test('verdicts follow the centipawn loss', () {
      expect(verdictFor(cpl: 0, inBook: false), MoveVerdict.best);
      expect(verdictFor(cpl: 10, inBook: false), MoveVerdict.best);
      expect(verdictFor(cpl: 30, inBook: false), MoveVerdict.good);
      expect(verdictFor(cpl: 60, inBook: false), MoveVerdict.inaccuracy);
      expect(verdictFor(cpl: 120, inBook: false), MoveVerdict.mistake);
      expect(verdictFor(cpl: 400, inBook: false), MoveVerdict.blunder);
      expect(verdictFor(cpl: 400, inBook: true), MoveVerdict.book);
    });
  });

  group('analyzeGame', () {
    test('scores every ply and classifies from the engine lines', () async {
      final engine = _FakeEngine({
        0: [_Line('e2e4', 30), _Line('d2d4', -20)],
        1: [_Line('e7e5', 30), _Line('c7c5', -20)],
        2: [_Line('g1f3', 40), _Line('b1c3', -10)],
        3: [_Line('b8c6', 40), _Line('g8f6', -10)],
        4: [_Line('b1c3', 70), _Line('f1b5', 20)],
        5: [_Line('a7a5', 20)],
        6: [const _Line('', 10)],
      });
      final ladder = parsePgn(_shortGame);

      final analysis = await analyzeGame(
        engine: engine,
        ladder: ladder,
        depth: 12,
        bookPlies: 0,
      );

      expect(analysis.plies, 6);
      // Six positions plus one extra search for the move the engine skipped.
      expect(engine.requests, hasLength(7));
      expect(engine.requests.first, isEmpty);
      expect(engine.requests[2], ['e2e4', 'e7e5']);

      expect(analysis.moves.map((move) => move.san), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bb5',
        'a6',
      ]);
      expect(analysis.moves.first.bestMoveUci, 'e2e4');
      expect(analysis.moves.first.isBestMove, isTrue);
      expect(analysis.moves.first.pv, 'e4');
      expect(analysis.moves.first.evalBefore, 30);

      // Bb5 was the engine's second choice, 50cp behind Nc3.
      expect(analysis.moves[4].cpl, 50);
      expect(analysis.moves[4].verdict, MoveVerdict.inaccuracy);
      expect(analysis.moves[4].isBestMove, isFalse);
      expect(analysis.moves[4].bestMoveSan, 'Nc3');

      // a6 was not in the engine's lines, so it was scored on its own:
      // 30cp lost against the engine's pick.
      expect(analysis.moves[5].verdict, MoveVerdict.good);
      expect(analysis.moves[5].cpl, 30);
      expect(engine.requests.last, [
        'e2e4',
        'e7e5',
        'g1f3',
        'b8c6',
        'f1b5',
        'a7a6',
      ], reason: 'the played move is searched from the position after it');
    });

    test('does not grade moves played from a lost position', () async {
      final engine = _FakeEngine({
        // Black is a rook down for the rest of the game, so its own moves are
        // marked as already lost rather than as mistakes.
        0: [_Line('e2e4', 0)],
        // Black is a rook down from here on and played e5 instead of d5.
        1: [_Line('d7d5', -600), _Line('e7e5', -800)],
        2: [_Line('g1f3', 0)],
        3: [_Line('g8f6', 0)],
        4: [_Line('f1b5', 0)],
        5: [_Line('a7a6', 0)],
        6: [const _Line('', 0)],
      });

      final analysis = await analyzeGame(
        engine: engine,
        ladder: parsePgn(_shortGame),
        bookPlies: 0,
      );

      expect(analysis.moves[1].verdict, MoveVerdict.wasLost);
      expect(analysis.moves[1].countsTowardAverage, isFalse);
      expect(analysis.moves[1].cpl, 200, reason: 'the loss is still reported');
      expect(analysis.moves.first.verdict, MoveVerdict.best);

      // Only White's move is scored, so only White's average moves.
      expect(analysis.mistakes, isEmpty);
      expect(analysis.averageCplBlack(), 0);
      expect(analysis.averageCplWhite(), 0);
      expect(analysis.moves.where((m) => m.countsTowardAverage), hasLength(5));
    });

    test('skips the opening book', () async {
      final engine = _FakeEngine({
        for (var i = 0; i <= 6; i++) i: [_Line('e2e4', 0)],
      });

      final analysis = await analyzeGame(
        engine: engine,
        ladder: parsePgn(_shortGame),
        bookPlies: 3,
      );

      expect(
        analysis.moves.take(3).map((m) => m.verdict),
        everyElement(MoveVerdict.book),
      );
      expect(analysis.moves[3].verdict, MoveVerdict.best);
      expect(analysis.averageCplWhite(), 0);
    });

    test(
      'does not grade a loss between a mate score and a score in centipawns',
      () async {
        final engine = _FakeEngine({
          0: [_Line('e2e4', 0)],
          // The best line is a forced mate, the played move is not.
          1: [const _Line.mate('c7c5', 3), _Line('e7e5', 40)],
          2: [_Line('g1f3', 0)],
          3: [_Line('g8f6', 0)],
          4: [_Line('f1b5', 0)],
          5: [_Line('a7a6', 0)],
          6: [const _Line('', 0)],
        });

        final analysis = await analyzeGame(
          engine: engine,
          ladder: parsePgn(_shortGame),
          bookPlies: 0,
        );

        final move = analysis.moves[1];
        expect(move.cpl, greaterThan(1000), reason: 'still reported as a loss');
        expect(move.verdict, MoveVerdict.decisive);
        expect(move.countsTowardAverage, isFalse);
        expect(analysis.mistakes, isEmpty);
      },
    );

    test('reports averages and mistake counts per side', () async {
      final engine = _FakeEngine({
        0: [_Line('e2e4', 0)],
        1: [_Line('e7e5', 0)],
        2: [_Line('g1f3', 0)],
        // Nc6 is 600cp behind the engine's pick.
        3: [_Line('g8f6', 900), _Line('b8c6', 300)],
        4: [_Line('f1b5', 0)],
        5: [_Line('a7a6', 0)],
        6: [const _Line('', 0)],
      });

      final analysis = await analyzeGame(
        engine: engine,
        ladder: parsePgn(_shortGame),
        bookPlies: 0,
      );

      // Black's second move drops 600cp.
      expect(analysis.moves[3].verdict, MoveVerdict.blunder);
      expect(analysis.mistakes, hasLength(1));
      expect(analysis.mistakes.single.isWhite, isFalse);
      expect(analysis.countVerdict(MoveVerdict.blunder, isWhite: false), 1);
      expect(analysis.countVerdict(MoveVerdict.blunder, isWhite: true), 0);
      expect(analysis.averageCplBlack(), greaterThan(0));
      expect(analysis.averageCplWhite(), 0);
    });
  });

  group('concurrent analysis', () {
    test('keeps as many searches in flight as it was given workers', () async {
      final engine = _SlowFakeEngine();

      final analysis = await analyzeGame(
        engine: engine,
        ladder: parsePgn(_shortGame),
        depth: 12,
        bookPlies: 0,
        concurrency: 3,
      );

      expect(analysis.plies, 6);
      expect(engine.peakInFlight, 3);
    });

    test(
      'produces the same verdicts and evaluations as a single worker',
      () async {
        final script = <int, List<_Line>>{
          0: [_Line('e2e4', 20)],
          1: [_Line('e7e5', 15)],
          2: [_Line('g1f3', 10)],
          3: [_Line('g8f6', 700), _Line('b8c6', 120)],
          4: [_Line('f1b5', 0)],
          5: [_Line('a7a6', 0)],
          6: [const _Line('', 0)],
        };

        Future<GameAnalysis> run(int concurrency) => analyzeGame(
          engine: _FakeEngine(script),
          ladder: parsePgn(_shortGame),
          depth: 12,
          bookPlies: 0,
          concurrency: concurrency,
        );

        final serial = await run(1);
        final parallel = await run(4);

        expect(parallel.plies, serial.plies);
        expect(parallel.finalEval, serial.finalEval);
        expect(parallel.averageCplWhite(), serial.averageCplWhite());
        expect(parallel.averageCplBlack(), serial.averageCplBlack());
        expect(
          parallel.moves.map((move) => move.san).toList(),
          serial.moves.map((move) => move.san).toList(),
        );
        expect(
          parallel.moves.map((move) => move.cpl).toList(),
          serial.moves.map((move) => move.cpl).toList(),
        );
      },
    );

    test(
      'streams a growing move list and ends with the finished game',
      () async {
        final partial = <GameAnalysis>[];

        final analysis = await analyzeGame(
          engine: _SlowFakeEngine(),
          ladder: parsePgn(_shortGame),
          depth: 12,
          bookPlies: 0,
          concurrency: 3,
          onPartial: partial.add,
        );

        expect(partial, isNotEmpty, reason: 'the move list fills in live');
        final lengths = partial.map((step) => step.moves.length).toList();
        expect(lengths, equals(lengths.toList()..sort()));
        expect(lengths.first, greaterThan(0), reason: 'no empty first paint');
        expect(lengths.last, analysis.moves.length);
        // Every partial list is a prefix of the finished move list.
        for (final step in partial) {
          expect(
            analysis.moves.take(step.moves.length).map((move) => move.san),
            step.moves.map((move) => move.san),
          );
        }
      },
    );

    test('handles a game with no moves', () async {
      final analysis = await analyzeGame(
        engine: _FakeEngine(const {}),
        ladder: GameLadder(
          startFen: Chess.DEFAULT_POSITION,
          plies: const [],
          sanByPly: const [],
          pgn: '',
        ),
      );

      expect(analysis.plies, 0);
      expect(analysis.finalEval, 0);
      expect(analysis.mistakes, isEmpty);
      expect(analysis.averageCplWhite(), 0);
    });

    test('scores the final position in White\'s point of view', () async {
      // A single ply: the last move's own score is the final position, and it
      // came from Black, so it has to flip sign.
      final analysis = await analyzeGame(
        engine: _FakeEngine({
          0: [_Line('e2e4', 40)],
          1: [_Line('d7d5', 60)],
        }),
        ladder: parsePgn('1. e4 d5 *'),
        bookPlies: 0,
      );

      expect(analysis.moves, hasLength(2));
      expect(analysis.moves.last.evalAfter, -60);
      expect(analysis.finalEval, -60);
    });

    test('marks the plies whose search ran out of time', () async {
      // The fake engine only ever reaches depth 4, so every ply is short.
      final analysis = await analyzeGame(
        engine: _ShallowFakeEngine(),
        ladder: parsePgn(_shortGame),
        depth: 12,
        bookPlies: 0,
      );

      expect(analysis.plies, 6);
      expect(analysis.truncatedPlies, 6);
      expect(analysis.moves.every((move) => move.truncated), isTrue);
    });

    test('counts no truncation when every search reached the depth', () async {
      final analysis = await analyzeGame(
        engine: _FakeEngine({
          0: [_Line('e2e4', 0)],
          1: [_Line('e7e5', 0)],
          2: [_Line('g1f3', 0)],
          3: [_Line('g8f6', 0)],
          4: [_Line('f1b5', 0)],
          5: [_Line('a7a6', 0)],
          6: [const _Line('', 0)],
        }),
        ladder: parsePgn(_shortGame),
        depth: 12,
        bookPlies: 0,
      );

      expect(analysis.truncatedPlies, 0);
      expect(analysis.moves.every((move) => !move.truncated), isTrue);
    });

    test('reports progress once per ply and totals the game length', () async {
      final progress = <(int, int)>[];

      await analyzeGame(
        engine: _SlowFakeEngine(),
        ladder: parsePgn(_shortGame),
        depth: 12,
        bookPlies: 0,
        concurrency: 3,
        onProgress: (completed, total) => progress.add((completed, total)),
      );

      expect(progress.map((step) => step.$1).toList(), [1, 2, 3, 4, 5, 6]);
      expect(progress.every((step) => step.$2 == 6), isTrue);
    });
  });
  test('verdict marks count up from a star to a cross', () {
    expect(MoveVerdict.best.symbol, '\u2605');
    expect(MoveVerdict.decisive.symbol, '\u2605');
    expect(MoveVerdict.good.symbol, '\u2713');
    expect(MoveVerdict.inaccuracy.symbol, '!');
    expect(MoveVerdict.mistake.symbol, '!!');
    expect(MoveVerdict.blunder.symbol, '\u2717');
  });

  test('moves that are not the fault of the mover carry no mark', () {
    // Book moves and moves from an already lost position say nothing about how
    // well the move was played, so a mark there would be a false accusation.
    expect(MoveVerdict.book.symbol, isEmpty);
    expect(MoveVerdict.wasLost.symbol, isEmpty);
  });
}

/// Reports a lower depth than requested, the way a search stopped by its time
/// limit does.
class _ShallowFakeEngine implements ChessEngine {
  @override
  void dispose() {}

  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) async => EngineResult(
    depth: 4,
    nodes: 10,
    lines: [
      const EngineInfoLine(
        depth: 4,
        multiPv: 1,
        scoreCp: 0,
        mateIn: null,
        nodes: 10,
        pv: [],
      ),
    ],
  );
}

/// An engine that never answers immediately, so overlap is observable.
class _SlowFakeEngine implements ChessEngine {
  int inFlight = 0;
  int peakInFlight = 0;

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
    inFlight++;
    peakInFlight = inFlight > peakInFlight ? inFlight : peakInFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    inFlight--;
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
}
