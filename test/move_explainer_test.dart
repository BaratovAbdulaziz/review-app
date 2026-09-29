import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/game_analyzer.dart';
import 'package:review_app/engine/move_explainer.dart';
import 'package:review_app/engine/pgn_parser.dart';
import 'package:review_app/engine/stockfish_engine.dart';

/// Returns one scripted line for whatever position is asked for, so the wording
/// can be checked without spawning an engine.
class _OneLineEngine implements ChessEngine {
  _OneLineEngine(this.replyUci, {this.replies});

  /// The reply the "engine" plays in any position.
  final String replyUci;

  /// Replies for particular positions, keyed by how many moves have been played
  /// when it is asked, for tests that look at more than one position.
  final Map<int, String>? replies;

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
    depth: depth,
    nodes: 10,
    lines: [
      EngineInfoLine(
        depth: depth,
        multiPv: 1,
        scoreCp: 0,
        mateIn: null,
        nodes: 10,
        pv: [replies?[moves.length] ?? replyUci],
      ),
    ],
  );
}

/// A move built by hand, so a test can set exactly the numbers it is about.
AnalyzedMove _move({
  required String san,
  bool isWhite = true,
  MoveVerdict verdict = MoveVerdict.good,
  int cpl = 0,
  int evalBefore = 30,
  int evalAfter = 20,
  String bestMoveSan = '',
  int reachedDepth = 12,
  int depth = 12,
}) {
  final ladder = parsePgn('1. e4 e5 *');
  return AnalyzedMove(
    ply: ladder.plies[0],
    san: san,
    isWhite: isWhite,
    uci: 'e2e4',
    evalBefore: evalBefore,
    evalAfter: evalAfter,
    cpl: cpl,
    verdict: verdict,
    bestMoveSan: bestMoveSan,
    bestMoveUci: bestMoveSan.isEmpty ? '' : 'g1f3',
    pv: '',
    depth: depth,
    reachedDepth: reachedDepth,
  );
}

/// An analyzed move for a real ply of [ladder], so the probe is handed a game
/// that really contains the move.
AnalyzedMove _moveAt(
  GameLadder ladder,
  int index,
  MoveVerdict verdict, {
  String? san,
  bool? isWhite,
}) {
  final ply = ladder.plies[index];
  return AnalyzedMove(
    ply: ply,
    san: san ?? ply.san,
    isWhite: isWhite ?? ply.isWhite,
    uci: ply.uci,
    evalBefore: 0,
    evalAfter: 0,
    cpl: 100,
    verdict: verdict,
    bestMoveSan: 'O-O',
    bestMoveUci: 'g1f3',
    pv: '',
    depth: 12,
    reachedDepth: 12,
  );
}

void main() {
  group('explainMove', () {
    test('names the move, the player and the loss for a blunder', () {
      final text = explainMove(
        _move(
          san: 'Bb5',
          isWhite: false,
          verdict: MoveVerdict.blunder,
          cpl: 340,
          evalBefore: -20,
          evalAfter: 360,
          bestMoveSan: 'O-O',
        ),
        playerName: 'hikaru',
      );

      expect(text, contains('hikaru'));
      expect(text, contains('move 1'));
      expect(text, contains('Bb5'));
      expect(text, contains('3.4 pawns'));
      expect(text, contains('blundered'));
      expect(text, contains('O-O'), reason: 'says what was best instead');
      // Black's own point of view: the engine's White-POV loss of 3.6 is a
      // 3.6 pawn gain for Black, so the sentence reads from +0.2 to -3.6.
      expect(text, contains('from +0.2 to -3.6'), reason: text);
    });

    test('says a best move was the engine choice', () {
      final text = explainMove(
        _move(san: 'Nf3', verdict: MoveVerdict.best, bestMoveSan: 'Nf3'),
      );

      expect(text, contains("the engine's first choice"));
      expect(text, contains('holds at +0.2'));
    });

    test('marks a book move as unscored', () {
      final text = explainMove(_move(san: 'e4', verdict: MoveVerdict.book));

      expect(text, contains('opening theory'));
      expect(text, contains('not scored'));
    });

    test('explains a move played from a lost position', () {
      final text = explainMove(
        _move(
          san: 'Qh5',
          isWhite: false,
          verdict: MoveVerdict.wasLost,
          evalBefore: 420,
          cpl: 200,
        ),
      );

      expect(text, contains('already 4.2 pawns down'));
      expect(text, contains('not scored'));
    });

    test('mentions a search that ran out of time', () {
      final text = explainMove(_move(san: 'Nf3', reachedDepth: 9, depth: 12));

      expect(text, contains('ran out of time'));
      expect(text, contains('depth 9'));
    });

    test('says nothing about a time limit that was not hit', () {
      final text = explainMove(_move(san: 'Nf3', reachedDepth: 12));

      expect(text, isNot(contains('ran out of time')));
    });

    test('reports what the engine reply wins', () {
      final text = explainMove(
        _move(
          san: 'Bb5',
          verdict: MoveVerdict.mistake,
          cpl: 150,
          bestMoveSan: 'O-O',
        ),
        consequence: const MoveConsequence(replySan: 'cxd5', materialSwing: 1),
      );

      expect(text, contains('Black answers cxd5'));
      expect(text, contains('wins a pawn'));
    });

    test('names a bigger win', () {
      final text = explainMove(
        _move(san: 'Bb5', verdict: MoveVerdict.blunder, cpl: 500),
        consequence: const MoveConsequence(replySan: 'Nxe4', materialSwing: 3),
      );

      expect(text, contains('wins a piece'));
    });

    test('calls a reply that wins a queen a queen', () {
      final text = explainMove(
        _move(san: 'Bxf7', verdict: MoveVerdict.blunder, cpl: 900),
        consequence: const MoveConsequence(replySan: 'Kxf7', materialSwing: 9),
      );

      expect(text, contains('wins a queen'));
    });

    test('does not claim a win when the reply gives material back', () {
      final text = explainMove(
        _move(san: 'Nf3'),
        consequence: const MoveConsequence(replySan: 'Nxe5', materialSwing: -3),
      );

      expect(text, contains('holds the position together'));
      expect(text, isNot(contains('wins')));
    });

    test('mentions a checking reply', () {
      final text = explainMove(
        _move(san: 'Nf3', verdict: MoveVerdict.mistake, cpl: 100),
        consequence: const MoveConsequence(
          replySan: 'Qxf7+',
          materialSwing: 1,
          givesCheck: true,
        ),
      );

      expect(text, contains('with check'));
    });

    test('does not print a mate score as a number of pawns', () {
      final text = explainMove(
        _move(san: 'Bxf7+', verdict: MoveVerdict.best, evalAfter: 1500),
      );

      expect(text, contains('The position is won.'));
      expect(text, isNot(contains('pawn')), reason: text);
    });

    test('says a won position was given up', () {
      final text = explainMove(
        _move(
          san: 'Rxf7',
          verdict: MoveVerdict.mistake,
          cpl: 400,
          evalBefore: 1500,
          evalAfter: 100,
        ),
      );

      expect(text, contains('giving up 4.0 pawns'));
      expect(text, contains('That gives up a won position'));
    });

    test('calls a loss past the clamp the game itself', () {
      final text = explainMove(
        _move(san: 'Qh5', verdict: MoveVerdict.blunder, cpl: 3000),
      );

      expect(text, contains('throwing away the game'));
    });

    test('says a move from a decided position is not scored', () {
      final text = explainMove(
        _move(
          san: 'Bxd1',
          isWhite: false,
          verdict: MoveVerdict.decisive,
          evalBefore: 1500,
        ),
      );

      expect(text, contains('a forced result'));
      expect(text, contains('not scored'));
      expect(text, isNot(contains('15.0')), reason: text);
    });

    test('says a move from a decided position is not scored', () {
      final text = explainMove(
        _move(san: 'Qh5', verdict: MoveVerdict.wasLost, evalBefore: -1500),
        playerName: 'bob',
      );

      expect(text, contains('bob was already lost'));
    });

    test('uses the player name when one is given and White otherwise', () {
      expect(explainMove(_move(san: 'e4')), startsWith('White played'));
      expect(
        explainMove(_move(san: 'e4', isWhite: false)),
        startsWith('Black played'),
      );
      expect(
        explainMove(_move(san: 'e4'), playerName: 'alice'),
        startsWith('alice played'),
      );
    });
  });

  group('spokenMoveCommentary', () {
    test('uses clear notation and a short verdict', () {
      final text = spokenMoveCommentary(
        _move(san: 'Nf3', verdict: MoveVerdict.best, bestMoveSan: 'Nf3'),
        playerName: 'alice',
      );

      expect(text, 'Move 1. alice played Knight to f 3. Best move.');
    });

    test('keeps engine analysis data out of the spoken feedback', () {
      final text = spokenMoveCommentary(
        _move(
          san: 'Qh5',
          verdict: MoveVerdict.blunder,
          cpl: 200,
          bestMoveSan: 'Nf3',
        ),
        playerName: 'alice',
      );

      expect(text, contains('Queen to h 5. Blunder.'));
      expect(text, isNot(contains('engine wanted')));
      expect(text, isNot(contains('Nf3')));
      expect(text, isNot(contains('pawn')));
    });

    test('speaks captures, promotions and castling naturally', () {
      expect(
        spokenMoveCommentary(
          _move(san: 'exd8=Q+', verdict: MoveVerdict.good),
          playerName: 'alice',
        ),
        contains('Pawn takes d 8, promoting to queen. Check.'),
      );
      expect(
        spokenMoveCommentary(
          _move(san: 'O-O', verdict: MoveVerdict.good),
          playerName: 'alice',
        ),
        contains('kingside castle'),
      );
    });
  });

  group('probeConsequence', () {
    test('reports the engine reply and what it wins', () async {
      // 1. e4 d5 2. exd5 — the pawn on e4 is taken, so Black is a pawn up
      // afterwards.
      final ladder = parsePgn('1. e4 d5 2. exd5 Qxd5 *');
      final consequence = await probeConsequence(
        _OneLineEngine('d8d5'),
        ladder,
        2,
      );

      expect(consequence, isNotNull);
      expect(consequence!.replySan, 'Qxd5');
      expect(consequence.materialSwing, 1);
    });

    test('reports no win when the reply wins nothing', () async {
      // After 1. e4 e5 it is White to move, and the engine develops a knight.
      final ladder = parsePgn('1. e4 e5 2. Nf3 *');
      final consequence = await probeConsequence(
        _OneLineEngine('g1f3'),
        ladder,
        1,
      );

      expect(consequence, isNotNull);
      expect(consequence!.replySan, 'Nf3');
      expect(consequence.winsMaterial, isFalse);
    });

    test(
      'counts a pawn taken en passant, which the notation only hints at',
      () async {
        // 1. e4 a6 2. e5 d5 — White can take the pawn that just moved two squares.
        final ladder = parsePgn('1. e4 a6 2. e5 d5 *');
        final consequence = await probeConsequence(
          _OneLineEngine('e5d6'),
          ladder,
          3,
        );

        expect(consequence, isNotNull);
        expect(consequence!.materialSwing, 1);
        expect(consequence.winsMaterial, isTrue);
      },
    );

    test('claims nothing when the reply is not a legal move there', () async {
      final ladder = parsePgn('1. e4 e5 2. Nf3 *');
      // A rook move that cannot be played in the position after 1. e4 e5.
      final consequence = await probeConsequence(
        _OneLineEngine('a1a8'),
        ladder,
        1,
      );

      expect(consequence, isNull);
    });

    test('returns null when the ply is past the end of the game', () async {
      final ladder = parsePgn('1. e4 e5 *');
      final consequence = await probeConsequence(
        _OneLineEngine('g8f6'),
        ladder,
        9,
      );

      expect(consequence, isNull);
    });
  });

  group('probeConsequences', () {
    test('only looks at the moves that were wrong', () async {
      final ladder = parsePgn('1. e4 d5 2. exd5 Qxd5 3. Nc3 *');
      final found = await probeConsequences(
        engine: _OneLineEngine('d8d5'),
        ladder: ladder,
        moves: [
          _moveAt(ladder, 0, MoveVerdict.best),
          _moveAt(ladder, 2, MoveVerdict.blunder, san: 'exd5'),
          _moveAt(ladder, 3, MoveVerdict.good, san: 'Qxd5', isWhite: false),
        ],
      );

      expect(found.keys, [2], reason: 'only the blunder is searched');
    });

    test('reports a reply for each move that was wrong', () async {
      final ladder = parsePgn('1. e4 d5 2. exd5 Qxd5 3. Nc3 *');
      final found = await probeConsequences(
        // After 2. exd5 the engine takes back on d5. After 2... Qxd5 it is
        // White to move, and it develops a knight.
        engine: _OneLineEngine('d8d5', replies: const {4: 'g1f3'}),
        ladder: ladder,
        moves: [
          _moveAt(ladder, 2, MoveVerdict.blunder, san: 'exd5'),
          _moveAt(ladder, 3, MoveVerdict.mistake, san: 'Qxd5'),
        ],
      );

      expect(found.keys.toSet(), {2, 3});
      expect(found[2]!.replySan, 'Qxd5');
      expect(found[2]!.winsMaterial, isTrue);
      expect(found[3]!.replySan, 'Nf3');
      expect(found[3]!.winsMaterial, isFalse);
    });

    test('has nothing to do when every move was fine', () async {
      final ladder = parsePgn('1. e4 e5 *');
      final engine = _OneLineEngine('g1f3');
      final found = await probeConsequences(
        engine: engine,
        ladder: ladder,
        moves: [_moveAt(ladder, 0, MoveVerdict.best)],
      );

      expect(found, isEmpty);
    });

    test('counts the replies it finished', () async {
      final ladder = parsePgn('1. e4 d5 2. exd5 Qxd5 *');
      var done = 0;
      await probeConsequences(
        engine: _OneLineEngine('d8d5'),
        ladder: ladder,
        moves: [
          _moveAt(ladder, 2, MoveVerdict.mistake, san: 'exd5'),
          _moveAt(ladder, 3, MoveVerdict.blunder, san: 'Qxd5', isWhite: false),
        ],
        onProgress: (completed, total) {
          done = completed;
          expect(total, 2);
        },
      );

      expect(done, 2);
    });
  });
}
