import 'package:flutter_test/flutter_test.dart';
import 'package:review_app/engine/board_facts.dart';

void main() {
  test('parses the starting position', () {
    final board = parseFenBoard(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    );
    expect(board['a1'], 'R');
    expect(board['h8'], 'r');
    expect(board['e4'], isNull);
    final material = materialCount(board);
    expect(material.white, 39);
    expect(material.black, 39);
  });

  test('finds a piece that is attacked and undefended', () {
    // White queen on e4 with a black rook down the e file and nothing between.
    final board = parseFenBoard('4r3/8/8/8/4Q3/8/8/4K3 w - - 0 1');
    expect(board['e4'], 'Q');
    expect(isHanging(board, 'e4'), isTrue);
  });

  test('an attacked but defended piece is not hanging', () {
    // Black queen on d4 eyes d1, but the white king on e2 backs it up.
    final board = parseFenBoard('4k3/8/8/8/3q4/8/8/3QK3 w - - 0 1');
    expect(
      isSquareAttacked(board, 'd1', false),
      isTrue,
      reason: 'queen eyes d1',
    );
    expect(isHanging(board, 'd1'), isFalse, reason: 'the king defends d1');
    expect(isHanging(board, 'd4'), isTrue, reason: 'nothing defends d4');
  });

  test('a pawn captures forwards only', () {
    // Black pawn on d5 attacks c4 and e4, never the square in front of it.
    final board = parseFenBoard('4k3/8/8/3p4/8/8/8/4K3 w - - 0 1');
    expect(isSquareAttacked(board, 'c4', false), isTrue);
    expect(isSquareAttacked(board, 'e4', false), isTrue);
    expect(isSquareAttacked(board, 'd4', false), isFalse);
  });

  test('finds knight attacks', () {
    // Knight on f4 reaches e2.
    expect(
      isSquareAttacked(
        parseFenBoard('4k3/8/8/8/5n2/8/8/4K3 w - - 0 1'),
        'e2',
        false,
      ),
      isTrue,
    );
    // Knight on g1 reaches e2.
    expect(
      isSquareAttacked(
        parseFenBoard('4k3/8/8/8/8/8/8/4K1n1 w - - 0 1'),
        'e2',
        false,
      ),
      isTrue,
    );
    // A knight two files away on the same rank cannot reach.
    expect(
      isSquareAttacked(
        parseFenBoard('4k3/8/8/8/8/8/8/Kn6 w - - 0 1'),
        'e2',
        false,
      ),
      isFalse,
    );
  });

  test('finds rook and king attacks', () {
    // Rook on d8 down the file onto the white king on d2.
    expect(
      isSquareAttacked(
        parseFenBoard('3rk3/8/8/8/8/8/3K4/8 w - - 0 1'),
        'd2',
        false,
      ),
      isTrue,
    );
    // The black king on e8 is next door to nothing on d7 here.
    expect(
      isSquareAttacked(
        parseFenBoard('4k3/8/8/8/8/8/8/K7 w - - 0 1'),
        'd1',
        false,
      ),
      isFalse,
    );
  });

  test('a blocked slider does not see through', () {
    // A black rook on a1 attacks the black... white pawn on a4 up the file.
    expect(
      isSquareAttacked(
        parseFenBoard('7k/8/8/8/p7/8/8/r2k4 w - - 0 1'),
        'a4',
        false,
      ),
      isTrue,
    );
    // Putting a white bishop on a3 in the way hides it.
    expect(
      isSquareAttacked(
        parseFenBoard('7k/8/8/8/p7/B7/8/r2k4 w - - 0 1'),
        'a4',
        false,
      ),
      isFalse,
    );
  });

  test('a diagonal slider sees down a clear diagonal', () {
    // White bishop on c3 reaches a1 through the empty b2.
    expect(
      isSquareAttacked(
        parseFenBoard('7k/8/8/8/8/2B5/8/4K3 w - - 0 1'),
        'a1',
        true,
      ),
      isTrue,
    );
  });
}
