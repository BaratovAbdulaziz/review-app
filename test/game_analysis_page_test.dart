import 'dart:io';

import 'package:chess/chess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/pgn_parser.dart';
import 'package:review_app/engine/stockfish_engine.dart';
import 'package:review_app/models/chess_game.dart';
import 'package:review_app/tts/commentator.dart';
import 'package:review_app/ui/chess_board_view.dart';
import 'package:review_app/ui/game_analysis_page.dart';

/// Returns a fixed score so the page can be driven without an engine binary.
class _StubEngine implements ChessEngine {
  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) async {
    return EngineResult(
      depth: depth,
      nodes: 1234,
      lines: [
        EngineInfoLine(
          depth: depth,
          multiPv: 1,
          scoreCp: 25,
          mateIn: null,
          nodes: 1234,
          pv: const ['e2e4'],
        ),
      ],
    );
  }

  @override
  void dispose() {}
}

/// Plays the first capture it can find, so the page has a real reply to report
/// when it looks a ply deeper to explain a move.
class _CapturingEngine implements ChessEngine {
  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) async {
    final board = Chess();
    board.load(fen, check_validity: false);
    for (final uci in moves) {
      board.move({'from': uci.substring(0, 2), 'to': uci.substring(2, 4)});
    }
    final legal = board.generate_moves();
    final capture = legal.where((m) => m.captured != null);
    final move = capture.isNotEmpty ? capture.first : legal.first;
    return EngineResult(
      depth: depth,
      nodes: 1234,
      lines: [
        EngineInfoLine(
          depth: depth,
          multiPv: 1,
          scoreCp: 25,
          mateIn: null,
          nodes: 1234,
          pv: ['${move.fromAlgebraic}${move.toAlgebraic}'],
        ),
      ],
    );
  }

  @override
  void dispose() {}
}

/// A speech engine that is never installed, so the page's commentary stays
/// quiet and no process is spawned during a test.
class _SilentRunner implements TtsProcessRunner {
  const _SilentRunner();

  @override
  Future<String?> which(String name) async => null;

  @override
  Future<TtsProcessResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    required Duration timeout,
    void Function(Process process)? onStarted,
  }) async => const TtsProcessResult(1, error: 'no speech engine in tests');
}

const _pgn = '''
[Event "Casual"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
''';

/// Long enough for the moves past the opening book to be graded, and with a
/// knight on c6 that 5... Be7 leaves alone for 5. ... Bxc6, so there is a real
/// reply to explain.
const _longPgn = '''
[Event "Casual"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 O-O 7. Bb3 Re8
8. a3 d6 9. d3 Bd7 10. Nbd2 Bc6 1-0
''';

/// The position on the board after [ply] half moves of [game].
String _fenAfter(ChessGame game, int ply) =>
    parsePgn(game.pgn!).plies[ply - 1].fenAfter;

ChessGame _game() {
  return ChessGame(
    url: 'https://www.chess.com/game/live/1',
    title: 'Casual Game',
    white: const ChessPlayer(username: 'alice', result: 'win', rating: 1500),
    black: const ChessPlayer(username: 'bob', result: 'loss', rating: 1490),
    timeControl: '300+3',
    endTime: DateTime.utc(2026),
    rated: false,
    pgn: _pgn,
  );
}

ChessGame _longGame() {
  final game = _game();
  return ChessGame(
    url: game.url,
    title: game.title,
    white: game.white,
    black: game.black,
    timeControl: game.timeControl,
    endTime: game.endTime,
    rated: game.rated,
    pgn: _longPgn,
  );
}

Widget _page({ChessGame? game, ChessEngine? engine}) {
  return MaterialApp(
    home: GameAnalysisPage(
      game: game ?? _game(),
      username: 'alice',
      engine: engine ?? _StubEngine(),
      commentator: Commentator(runner: const _SilentRunner())..enabled = false,
    ),
  );
}

void main() {
  /// A window big enough for the wide layout, where the whole page fits.
  void useLargeWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('lays out the board and the move list', (tester) async {
    useLargeWindow(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('You vs opponent'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('caps the board width on a wide window', (tester) async {
    useLargeWindow(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    final board = tester.getSize(find.byType(ChessBoardView));
    expect(board.width, ChessBoardView.maxBoardSize);
    expect(board.width, board.height, reason: 'the board stays square');
  });

  testWidgets('analyses the game with the injected engine', (tester) async {
    useLargeWindow(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyse game'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Re-analyse'), findsOneWidget);
    // Every ply of the fixture game is now on the move list with a verdict.
    expect(find.text('e4'), findsWidgets);
    expect(find.text('Bb5'), findsWidgets);

    // Stepping forward shows the detail for the move that was played.
    await tester.tap(find.byTooltip('Next move'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('you —'), findsOneWidget);
    expect(find.textContaining('Line (depth 12): e4'), findsOneWidget);
  });

  testWidgets('walks one move at a time with the keyboard', (tester) async {
    useLargeWindow(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyse game'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.textContaining('you played e4 on move 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(find.textContaining('opponent played a6 on move 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('always shows the engine move on the played position', (
    tester,
  ) async {
    useLargeWindow(tester);
    await tester.pumpWidget(
      _page(game: _longGame(), engine: _CapturingEngine()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyse game'));
    await tester.pumpAndSettle();
    // 5... Be7 is beyond the book and has a different engine move.
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byTooltip('Next move'));
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Engine move:'), findsOneWidget);
    final board = tester.widget<ChessBoardView>(find.byType(ChessBoardView));
    expect(
      board.bestMove,
      isNotNull,
      reason: 'the engine move is drawn without asking for it',
    );
    expect(
      board.fen,
      _fenAfter(_longGame(), 10),
      reason: 'the board shows the position that was played',
    );
    expect(
      find.text('Show on board'),
      findsNothing,
      reason: 'there is no preview toggle any more',
    );
    expect(find.text('Show played move'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains a game it cannot replay', (tester) async {
    useLargeWindow(tester);
    final game = _game();
    await tester.pumpWidget(
      MaterialApp(
        home: GameAnalysisPage(
          game: ChessGame(
            url: game.url,
            title: game.title,
            white: game.white,
            black: game.black,
            timeControl: game.timeControl,
            rated: game.rated,
            pgn: '[FEN "brnkqnrb/pppppppp/8/8/8/8/PPPPPPPP/BRNKQNRB w GBgb - 0 1"]\n\n1. a3 a6 *',
          ),
          username: 'alice',
          engine: _StubEngine(),
          commentator: Commentator(runner: const _SilentRunner())
            ..enabled = false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot replay'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains the move that is on the board in words', (
    tester,
  ) async {
    useLargeWindow(tester);
    await tester.pumpWidget(_page(game: _longGame()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyse game'));
    await tester.pumpAndSettle();
    // 5. O-O is the first move the review is allowed to grade.
    for (var i = 0; i < 9; i++) {
      await tester.tap(find.byTooltip('Next move'));
      await tester.pumpAndSettle();
    }

    expect(
      find.textContaining('you played O-O on move 5'),
      findsOneWidget,
      reason: 'the panel says who played what, in words',
    );
    expect(find.textContaining('gave up 0.5 pawns'), findsOneWidget);
    expect(find.textContaining('an inaccuracy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('says what the opponent gets after a wrong move', (tester) async {
    useLargeWindow(tester);
    await tester.pumpWidget(
      _page(game: _longGame(), engine: _CapturingEngine()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyse game'));
    await tester.pumpAndSettle();

    // 5... Be7 leaves the knight on c6 there, so the engine takes it.
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byTooltip('Next move'));
      await tester.pumpAndSettle();
    }

    expect(
      find.textContaining('opponent played Be7 on move 5'),
      findsOneWidget,
    );
    expect(
      find.textContaining('you answer Bxc6'),
      findsOneWidget,
      reason: 'the reply is played out on the board, not guessed',
    );
    expect(
      find.textContaining('wins a piece'),
      findsOneWidget,
      reason: 'the panel says what the move actually let go of',
    );
    expect(find.textContaining('so opponent loses it'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
