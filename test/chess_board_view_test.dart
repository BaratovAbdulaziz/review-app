import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/ui/chess_board_view.dart';

const _startPosition =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

const _size = 320.0;

/// Brightest and darkest pixel in the middle of a square, as 0 to 255.
({int lightest, int darkest}) _sampleSquare(
  ByteData data,
  int file,
  int rank, {
  bool fromBottom = true,
}) {
  final square = _size / 8;
  // `rank` counts from rank 8, so rank 7 is rank 1 and sits at the bottom.
  final imageRow = fromBottom ? rank : 7 - rank;
  var lightest = 0;
  var darkest = 255;
  for (var dy = square * 0.3; dy < square * 0.7; dy++) {
    for (var dx = square * 0.3; dx < square * 0.7; dx++) {
      final x = (file * square + dx).floor();
      final y = (imageRow * square + dy).floor();
      final offset = (y * _size.toInt() + x) * 4;
      final luminance =
          (data.getUint8(offset) * 299 +
              data.getUint8(offset + 1) * 587 +
              data.getUint8(offset + 2) * 114) ~/
          1000;
      if (luminance > lightest) lightest = luminance;
      if (luminance < darkest) darkest = luminance;
    }
  }
  return (lightest: lightest, darkest: darkest);
}

/// Share of the square's pixels that are piece ink, i.e. clearly darker than
/// either square colour.
double _inkFraction(ByteData data, int file, int imageRow) {
  final square = _size / 8;
  var ink = 0;
  var sampled = 0;
  for (var dy = 1; dy < square - 1; dy++) {
    for (var dx = 1; dx < square - 1; dx++) {
      final x = (file * square + dx).floor();
      final y = (imageRow * square + dy).floor();
      final offset = (y * _size.toInt() + x) * 4;
      final luminance =
          (data.getUint8(offset) * 299 +
              data.getUint8(offset + 1) * 587 +
              data.getUint8(offset + 2) * 114) ~/
          1000;
      sampled++;
      if (luminance < 110) ink++;
    }
  }
  return ink / sampled;
}

Future<ByteData> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  late ByteData data;
  // Rasterising has to happen outside the test's fake async zone.
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return data;
}

/// Lets the bundled piece SVGs finish decoding and measuring.
///
/// The board paints its own outlines until they are ready, and the work needs
/// the real event loop, so the test alternates real turns with pumps until the
/// board has repainted with the real pieces.
Future<void> _awaitPieces(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<ByteData> _pumpBoard(
  WidgetTester tester, {
  String fen = _startPosition,
  bool whiteAtBottom = true,
  String? lastMove,
  String? bestMove,
  String? statusSymbol,
  Color? statusColor,
  double size = _size,
}) async {
  // The board has to fill the view, otherwise the sampled pixels are not the
  // board's pixels.
  tester.view.physicalSize = Size(size, size);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: size,
        height: size,
        child: ChessBoardView(
          fen: fen,
          lastMove: lastMove,
          bestMove: bestMove,
          statusSymbol: statusSymbol,
          statusColor: statusColor,
          whiteAtBottom: whiteAtBottom,
        ),
      ),
    ),
  );
  await _awaitPieces(tester);
  return _capture(tester);
}

/// True when any pixel of the board is close to [colour], which is how an arrow
/// or a tint is looked for: the shape is thin, so a sample point is a gamble.
bool _showsColour(
  ByteData data,
  double size,
  Color colour, {
  int tolerance = 26,
}) {
  final pixels = size.toInt() * size.toInt();
  for (var i = 0; i < pixels; i++) {
    final offset = i * 4;
    if ((data.getUint8(offset) - colour.r * 255).abs() <= tolerance &&
        (data.getUint8(offset + 1) - colour.g * 255).abs() <= tolerance &&
        (data.getUint8(offset + 2) - colour.b * 255).abs() <= tolerance) {
      return true;
    }
  }
  return false;
}

/// Mean change per channel, 0 to 255, between the same square of two
/// captures. This is how much a piece stands out from the square it is on.
double _meanChange(
  ByteData withPiece,
  ByteData withoutPiece,
  double size,
  int file,
  int row,
) {
  final square = size / 8;
  var total = 0;
  var counted = 0;
  for (var dy = 1; dy < square - 1; dy++) {
    for (var dx = 1; dx < square - 1; dx++) {
      final x = (file * square + dx).floor();
      final y = (row * square + dy).floor();
      final offset = (y * size.toInt() + x) * 4;
      total +=
          ((withPiece.getUint8(offset) - withoutPiece.getUint8(offset)).abs() +
              (withPiece.getUint8(offset + 1) -
                      withoutPiece.getUint8(offset + 1))
                  .abs() +
              (withPiece.getUint8(offset + 2) -
                      withoutPiece.getUint8(offset + 2))
                  .abs()) ~/
          3;
      counted++;
    }
  }
  return total / counted;
}

/// True when a pixel close to [colour] sits within [radius] of [centre].
bool _showsColourNear(
  ByteData data,
  double size,
  Color colour, {
  required double centreX,
  required double centreY,
  required double radius,
  int tolerance = 26,
}) {
  final minX = (centreX - radius).clamp(0, size).floor();
  final maxX = (centreX + radius).clamp(0, size).floor();
  final minY = (centreY - radius).clamp(0, size).floor();
  final maxY = (centreY + radius).clamp(0, size).floor();
  for (var y = minY; y < maxY; y++) {
    for (var x = minX; x < maxX; x++) {
      final offset = (y * size.toInt() + x) * 4;
      if ((data.getUint8(offset) - colour.r * 255).abs() <= tolerance &&
          (data.getUint8(offset + 1) - colour.g * 255).abs() <= tolerance &&
          (data.getUint8(offset + 2) - colour.b * 255).abs() <= tolerance) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  testWidgets('slides the played piece through intermediate frames', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(_size, _size);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Widget board(String fen, String? lastMove) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: _size,
        height: _size,
        child: ChessBoardView(fen: fen, lastMove: lastMove),
      ),
    );

    await tester.pumpWidget(board(_startPosition, null));
    await _awaitPieces(tester);
    await tester.pumpWidget(
      board(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        'e2e4',
      ),
    );
    await tester.pump();
    final atStart = await _capture(tester);

    await tester.pump(const Duration(milliseconds: 130));
    final halfway = await _capture(tester);

    expect(_meanChange(atStart, halfway, _size, 4, 6), greaterThan(1));
  });

  testWidgets('draws a light white piece and a dark black piece', (
    tester,
  ) async {
    final data = await _pumpBoard(tester);

    // The white king on e1 is light with a dark outline.
    final whiteKing = _sampleSquare(data, 4, 7);
    expect(
      whiteKing.lightest,
      greaterThan(200),
      reason: 'white piece is drawn',
    );
    expect(whiteKing.darkest, lessThan(90), reason: 'white piece is outlined');

    // The black king on e8 is drawn.
    final blackKing = _sampleSquare(data, 4, 0);
    expect(blackKing.darkest, lessThan(80), reason: 'black piece is drawn');

    // d5 is empty, so it holds square colour only: dark ink there would mean a
    // piece is painted outside its own square.
    expect(
      _sampleSquare(data, 3, 3).darkest,
      greaterThan(120),
      reason: 'no piece leaks into the empty square beside them',
    );
  });

  testWidgets('every piece stands out from both square colours', (
    tester,
  ) async {
    // A white piece on a light square used to be almost the colour of the
    // square, so a small board lost the pawn and the bishop. Each piece is
    // placed on a light and a dark square and compared with the same square
    // left empty, which is what "the piece is missing" means in pixels.
    const size = 240.0;
    const empty = '4k3/8/8/8/8/8/8/8 w - - 0 1';
    final blank = await _pumpBoard(tester, fen: empty, size: size);

    // d4 is a dark square and d5 a light one.
    for (final piece in 'PNBRQK'.split('')) {
      for (final (fen, row, onLight) in [
        ('4k3/8/8/8/3${piece}4/8/8/8 w - - 0 1', 4, false),
        ('4k3/8/8/3${piece}4/8/8/8 w - - 0 1', 3, true),
        ('4k3/8/8/8/3${piece.toLowerCase()}4/8/8/8 w - - 0 1', 4, false),
        ('4k3/8/8/3${piece.toLowerCase()}4/8/8/8 w - - 0 1', 3, true),
      ]) {
        final data = await _pumpBoard(tester, fen: fen, size: size);
        final change = _meanChange(data, blank, size, 3, row);
        final colour = piece == piece.toLowerCase() ? 'black' : 'white';
        final isWhite = colour == 'white';
        expect(
          change,
          greaterThanOrEqualTo(isWhite && onLight ? 40 : 30),
          reason:
              '$colour $piece on a ${onLight ? 'light' : 'dark'} square only '
              'changes it by ${change.toStringAsFixed(1)}/255, so it reads as '
              'part of the square',
        );
      }
    }
  });

  testWidgets('keeps every piece inside its own square', (tester) async {
    final data = await _pumpBoard(tester);

    // f3 is empty, so it only has square colours: never the dark ink of a
    // piece, which would mean a piece is drawn outside its own square.
    final empty = _sampleSquare(data, 5, 5);
    expect(empty.lightest, greaterThan(180));
    expect(empty.darkest, greaterThan(120), reason: 'no piece leaks sideways');

    // The knight on g1 is drawn.
    expect(_sampleSquare(data, 6, 7).darkest, lessThan(80));
  });

  testWidgets('draws the played move and the engine move in different '
      'colours', (tester) async {
    final data = await _pumpBoard(tester, lastMove: 'e2e4', bestMove: 'd7d5');

    expect(
      _showsColour(data, _size, const Color(0xFF2F6FD0)),
      isTrue,
      reason: 'the move that was played is drawn in blue',
    );
    expect(
      _showsColour(data, _size, const Color(0xFF34A853)),
      isTrue,
      reason: 'the engine\'s move is drawn in green',
    );
  });

  testWidgets('draws the engine arrow over the pieces, not under them', (
    tester,
  ) async {
    // e1g1 is castling: the arrowhead lands on the g1 knight, so an arrow drawn
    // under the pieces would be hidden by it.
    final data = await _pumpBoard(tester, bestMove: 'e1g1');

    final square = _size / 8;
    final found = _showsColourNear(
      data,
      _size,
      const Color(0xFF34A853),
      // Just short of the g1 knight's centre, which is where the head sits.
      centreX: square * 6.3,
      centreY: square * 7.5,
      radius: square * 0.2,
    );

    expect(found, isTrue, reason: 'the arrow head is drawn over the knight');
  });

  testWidgets('draws the played move in green when the engine wanted it too', (
    tester,
  ) async {
    final data = await _pumpBoard(tester, lastMove: 'e2e4', bestMove: 'e2e4');

    expect(
      _showsColour(data, _size, const Color(0xFF34A853)),
      isTrue,
      reason: 'the move on the board is the engine\'s own choice',
    );
    expect(
      _showsColour(data, _size, const Color(0xFF2F6FD0)),
      isFalse,
      reason: 'no separate blue arrow, the two indicators are one move',
    );
  });

  testWidgets('flips the board', (tester) async {
    final data = await _pumpBoard(tester, whiteAtBottom: false);

    // Black's back rank is at the bottom now, White's at the top, so the rows
    // the sampler reads are the other way round.
    expect(
      _sampleSquare(data, 4, 0, fromBottom: false).darkest,
      lessThan(80),
      reason: 'the black king is at the bottom',
    );
    expect(
      _sampleSquare(data, 4, 7, fromBottom: false).lightest,
      greaterThan(200),
      reason: 'the white king is at the top',
    );
  });

  testWidgets('draws a position with a promoted piece', (tester) async {
    final data = await _pumpBoard(
      tester,
      // A queen that just promoted on d8, with the black king on f8.
      fen: '3Q1k2/8/8/8/8/8/8/4K3 w - - 0 1',
      lastMove: 'd7d8',
    );

    // The new queen on d8 and the white king on e1 are both drawn.
    expect(_sampleSquare(data, 3, 0).lightest, greaterThan(200));
    expect(_sampleSquare(data, 4, 7).lightest, greaterThan(200));
    // The black king on f8 is drawn.
    final blackKing = _sampleSquare(data, 5, 0);
    expect(blackKing.darkest, lessThan(80));
    // e8 is empty next to it, so it must not have picked up any of the king's
    // ink.
    expect(_sampleSquare(data, 4, 0).darkest, greaterThan(120));
    // The move came from d7, which is empty and only tinted.
    expect(_sampleSquare(data, 3, 1).darkest, greaterThan(120));
  });

  testWidgets('renders the bundled piece set at its own sizes', (tester) async {
    final data = await _pumpBoard(
      tester,
      // A white queen on d5 and a white pawn on f5, so both sizes of piece are
      // covered by one board.
      fen: '4k3/8/8/3Q1P2/8/8/8/4K3 w - - 0 1',
    );

    // A bundled Cburnett pawn is a small shape in the middle of its square, not
    // something that fills it corner to corner.
    final pawn = _inkFraction(data, 5, 3);
    expect(pawn, greaterThan(0.04), reason: 'the pawn is drawn');
    expect(pawn, lessThan(0.5), reason: 'the pawn leaves its square around it');

    // The set's size hierarchy survives, so the queen covers more of its square
    // than the pawn does.
    expect(_inkFraction(data, 3, 3), greaterThan(pawn));

    // Black pieces are near black, so they carry a pale halo to stay readable on
    // a dark square. Without it they all but disappear into the square.
    final start = await _pumpBoard(tester, fen: _startPosition);
    final blackPawn = _sampleSquare(start, 0, 1);
    final emptyDark = _sampleSquare(start, 0, 5);
    expect(blackPawn.darkest, lessThan(80), reason: 'the black pawn is drawn');
    expect(
      blackPawn.lightest,
      greaterThan(emptyDark.lightest + 25),
      reason: 'the black pawn is outlined in a light colour',
    );
  });

  testWidgets('paints the move status mark in the verdict colour', (
    tester,
  ) async {
    const blunder =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

    final plain = await _pumpBoard(tester, fen: blunder, lastMove: 'e2e4');
    final red = await _pumpBoard(
      tester,
      fen: blunder,
      lastMove: 'e2e4',
      statusSymbol: '\u2717',
      statusColor: const Color(0xFFB3261E),
    );
    final green = await _pumpBoard(
      tester,
      fen: blunder,
      lastMove: 'e2e4',
      statusSymbol: '\u2717',
      statusColor: const Color(0xFF1B873F),
    );

    expect(
      _showsColour(red, _size, const Color(0xFFB3261E)),
      isTrue,
      reason: 'the mark should be drawn in the colour of the verdict',
    );
    expect(
      _showsColour(red, _size, const Color(0xFF1B873F)),
      isFalse,
      reason: 'a blunder must not be painted as a good move',
    );
    expect(_showsColour(green, _size, const Color(0xFF1B873F)), isTrue);
    expect(
      _identical(plain, red),
      isFalse,
      reason: 'the mark should be painted at all, not just accepted',
    );
  });
}

/// Whether two renderings are byte for byte the same, used to prove something
/// was actually drawn rather than silently skipped.
bool _identical(ByteData a, ByteData b) {
  final left = a.buffer.asUint8List();
  final right = b.buffer.asUint8List();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
