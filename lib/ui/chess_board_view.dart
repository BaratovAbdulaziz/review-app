import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chess_pieces.dart';

/// Read-only chessboard used to show the position being reviewed.
///
/// The pieces are the official Cburnett set, bundled as SVGs and decoded once
/// into pictures (see `ChessPieceSet`), rather than chess characters: the
/// hollow white characters are missing from a lot of system fonts, and the two
/// sets rarely have the same metrics, which left the board with missing and
/// mismatched pieces. Drawing a character is also not an option inside a
/// painter, so the pieces are decoded and measured up front and the painter
/// only ever places a ready picture with a transform.
///
/// Until the pictures are ready, and for any piece whose asset cannot be
/// loaded, the board falls back to the hand-drawn outlines further down, so a
/// piece is never missing.
class ChessBoardView extends StatefulWidget {
  const ChessBoardView({
    super.key,
    required this.fen,
    this.lastMove,
    this.bestMove,
    this.statusSymbol,
    this.statusColor,
    this.inCheck = false,
    this.whiteAtBottom = true,
  });

  final String fen;

  /// Uci move that was just played, e.g. `e2e4`.
  final String? lastMove;

  /// Uci move the engine preferred, e.g. `d2d4`.
  final String? bestMove;

  /// A mark for how good the move on the board was, such as a star or a cross.
  /// Empty when the move is not being judged.
  final String? statusSymbol;
  final Color? statusColor;

  /// Highlights the side to move's king.
  final bool inCheck;

  final bool whiteAtBottom;

  // The light square is a touch darker than the artwork's white, so a white
  // piece keeps its shape on it instead of blending into the background.
  static const _light = Color(0xFFDCD9C3);
  static const _dark = Color(0xFF7A9663);
  static const _check = Color(0x66E23D3D);

  /// The move that was played: a blue tint on the squares it used, and a blue
  /// arrow.
  static const _playedTint = Color(0x5C2F6FD0);
  static const _playedArrow = Color(0xE62F6FD0);

  /// The move the engine would have played: a green tint on the square it goes
  /// to, and a green arrow. A green arrow therefore means the move on the board
  /// is the engine's own choice.
  static const _bestTint = Color(0x4D34A853);
  static const _bestArrow = Color(0xE634A853);

  /// A soft dark edge under an arrow, so it reads over a white piece as well as
  /// over a dark square.
  static const _arrowEdge = Color(0x7A1B1B1B);

  /// Largest board the analysis page asks for, so a wide window does not
  /// stretch it across half the screen.
  static const double maxBoardSize = 420;

  static const _files = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

  @override
  State<ChessBoardView> createState() => _ChessBoardViewState();
}

class _ChessBoardViewState extends State<ChessBoardView>
    with SingleTickerProviderStateMixin {
  ChessPieceSet? _pieces;
  late final AnimationController _moveAnimation;
  String? _animatedMove;

  @override
  void initState() {
    super.initState();
    _moveAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pieces != null) return;
    ChessPieceSet.load(context).then((pieces) {
      if (!mounted) return;
      setState(() => _pieces = pieces);
    });
  }

  @override
  void didUpdateWidget(covariant ChessBoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final move = widget.lastMove;
    if (move != null &&
        move != oldWidget.lastMove &&
        widget.fen != oldWidget.fen &&
        move.length >= 4) {
      _animatedMove = move;
      _moveAnimation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _moveAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _moveAnimation,
        builder: (context, child) => CustomPaint(
          painter: _BoardPainter(
            fen: widget.fen,
            lastMove: widget.lastMove,
            bestMove: widget.bestMove,
            inCheck: widget.inCheck,
            whiteAtBottom: widget.whiteAtBottom,
            pieces: _pieces,
            statusSymbol: widget.statusSymbol,
            statusColor: widget.statusColor,
            moveProgress: _animatedMove == widget.lastMove
                ? _moveAnimation.value
                : 1,
          ),
          isComplex: true,
          willChange: _moveAnimation.isAnimating,
        ),
      ),
    );
  }
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({
    required this.fen,
    required this.lastMove,
    required this.bestMove,
    required this.inCheck,
    required this.whiteAtBottom,
    required this.pieces,
    required this.moveProgress,
    required this.statusSymbol,
    required this.statusColor,
  });

  final String fen;
  final String? lastMove;
  final String? bestMove;
  final bool inCheck;
  final bool whiteAtBottom;

  /// The decoded piece set, or null while it is still being loaded.
  final ChessPieceSet? pieces;

  /// Zero while the moved piece is still on its starting square, one when it
  /// reaches the position in [fen].
  final double moveProgress;

  /// The mark for how good the move on the board was, shown beside the square
  /// it reached. Empty when the move is not being judged.
  final String? statusSymbol;
  final Color? statusColor;

  static final Map<String, Path> _piecePaths = {
    'p': _pawn(),
    'r': _rook(),
    'n': _knight(),
    'b': _bishop(),
    'q': _queen(),
    'k': _king(),
  };

  /// How much of a square a piece fills, measured on the artwork rather than on
  /// the square, so every piece reads at the same size.
  static const double _pieceSize = 0.88;

  /// Share of a square taken by the halo that keeps black pieces readable on a
  /// dark square.
  ///
  /// It is a share rather than a weight in the artwork's own units so that it
  /// stays the same thickness whichever piece set is bundled and however large
  /// the set's viewBox happens to be.
  static const double _haloShare = 0.10;

  static const Color _blackHalo = Color(0xE6EDEDE6);

  /// A white piece on a light square is almost the same colour as the square,
  /// so its shape has to be carried by its edge. A dark rim is stroked under the
  /// white fill, which is the mirror image of the pale halo the black pieces get:
  /// it widens the artwork's own thin outline into a border that reads on either
  /// square. The fill and the crisp outline are painted on top of it, so the
  /// piece keeps its official look and only gains a border.
  ///
  /// A share of the square for the largest piece in the set; a smaller piece
  /// gets a proportionally wider rim, so a pawn is as readable as a queen.
  static const double _whiteRimShare = 0.074;

  /// A pawn gets a wider rim than a queen, but not an unlimited one.
  static const double _maxWhiteRimShare = 0.14;

  /// Rim colour for the white pieces' detail shapes, which the artwork draws
  /// without an outline of their own.
  static const Color _rimColour = Color(0xFF2B2A26);

  /// The artwork outlines a piece thinly, which is under a whole pixel on a
  /// small board. A white piece on a light square is carried entirely by that
  /// outline, so it is never allowed to fall below this many device pixels:
  /// below that the piece stops reading as a piece.
  static const double _minOutlineWidth = 1.25;

  @override
  void paint(Canvas canvas, Size size) {
    final square = math.min(size.width, size.height) / 8;
    final origin = Offset(
      (size.width - square * 8) / 2,
      (size.height - square * 8) / 2,
    );
    final placement = _parsePlacement(fen.split(' ').first);
    final checked = _checkedKing(placement);

    for (var rank = 0; rank < 8; rank++) {
      for (var file = 0; file < 8; file++) {
        final rect = Rect.fromLTWH(
          origin.dx + file * square,
          origin.dy + rank * square,
          square,
          square,
        );
        canvas.drawRect(rect, Paint()..color = _squareColor(file, rank));
      }
    }

    _paintHighlights(canvas, origin, square, checked);
    final animatedMove = moveProgress < 1 ? _uCI(lastMove) : null;
    final movingPiece = animatedMove == null
        ? null
        : placement[animatedMove.to];
    var stationary = placement;
    if (animatedMove != null && movingPiece != null) {
      stationary = Map<String, String>.of(placement)..remove(animatedMove.to);
    }
    _paintPieces(canvas, origin, square, stationary);
    if (animatedMove != null && movingPiece != null) {
      final rect = Rect.lerp(
        _rectFor(animatedMove.from, origin, square),
        _rectFor(animatedMove.to, origin, square),
        Curves.easeOutCubic.transform(moveProgress),
      )!;
      _paintPiece(canvas, rect, movingPiece, square);
    }
    // The arrows go on last, over the pieces: an arrow under them is hidden by
    // the piece it starts on, which is the half that says where the move began.
    _paintArrows(canvas, origin, square);
    _paintStatus(canvas, origin, square);
    _paintCoordinates(canvas, origin, square);
  }

  Color _squareColor(int file, int rank) =>
      (file + rank).isEven ? ChessBoardView._light : ChessBoardView._dark;

  void _paintHighlights(
    Canvas canvas,
    Offset origin,
    double square,
    String? checked,
  ) {
    final played = _uCI(lastMove);
    final preferred = _uCI(bestMove);
    // The engine's square is tinted first, so the played squares stay readable
    // on top of it where the two moves share a square.
    if (preferred != null && preferred != played) {
      _tint(canvas, origin, square, preferred.to, ChessBoardView._bestTint);
    }
    if (played != null) {
      _tint(canvas, origin, square, played.from, ChessBoardView._playedTint);
      _tint(canvas, origin, square, played.to, ChessBoardView._playedTint);
    }
    if (checked != null) {
      canvas.drawRect(
        _rectFor(checked, origin, square),
        Paint()..color = ChessBoardView._check,
      );
    }
  }

  void _tint(
    Canvas canvas,
    Offset origin,
    double square,
    String squareName,
    Color color,
  ) {
    canvas.drawRect(
      _rectFor(squareName, origin, square),
      Paint()..color = color,
    );
  }

  void _paintPieces(
    Canvas canvas,
    Offset origin,
    double square,
    Map<String, String> placement,
  ) {
    for (final entry in placement.entries) {
      _paintPiece(
        canvas,
        _rectFor(entry.key, origin, square),
        entry.value,
        square,
      );
    }
  }

  void _paintPiece(Canvas canvas, Rect rect, String piece, double square) {
    final art = pieces?[piece];
    if (art != null) {
      _paintArt(canvas, rect, art, square);
    } else if (_piecePaths[piece.toLowerCase()] != null) {
      _paintOutline(canvas, rect, piece, square);
    }
  }

  /// Draws the piece centred on its square. One scale is shared by the whole
  /// set, derived from the largest piece, so a pawn stays smaller than a queen
  /// and no piece is stretched: the biggest piece takes up [_pieceSize] of the
  /// square and the rest keep the artwork's own proportions.
  void _paintArt(Canvas canvas, Rect rect, ChessPieceArt art, double square) {
    final scale = square * _pieceSize / pieces!.maxInkExtent;
    final scaledInkExtent = art.inkExtent;
    canvas.save();
    canvas.translate(
      rect.center.dx - art.ink.center.dx * scale * art.sizeScale,
      rect.center.dy - art.ink.center.dy * scale * art.sizeScale,
    );
    canvas.scale(scale * art.sizeScale);

    if (art.isWhite) {
      // The rim is measured as a share of a square and then converted into the
      // artwork's own units, because that is what the scaled canvas strokes in.
      // A smaller piece is compensated, so the rim comes out the same width on
      // the board for a pawn as for a queen: the pawn is the piece that
      // disappears into a light square without it.
      final share = math.min(
        _maxWhiteRimShare,
        _whiteRimShare * pieces!.maxInkExtent / scaledInkExtent,
      );
      final rimWidth =
          share * pieces!.maxInkExtent / (_pieceSize * art.sizeScale);
      for (final shape in art.shapes) {
        canvas.drawPath(
          shape.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = rimWidth
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..color = shape.outline ?? _rimColour,
        );
      }
    }
    if (!art.isWhite) {
      // The bundled black pieces are near black on their own, which is how they
      // are drawn on lichess, but that all but vanishes on a dark square. A pale
      // halo underneath keeps them readable without touching the artwork. Like
      // the white rim it is a share of a square, expressed in the artwork's own
      // units so it survives any viewBox and any board size.
      final halo = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            _haloShare * pieces!.maxInkExtent / (_pieceSize * art.sizeScale)
        ..strokeJoin = StrokeJoin.round
        ..color = _blackHalo;
      for (final shape in art.shapes) {
        canvas.drawPath(shape.path, halo);
      }
    }
    for (final shape in art.shapes) {
      final fill = shape.fill;
      if (fill != null) canvas.drawPath(shape.path, Paint()..color = fill);
    }
    for (final shape in art.shapes) {
      final outline = shape.outline;
      if (outline == null) continue;
      canvas.drawPath(
        shape.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(shape.outlineWidth, _minOutlineWidth)
          ..strokeJoin = StrokeJoin.miter
          ..strokeCap = StrokeCap.round
          ..color = outline,
      );
    }
    canvas.restore();
  }

  void _paintOutline(Canvas canvas, Rect rect, String piece, double square) {
    final path = _piecePaths[piece.toLowerCase()]!;
    final isWhite = piece == piece.toUpperCase();
    // Each piece is drawn in a unit square, so one scale and one translate
    // place every piece the same way inside its square.
    final size = square * _pieceSize;

    canvas.save();
    canvas.translate(
      rect.left + (square - size) / 2,
      rect.top + (square - size) / 2,
    );
    canvas.scale(size, size);

    canvas.drawPath(
      path,
      Paint()
        ..color = isWhite ? const Color(0xFFF8F8F4) : const Color(0xFF23231F),
    );
    // The outline is the opposite of the fill, so black pieces still read on
    // a dark square and white pieces still read on a light one.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.03
        ..strokeJoin = StrokeJoin.round
        ..color = isWhite ? const Color(0xFF2B2B28) : const Color(0xFFF1F1EC),
    );
    canvas.restore();
  }

  void _paintCoordinates(Canvas canvas, Offset origin, double square) {
    for (var i = 0; i < 8; i++) {
      final isLight = i.isEven;
      final fileColor = isLight ? ChessBoardView._dark : ChessBoardView._light;
      final rankColor = isLight ? ChessBoardView._light : ChessBoardView._dark;

      final filePainter = TextPainter(
        text: TextSpan(
          text: ChessBoardView._files[whiteAtBottom ? i : 7 - i],
          style: TextStyle(
            fontSize: square * 0.15,
            fontWeight: FontWeight.bold,
            color: fileColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      filePainter.paint(
        canvas,
        origin +
            Offset(
              (i + 0.5) * square - filePainter.width / 2,
              7 * square + square - filePainter.height * 1.15,
            ),
      );

      final rankPainter = TextPainter(
        text: TextSpan(
          text: '${whiteAtBottom ? 8 - i : i + 1}',
          style: TextStyle(
            fontSize: square * 0.15,
            fontWeight: FontWeight.bold,
            color: rankColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      rankPainter.paint(
        canvas,
        origin +
            Offset(square * 0.06, (i + 0.55) * square - rankPainter.height / 2),
      );
    }
  }

  void _paintArrows(Canvas canvas, Offset origin, double square) {
    final played = _uCI(lastMove);
    final preferred = _uCI(bestMove);
    if (played != null) {
      // When the move on the board is the one the engine wanted, the arrow is
      // green: the two indicators have become one fact.
      final colour = played == preferred
          ? ChessBoardView._bestArrow
          : ChessBoardView._playedArrow;
      _drawArrow(canvas, origin, square, played, colour);
    }
    if (preferred != null && preferred != played) {
      _drawArrow(canvas, origin, square, preferred, ChessBoardView._bestArrow);
    }
  }

  void _drawArrow(
    Canvas canvas,
    Offset origin,
    double square,
    _SquarePair pair,
    Color colour,
  ) {
    final from = _centerOf(pair.from, origin, square);
    final to = _centerOf(pair.to, origin, square);
    final direction = (to - from) / (to - from).distance;
    // The perpendicular the arrow is drawn around, so it tapers sideways.
    final side = Offset(-direction.dy, direction.dx);

    // The shaft stops well short of the piece it starts on, and the head stops
    // short of the square it points at, so both pieces stay recognisable.
    final tail = from + direction * square * 0.3;
    final tip = to - direction * square * 0.16;
    final headBase = to - direction * square * 0.34;

    // A tapered body and a flared head, drawn as one shape: a line with a
    // triangle stuck on the end always shows a seam where they meet.
    final path = Path()
      ..moveTo(
        (tail + side * square * 0.055).dx,
        (tail + side * square * 0.055).dy,
      )
      ..lineTo(
        (headBase + side * square * 0.095).dx,
        (headBase + side * square * 0.095).dy,
      )
      ..lineTo(
        (headBase + side * square * 0.15).dx,
        (headBase + side * square * 0.15).dy,
      )
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(
        (headBase - side * square * 0.15).dx,
        (headBase - side * square * 0.15).dy,
      )
      ..lineTo(
        (headBase - side * square * 0.095).dx,
        (headBase - side * square * 0.095).dy,
      )
      ..lineTo(
        (tail - side * square * 0.055).dx,
        (tail - side * square * 0.055).dy,
      )
      ..close();

    // A soft shadow, offset a little, lifts the arrow off the board so it reads
    // as a marker rather than as part of the squares.
    canvas.save();
    canvas.translate(0, square * 0.03);
    canvas.drawPath(
      path,
      Paint()
        ..color = ChessBoardView._arrowEdge
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();

    // The dark rim is the same shape stroked a little wider, which is what
    // keeps the arrow legible over a white piece and a pale square alike.
    canvas.drawPath(
      path,
      Paint()
        ..color = ChessBoardView._arrowEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = square * 0.05
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.fill
        ..strokeJoin = StrokeJoin.round,
    );
  }

  Offset _centerOf(String squareName, Offset origin, double square) =>
      _rectFor(squareName, origin, square).center;

  Rect _rectFor(String squareName, Offset origin, double square) {
    final file = squareName.codeUnitAt(0) - 97;
    final rank = 56 - squareName.codeUnitAt(1);
    final column = whiteAtBottom ? file : 7 - file;
    final row = whiteAtBottom ? rank : 7 - rank;
    return Rect.fromLTWH(
      origin.dx + column * square,
      origin.dy + row * square,
      square,
      square,
    );
  }

  _SquarePair? _uCI(String? move) {
    if (move == null || move.length < 4) return null;
    return _SquarePair(move.substring(0, 2), move.substring(2, 4));
  }

  Map<String, String> _parsePlacement(String placement) {
    final onBoard = <String, String>{};
    final ranks = placement.split('/');
    for (var r = 0; r < ranks.length; r++) {
      var file = 0;
      for (final char in ranks[r].split('')) {
        final digit = int.tryParse(char);
        if (digit != null) {
          file += digit;
          continue;
        }
        if (file < 8) {
          onBoard['${ChessBoardView._files[file]}${8 - r}'] = char;
        }
        file++;
      }
    }
    return onBoard;
  }

  String? _checkedKing(Map<String, String> placement) {
    if (!inCheck) return null;
    final fields = fen.split(' ');
    final whiteToMove = fields.length < 2 || fields[1] != 'b';
    final target = whiteToMove ? 'K' : 'k';
    for (final entry in placement.entries) {
      if (entry.value == target) return entry.key;
    }
    return null;
  }

  /// The mark sits in the corner of the square the move reached, so it never
  /// covers the piece that just moved there.
  void _paintStatus(Canvas canvas, Offset origin, double square) {
    final symbol = statusSymbol;
    final colour = statusColor;
    if (symbol == null || symbol.isEmpty || colour == null) return;
    final pair = _uCI(lastMove);
    final target = pair == null
        ? origin + Offset(square * 0.5, square * 0.5)
        : _centerOf(pair.to, origin, square) +
              Offset(square * 0.3, -square * 0.3);
    final radius = square * 0.19;

    canvas.drawCircle(
      target,
      radius,
      Paint()..color = const Color(0xFF1B1B1B).withValues(alpha: 0.82),
    );
    canvas.drawCircle(
      target,
      radius,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = square * 0.035,
    );

    final painter = TextPainter(
      text: TextSpan(
        text: symbol,
        style: TextStyle(
          fontSize: radius * 1.25,
          fontWeight: FontWeight.bold,
          color: colour,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      target - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_BoardPainter oldDelegate) =>
      oldDelegate.fen != fen ||
      oldDelegate.lastMove != lastMove ||
      oldDelegate.bestMove != bestMove ||
      oldDelegate.inCheck != inCheck ||
      oldDelegate.whiteAtBottom != whiteAtBottom ||
      oldDelegate.moveProgress != moveProgress ||
      oldDelegate.statusSymbol != statusSymbol ||
      oldDelegate.statusColor != statusColor ||
      !identical(oldDelegate.pieces, pieces);

  // Hand-drawn outlines, used until the bundled piece set has loaded and for
  // any piece whose asset is missing, so a square is never left empty.

  static Path _base(double top) => Path()
    ..addRRect(
      RRect.fromLTRBR(0.18, top, 0.82, top + 0.14, const Radius.circular(0.04)),
    );

  static Path _pawn() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(0.5, 0.22), radius: 0.13))
    ..moveTo(0.5, 0.36)
    ..cubicTo(0.36, 0.42, 0.32, 0.56, 0.32, 0.66)
    ..lineTo(0.24, 0.72)
    ..lineTo(0.76, 0.72)
    ..lineTo(0.68, 0.66)
    ..cubicTo(0.68, 0.56, 0.64, 0.42, 0.5, 0.36)
    ..close()
    ..addPath(_base(0.72), Offset.zero);

  static Path _rook() => Path()
    ..addRect(const Rect.fromLTRB(0.22, 0.12, 0.34, 0.28))
    ..addRect(const Rect.fromLTRB(0.37, 0.12, 0.49, 0.28))
    ..addRect(const Rect.fromLTRB(0.52, 0.12, 0.64, 0.28))
    ..addRect(const Rect.fromLTRB(0.67, 0.12, 0.79, 0.28))
    ..addRRect(
      RRect.fromLTRBR(0.18, 0.28, 0.83, 0.42, const Radius.circular(0.03)),
    )
    ..addRRect(
      RRect.fromLTRBR(0.33, 0.42, 0.68, 0.58, const Radius.circular(0.03)),
    )
    ..addPath(_base(0.72), Offset.zero);

  static Path _knight() => Path()
    ..moveTo(0.28, 0.86)
    ..lineTo(0.30, 0.60)
    ..cubicTo(0.32, 0.44, 0.42, 0.34, 0.58, 0.26)
    ..lineTo(0.52, 0.12)
    ..lineTo(0.64, 0.22)
    ..cubicTo(0.70, 0.28, 0.72, 0.36, 0.68, 0.42)
    ..cubicTo(0.64, 0.48, 0.58, 0.50, 0.56, 0.56)
    ..cubicTo(0.55, 0.66, 0.62, 0.74, 0.70, 0.80)
    ..lineTo(0.72, 0.86)
    ..close()
    ..addPath(_base(0.80), Offset.zero);

  static Path _bishop() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(0.5, 0.13), radius: 0.08))
    ..moveTo(0.5, 0.20)
    ..cubicTo(0.72, 0.34, 0.68, 0.58, 0.74, 0.70)
    ..lineTo(0.26, 0.70)
    ..cubicTo(0.32, 0.58, 0.28, 0.34, 0.5, 0.20)
    ..close()
    ..addPath(_base(0.70), Offset.zero);

  static Path _queen() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(0.5, 0.10), radius: 0.075))
    ..addOval(Rect.fromCircle(center: const Offset(0.24, 0.20), radius: 0.06))
    ..addOval(Rect.fromCircle(center: const Offset(0.76, 0.20), radius: 0.06))
    ..moveTo(0.16, 0.34)
    ..lineTo(0.24, 0.24)
    ..lineTo(0.34, 0.40)
    ..lineTo(0.5, 0.16)
    ..lineTo(0.66, 0.40)
    ..lineTo(0.76, 0.24)
    ..lineTo(0.84, 0.34)
    ..lineTo(0.80, 0.58)
    ..cubicTo(0.74, 0.68, 0.76, 0.72, 0.78, 0.74)
    ..lineTo(0.22, 0.74)
    ..cubicTo(0.24, 0.72, 0.26, 0.68, 0.20, 0.58)
    ..close()
    ..addPath(_base(0.72), Offset.zero);

  static Path _king() => Path()
    ..addRect(const Rect.fromLTRB(0.45, 0.06, 0.55, 0.26))
    ..addRect(const Rect.fromLTRB(0.38, 0.13, 0.62, 0.20))
    ..moveTo(0.20, 0.40)
    ..lineTo(0.28, 0.28)
    ..lineTo(0.38, 0.42)
    ..lineTo(0.5, 0.30)
    ..lineTo(0.62, 0.42)
    ..lineTo(0.72, 0.28)
    ..lineTo(0.80, 0.40)
    ..lineTo(0.77, 0.60)
    ..cubicTo(0.72, 0.68, 0.74, 0.72, 0.76, 0.74)
    ..lineTo(0.24, 0.74)
    ..cubicTo(0.26, 0.72, 0.28, 0.68, 0.23, 0.60)
    ..close()
    ..addPath(_base(0.72), Offset.zero);
}

class _SquarePair {
  const _SquarePair(this.from, this.to);

  final String from;
  final String to;
}
