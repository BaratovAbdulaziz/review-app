import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/stockfish_engine.dart';

void main() {
  group('parseInfoLine', () {
    test('parses a cp score with a principal variation', () {
      final line = parseInfoLine(
        'info depth 12 seldepth 18 multipv 1 score cp 34 nodes 4821 nps '
        '910000 hashfull 12 tbhits 0 time 5 pv e2e4 e7e5 g1f3',
      );

      expect(line, isNotNull);
      expect(line!.depth, 12);
      expect(line.multiPv, 1);
      expect(line.scoreCp, 34);
      expect(line.mateIn, isNull);
      expect(line.nodes, 4821);
      expect(line.pv, ['e2e4', 'e7e5', 'g1f3']);
    });

    test('parses a mate score', () {
      final line = parseInfoLine(
        'info depth 20 multipv 1 score mate 3 nodes 12 pv d1h5',
      );

      expect(line!.mateIn, 3);
      expect(line.scoreCp, isNull);
      expect(line.pv, ['d1h5']);
    });

    test('parses negative mate scores and multipv indexes', () {
      final line = parseInfoLine(
        'info depth 9 multipv 4 score mate -2 nodes 44 pv a2a3',
      );

      expect(line!.multiPv, 4);
      expect(line.mateIn, -2);
    });

    test('tolerates an empty pv and a trailing space', () {
      final line = parseInfoLine(
        'info depth 1 seldepth 0 multipv 1 score cp 0 nodes 0 nps 0 pv ',
      );

      expect(line, isNotNull);
      expect(line!.pv, isEmpty);
    });

    test('returns null for non-info and scoreless lines', () {
      expect(parseInfoLine('bestmove e2e4 ponder e7e5'), isNull);
      expect(
        parseInfoLine('info string NNUE evaluation using nn-1a2b.nnue'),
        isNull,
      );
      expect(parseInfoLine('readyok'), isNull);
    });

    test('returns null when the score value is missing', () {
      expect(parseInfoLine('info depth 5 seldepth 0 score cp pv e2e4'), isNull);
    });
  });

  group('StockfishEnginePool', () {
    test('leaves room for the desktop and caps the worker count', () {
      expect(StockfishEnginePool.workersForMachine(1), 1);
      expect(StockfishEnginePool.workersForMachine(2), 1);
      expect(StockfishEnginePool.workersForMachine(4), 2);
      expect(StockfishEnginePool.workersForMachine(8), 6);
      expect(StockfishEnginePool.workersForMachine(128), 8);
    });

    test('round-robins searches over its workers', () async {
      final pool = StockfishEnginePool(
        binaryPath: '/nonexistent/stockfish',
        engines: [_FakeEngine('a'), _FakeEngine('b'), _FakeEngine('c')],
      );

      final results = await Future.wait([
        pool.analyse(fen: 'startpos', depth: 10),
        pool.analyse(fen: 'startpos', depth: 10),
        pool.analyse(fen: 'startpos', depth: 10),
        pool.analyse(fen: 'startpos', depth: 10),
      ]);

      expect(pool.isRunning, isTrue);
      expect(pool.runningWorkers, 3);
      expect(results.map((result) => result.lines.single.pv.single), [
        'a',
        'b',
        'c',
        'a',
      ]);
    });

    test('passes the search settings through to the chosen worker', () async {
      final worker = _FakeEngine('a');
      final pool = StockfishEnginePool(
        binaryPath: '/nonexistent/stockfish',
        engines: [worker],
      );

      await pool.analyse(
        fen: 'fen',
        moves: const ['e2e4'],
        depth: 14,
        multiPv: 5,
        maxTime: const Duration(seconds: 3),
      );

      expect(worker.requests, hasLength(1));
      final request = worker.requests.single;
      expect(request.fen, 'fen');
      expect(request.moves, ['e2e4']);
      expect(request.depth, 14);
      expect(request.multiPv, 5);
      expect(request.maxTime, const Duration(seconds: 3));
    });

    test('disposes every worker and refuses later searches', () async {
      final workers = [_FakeEngine('a'), _FakeEngine('b')];
      final pool = StockfishEnginePool(
        binaryPath: '/nonexistent/stockfish',
        engines: workers,
      );

      pool.dispose();
      pool.dispose();

      expect(workers.every((worker) => worker.disposed), isTrue);
      expect(pool.runningWorkers, 0);
      expect(pool.isRunning, isFalse);
      expect(
        () => pool.analyse(fen: 'startpos', depth: 10),
        throwsA(isA<EngineException>()),
      );
    });
  });
}

/// Names the worker that served a search, so the pool's dispatch is visible.
class _FakeEngine implements ChessEngine {
  _FakeEngine(this.name);

  final String name;
  final List<_Request> requests = [];
  bool disposed = false;

  @override
  void dispose() => disposed = true;

  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) async {
    requests.add(
      _Request(
        fen: fen,
        moves: moves,
        depth: depth,
        multiPv: multiPv,
        maxTime: maxTime,
      ),
    );
    return EngineResult(
      depth: depth,
      nodes: 1,
      lines: [
        EngineInfoLine(
          depth: depth,
          multiPv: 1,
          scoreCp: 0,
          mateIn: null,
          nodes: 1,
          pv: [name],
        ),
      ],
    );
  }
}

class _Request {
  const _Request({
    required this.fen,
    required this.moves,
    required this.depth,
    required this.multiPv,
    required this.maxTime,
  });

  final String fen;
  final List<String> moves;
  final int depth;
  final int multiPv;
  final Duration? maxTime;
}
