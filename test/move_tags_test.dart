import 'package:flutter_test/flutter_test.dart';
import 'package:review_app/engine/game_analyzer.dart';
import 'package:review_app/engine/move_tags.dart';
import 'package:review_app/engine/pgn_parser.dart';

/// The parsed game, so a test can look at the reply as well as the move.
GameLadder _ladder(String pgn) => parsePgn(pgn);

/// Builds a move for the ply at [index], with the engine fields filled in as the
/// notes do not read them.
AnalyzedMove _move(
  GameLadder ladder,
  int index, {
  String bestMoveSan = '',
  String bestMoveUci = '',
  int cpl = 0,
}) {
  final ply = ladder.plies[index];
  return AnalyzedMove(
    ply: ply,
    san: ply.san,
    isWhite: ply.isWhite,
    uci: ply.uci,
    evalBefore: 0,
    evalAfter: 0,
    cpl: cpl,
    verdict: MoveVerdict.good,
    bestMoveSan: bestMoveSan,
    bestMoveUci: bestMoveUci,
    pv: '',
    depth: 12,
    reachedDepth: 12,
  );
}

List<MoveNote> _notes(
  String pgn,
  int index, {
  String who = 'you',
  String bestMoveSan = '',
  String bestMoveUci = '',
  int cpl = 0,
}) {
  final ladder = _ladder(pgn);
  final hasReply = index + 1 < ladder.plies.length;
  return notesFor(
    _move(
      ladder,
      index,
      bestMoveSan: bestMoveSan,
      bestMoveUci: bestMoveUci,
      cpl: cpl,
    ),
    who: who,
    next: hasReply ? _move(ladder, index + 1) : null,
  );
}

Set<MoveNoteKind> _kinds(List<MoveNote> notes) =>
    notes.map((note) => note.kind).toSet();

String _labelOf(List<MoveNote> notes, MoveNoteKind kind) =>
    notes.firstWhere((note) => note.kind == kind).label;

const _castled = '''
[Event "Test"]
[SetUp "1"]
[FEN "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1"]

1. O-O d6
''';

const _castledLong = '''
[Event "Test"]
[SetUp "1"]
[FEN "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1"]

1. O-O-O Nc6
''';

const _freePawn = '''
[Event "Test"]
[SetUp "1"]
[FEN "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1"]

1. exd5 Kd7
''';

const _defendedPawn = '''
[Event "Test"]
[SetUp "1"]
[FEN "3rk3/8/8/3p4/4P3/8/8/4K3 w - - 0 1"]

1. exd5 Rxd5
''';

const _hungPiece = '''
[Event "Test"]
[SetUp "1"]
[FEN "4k3/8/8/8/8/2n5/4P3/4K3 w - - 0 1"]

1. Kf1 Nxe2
''';

const _wrongCapture = '''
[Event "Test"]
[SetUp "1"]
[FEN "5k2/5ppp/8/8/8/8/8/5RK1 w - - 0 1"]

1. Rxf7+ Kxf7
''';

const _freePieceMissed = '''
[Event "Test"]
[SetUp "1"]
[FEN "4k3/8/8/3n4/8/8/8/1N2K3 w - - 0 1"]

1. Nc3 Kd7
''';

const _defendedPieceMissed = '''
[Event "Test"]
[SetUp "1"]
[FEN "3rk3/8/8/3n4/8/8/8/1N2K3 w - - 0 1"]

1. Nc3 Rd6
''';

const _check = '''
[Event "Test"]
[SetUp "1"]
[FEN "4k3/8/8/8/8/8/8/R3K3 w - - 0 1"]

1. Ra8+ Ke7
''';

const _promotion = '''
[Event "Test"]
[SetUp "1"]
[FEN "8/P6k/8/8/8/8/8/K7 w - - 0 1"]

1. a8=Q+ Kh6
''';

void main() {
  test('calls out kingside castling', () {
    final notes = _notes(_castled, 0);
    expect(_kinds(notes), contains(MoveNoteKind.castlingShort));
    expect(_labelOf(notes, MoveNoteKind.castlingShort), 'Kingside castle');
    expect(notes.first.sentence, contains('king side'));
  });

  test('calls out queenside castling', () {
    final notes = _notes(_castledLong, 0);
    expect(_kinds(notes), contains(MoveNoteKind.castlingLong));
    expect(notes.first.sentence, contains('queen side'));
  });

  test('a pawn that nothing recaptures is a free pawn', () {
    final notes = _notes(_freePawn, 0);
    expect(_kinds(notes), contains(MoveNoteKind.freePawnTaken));
    expect(_labelOf(notes, MoveNoteKind.freePawnTaken), 'Took a free pawn');
  });

  test('a pawn the opponent recaptures is not free', () {
    // The rook on d8 answers exd5 with Rxd5, so nothing was won.
    final notes = _notes(_defendedPawn, 0);
    expect(_kinds(notes), isNot(contains(MoveNoteKind.freePawnTaken)));
    expect(
      _kinds(notes),
      contains(MoveNoteKind.wrongCapture),
      reason: 'the capture was handed straight back',
    );
  });

  test('a piece left on an attacked square is called lost', () {
    final notes = _notes(_hungPiece, 0);
    expect(_kinds(notes), contains(MoveNoteKind.pieceLost));
    expect(_labelOf(notes, MoveNoteKind.pieceLost), 'Lost a pawn');
    expect(
      notes.firstWhere((note) => note.kind == MoveNoteKind.pieceLost).sentence,
      contains('left a pawn'),
    );
  });

  test('a capture the king simply takes back is the wrong capture', () {
    final notes = _notes(_wrongCapture, 0);
    expect(_kinds(notes), contains(MoveNoteKind.wrongCapture));
    expect(
      notes
          .firstWhere((note) => note.kind == MoveNoteKind.wrongCapture)
          .sentence,
      contains('gave it back'),
    );
  });

  test('notes a free piece the engine wanted and the move did not take', () {
    final notes = _notes(
      _freePieceMissed,
      0,
      bestMoveSan: 'Nxd5',
      bestMoveUci: 'c3d5',
      cpl: 120,
    );
    expect(_kinds(notes), contains(MoveNoteKind.freePieceMissed));
    expect(
      notes
          .firstWhere((note) => note.kind == MoveNoteKind.freePieceMissed)
          .sentence,
      contains('Nxd5'),
    );
  });

  test('a defended piece that was available is not called free', () {
    // The rook on d8 covers d5, so Nxd5 would not have been free.
    final notes = _notes(
      _defendedPieceMissed,
      0,
      bestMoveSan: 'Nxd5',
      bestMoveUci: 'c3d5',
      cpl: 120,
    );
    expect(_kinds(notes), isNot(contains(MoveNoteKind.freePieceMissed)));
  });

  test('a small loss the move did not cause is not called a lost piece', () {
    // cpl is irrelevant here: only a capture reply can cost material.
    final notes = _notes(_freePieceMissed, 0, cpl: 300);
    expect(_kinds(notes), isNot(contains(MoveNoteKind.pieceLost)));
  });

  test('check and promotion are noted', () {
    expect(_kinds(_notes(_check, 0)), contains(MoveNoteKind.check));
    expect(_kinds(_notes(_promotion, 0)), contains(MoveNoteKind.promoted));
  });

  test('the wording follows the name of the side that played the move', () {
    final asOpponent = _notes(_hungPiece, 0, who: 'opponent');
    expect(
      asOpponent
          .firstWhere((note) => note.kind == MoveNoteKind.pieceLost)
          .sentence,
      contains('opponent left a pawn'),
    );
  });
}
