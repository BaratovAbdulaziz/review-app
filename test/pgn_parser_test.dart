import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/engine/pgn_parser.dart';

const _scholarsMates = '''
[Event "Live Chess"]
[Site "Chess.com"]
[Date "2026.09.01"]
[Round "-"]
[White "Alice"]
[Black "Bob"]
[Result "0-1"]
[TimeControl "180"]
[Termination "Bob won by resignation"]

1. e4 {[%clk 0:02:59]} 1... e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0
''';

const _promotionAndCastling = '''
[Event "Daily Chess"]
[Result "1-0"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be7
8. f3 O-O 9. Qd2 b5 10. O-O-O Nbd7 11. g4 b4 12. Na4 Nxe4 13. Nxe4 d5
14. exd5 exd5 15. Rxd5 Nxd5 16. Nc3 Nf6 17. Bg5 h6 18. Bh4 Rc8 19. Rhe1 Be6
20. Bxf6 Qxf6 21. Rxd5 Qxd5 22. Bxd5 Rd8 23. Rd1 1-0
''';

/// The tail of a real Chess.com game where Black promotes on e1 and then plays
/// on for another fourteen moves. The move library silently drops promotions
/// when they are applied from a move object, which used to cut these games
/// short right at the promotion.
const _promotionContinuesPgn = '''
[Event "Live Chess"]
[Result "*"]
[FEN "8/8/8/8/6K1/2bkp3/8/8 w - - 9 77"]

77. Kf3 Bd2 78. Kg2 Bc1 79. Kh3 Bb2 80. Kg4 Bc3 81. Kf5 e2 82. Kg4 e1=Q
83. Kf3 Be5 84. Kg2 Ke4 85. Kh3 Qg1 86. Kh4 Qg2 87. Kh5 Qg1 88. Kh6 Qg8
89. Kh5 Qh7+ *
''';

/// Chess.com annotates plenty of moves, which must not break the replay.
const _annotatedPgn = '''
[Event "Daily Chess"]
[Result "1/2-1/2"]

1. e4!? e5?! 2. Nf3 Nc6 3. Bb5!! a6??? 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6
8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8
14. Ng3 g6 15. Bg5 h6 16. Bd2 Bg7 17. a4 c5 18. d5 c4 1/2-1/2
''';

void main() {
  group('parsePgn', () {
    test('builds a uci ladder with fens for a real game', () {
      final ladder = parsePgn(_scholarsMates);

      expect(ladder.startFen, startsWith('rnbqkbnr/pppppppp/8/8'));
      expect(ladder.plies.map((ply) => ply.uci), [
        'e2e4',
        'e7e5',
        'f1c4',
        'b8c6',
        'd1h5',
        'g8f6',
        'h5f7',
      ]);
      expect(ladder.plies.map((ply) => ply.san), [
        'e4',
        'e5',
        'Bc4',
        'Nc6',
        'Qh5',
        'Nf6',
        'Qxf7#',
      ]);
      expect(ladder.plies.first.fenBefore, ladder.startFen);
      expect(
        ladder.plies.first.fenAfter,
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      expect(
        ladder.plies[6].fenAfter,
        'r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4',
      );
      expect(ladder.plies.last.isWhite, isTrue);
      expect(ladder.plies[1].isWhite, isFalse);
      expect(ladder.plies[6].moveNumber, 4);
    });

    test('resolves castling and en passant to uci', () {
      final ladder = parsePgn(_promotionAndCastling);

      String? uciForSan(String san, {required bool isWhite}) => ladder.plies
          .firstWhere(
            (ply) => ply.san == san && ply.isWhite == isWhite,
            orElse: () => throw StateError('$san not found'),
          )
          .uci;

      expect(uciForSan('O-O', isWhite: false), 'e8g8');
      expect(uciForSan('O-O-O', isWhite: true), 'e1c1');
      expect(uciForSan('cxd4', isWhite: false), 'c5d4');
    });

    test('exposes a uci to san lookup per ply for engine lines', () {
      final ladder = parsePgn(_scholarsMates);

      expect(ladder.sanForUci(0, 'e2e4'), 'e4');
      expect(ladder.sanForUci(2, 'f1c4'), 'Bc4');
      expect(ladder.sanForUci(2, 'e2e4'), 'e2e4', reason: 'not legal here');
      expect(ladder.pvToSan(0, ['e2e4', 'e7e5', 'f1c4']), 'e4 e5 Bc4');
      expect(ladder.pvToSan(0, ['d2d4']), 'd4');
      expect(ladder.pvToSan(0, ['a1a8']), '', reason: 'not a legal move');
    });

    test('handles promotion', () {
      final ladder = parsePgn('''
[Event "Casual"]
[Result "1-0"]

1. d4 h5 2. d5 h4 3. d6 h3 4. dxe7 1-0
''');

      expect(ladder.plies.last.uci, 'd6e7');
      expect(ladder.plies.last.san, 'dxe7');
    });

    test('keeps playing after a promotion', () {
      final ladder = parsePgn(_promotionContinuesPgn);

      expect(ladder.isTruncated, isFalse);
      expect(ladder.missingPly, 0);
      expect(ladder.plies, hasLength(26));
      expect(ladder.startFen, '8/8/8/8/6K1/2bkp3/8/8 w - - 9 77');
      expect(ladder.plies[11].san, 'e1=Q');
      expect(ladder.plies[11].uci, 'e2e1q');
      // The promoted queen is really on the board, not silently dropped.
      expect(ladder.plies[11].fenAfter, contains('q'));
      expect(ladder.plies.last.san, 'Qh7+');
    });

    test('accepts annotated moves', () {
      final ladder = parsePgn(_annotatedPgn);

      expect(ladder.isTruncated, isFalse);
      expect(ladder.plies.last.san, 'c4');
      expect(ladder.plies[2].san, 'Nf3');
      expect(ladder.plies[8].uci, 'e1g1');
    });

    test('flags a game whose moves cannot all be read', () {
      // 4. a7 is illegal here: Black still has a pawn on a7.
      final ladder = parsePgn('''
[Event "Casual"]
[Result "*"]

1. a4 h5 2. a5 h4 3. a6 h3 4. a7 h2 5. a8=Q h1=Q *
''');

      expect(ladder.plies.length, lessThan(ladder.movesInPgn * 2));
      expect(ladder.isTruncated, isTrue);
      expect(ladder.missingPly, greaterThan(0));
    });

    test('does not flag a complete game as truncated', () {
      expect(parsePgn(_scholarsMates).isTruncated, isFalse);
      expect(parsePgn(_scholarsMates).movesInPgn, 7);
    });

    test('keeps the custom starting position', () {
      final ladder = parsePgn('''
[Event "Position play"]
[SetUp "1"]
[FEN "8/8/4k3/8/8/8/4P3/K7 w - - 0 1"]
[Result "1-0"]

1. e4 Ke7 2. e5 1-0
''');

      expect(ladder.startFen, '8/8/4k3/8/8/8/4P3/K7 w - - 0 1');
      expect(ladder.plies.first.uci, 'e2e4');
      expect(ladder.plies.first.fenBefore, ladder.startFen);
    });

    test('throws when no move can be read at all', () {
      expect(
        () => parsePgn('[Event "x"]\n[Result "*"]\n\n*'),
        throwsA(isA<PgnParseException>()),
      );
    });

    test('rejects empty pgn data', () {
      expect(() => parsePgn('   '), throwsA(isA<PgnParseException>()));
    });
  });
}
