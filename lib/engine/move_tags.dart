import 'board_facts.dart';
import 'game_analyzer.dart';

/// What a note says about the move's tone, which is all the interface needs to
/// colour it. The text carries the meaning; the tone is a summary of it.
enum MoveNoteTone { good, bad, neutral }

/// The kind of thing that happened on a move.
enum MoveNoteKind {
  castlingShort,
  castlingLong,
  promoted,
  check,
  checkmate,
  capturedPawn,
  capturedPiece,
  freePawnTaken,
  freePieceTaken,
  wrongCapture,
  pieceLost,
  freePawnMissed,
  freePieceMissed,
}

/// One thing worth saying about a move.
///
/// These are read off the board rather than the evaluation, so "you took a free
/// piece" is a statement about the position and not about a number.
class MoveNote {
  const MoveNote({
    required this.kind,
    required this.label,
    required this.sentence,
    required this.tone,
  });

  final MoveNoteKind kind;

  /// Short enough for a chip beside the move.
  final String label;

  /// A full sentence, using [who] as the name of the side that played the move.
  final String sentence;

  final MoveNoteTone tone;

  /// Whether the note is something the player would be glad to read.
  bool get isGood => tone == MoveNoteTone.good;
}

/// Everything worth saying about one move, in the order it should be read.
///
/// [who] is the name for the side that played it, e.g. `you` or `opponent`, and
/// [next] is the opponent's reply, which is needed to see whether a capture was
/// simply given back. Nothing here is a judgement: the quality of the move is
/// the verdict's job, and these notes only describe what happened.
List<MoveNote> notesFor(
  AnalyzedMove move, {
  required String who,
  AnalyzedMove? next,
}) {
  final notes = <MoveNote>[];
  final san = move.san;
  final before = parseFenBoard(move.ply.fenBefore);
  final after = parseFenBoard(move.ply.fenAfter);

  if (san == 'O-O') {
    notes.add(
      MoveNote(
        kind: MoveNoteKind.castlingShort,
        label: 'Kingside castle',
        sentence:
            '$who castled on the king side, putting the king behind the '
            'pawns.',
        tone: MoveNoteTone.good,
      ),
    );
  } else if (san == 'O-O-O') {
    notes.add(
      MoveNote(
        kind: MoveNoteKind.castlingLong,
        label: 'Queenside castle',
        sentence:
            '$who castled on the queen side, putting the rook on an open '
            'file.',
        tone: MoveNoteTone.good,
      ),
    );
  }

  if (san.contains('=')) {
    notes.add(
      MoveNote(
        kind: MoveNoteKind.promoted,
        label: 'Promoted',
        sentence: '$who promoted on move ${move.moveNumber}.',
        tone: MoveNoteTone.good,
      ),
    );
  }

  // Material won or lost by the move itself, in pawns, from the mover's side.
  final delta = _materialDelta(before, after, move.isWhite);
  final target = _destination(move.uci);
  final captured = target == null
      ? null
      : pieceOn(before, target)?.toLowerCase();
  final capturedValue = captured == null ? 0 : (pieceValue[captured] ?? 0);

  // What the opponent's reply took. A side cannot lose material on its own
  // move, so this is the only way to know a capture was simply given back or a
  // piece was left hanging.
  final givenBack = _materialGivenAway(move, next);

  if (delta > 0) {
    // A capture is free when the opponent cannot take it straight back, which
    // is judged on the position after the move: the capturing piece is on the
    // square by then, so nothing counts as defending it except real defenders.
    final wasFree =
        target != null && !isSquareAttacked(after, target, !move.isWhite);
    // En passant takes a pawn that is not standing on the target square, so the
    // material change is the reliable signal and the captured piece is only a
    // bonus that gives the name.
    final aPawn = captured == null ? delta == 1 : capturedValue == 1;
    final name = captured == null
        ? (aPawn ? 'pawn' : 'piece')
        : _pieceName(captured);
    if (givenBack > 0) {
      notes.add(
        MoveNote(
          kind: MoveNoteKind.wrongCapture,
          label: 'Wrong capture',
          sentence:
              '$who took on ${move.san} on move ${move.moveNumber} and '
              'immediately gave it back, so the piece was not really there to '
              'take.',
          tone: MoveNoteTone.bad,
        ),
      );
    } else if (wasFree) {
      notes.add(
        MoveNote(
          kind: aPawn
              ? MoveNoteKind.freePawnTaken
              : MoveNoteKind.freePieceTaken,
          label: aPawn ? 'Took a free pawn' : 'Took a free piece',
          sentence: aPawn
              ? '$who took a pawn on move ${move.moveNumber} that nothing was '
                    'defending.'
              : '$who took a free $name on move ${move.moveNumber} that nothing '
                    'was defending.',
          tone: MoveNoteTone.good,
        ),
      );
    } else {
      notes.add(
        MoveNote(
          kind: aPawn ? MoveNoteKind.capturedPawn : MoveNoteKind.capturedPiece,
          label: aPawn ? 'Took a pawn' : 'Took a piece',
          sentence: aPawn
              ? '$who won a pawn with ${move.san} on move ${move.moveNumber}.'
              : '$who won a $name with ${move.san} on move '
                    '${move.moveNumber}.',
          tone: MoveNoteTone.good,
        ),
      );
    }
  } else if (givenBack > 0) {
    notes.add(
      MoveNote(
        kind: MoveNoteKind.pieceLost,
        label: givenBack == 1 ? 'Lost a pawn' : 'Lost a piece',
        sentence: givenBack == 1
            ? '$who left a pawn on move ${move.moveNumber} that the opponent '
                  'simply took.'
            : '$who left a piece on move ${move.moveNumber} that the opponent '
                  'simply took.',
        tone: MoveNoteTone.bad,
      ),
    );
  }

  // A capture the engine wanted that was not taken is usually a piece the other
  // side forgot to defend, so it is worth calling a free piece rather than just
  // a better move.
  final missed = _missedFreeCapture(move, before);
  if (missed != null && delta <= 0) {
    notes.add(
      MoveNote(
        kind: missed == 1
            ? MoveNoteKind.freePawnMissed
            : MoveNoteKind.freePieceMissed,
        label: missed == 1 ? 'Left a free pawn' : 'Left a free piece',
        sentence: missed == 1
            ? '$who could have taken a pawn with ${move.bestMoveSan} on move '
                  '${move.moveNumber} and left it there.'
            : '$who could have won a piece with ${move.bestMoveSan} on move '
                  '${move.moveNumber} and left it hanging.',
        tone: MoveNoteTone.bad,
      ),
    );
  }

  if (san.contains('#')) {
    notes.add(
      const MoveNote(
        kind: MoveNoteKind.checkmate,
        label: 'Checkmate',
        sentence: 'and it is mate.',
        tone: MoveNoteTone.good,
      ),
    );
  } else if (san.contains('+')) {
    notes.add(
      const MoveNote(
        kind: MoveNoteKind.check,
        label: 'Check',
        sentence: 'It comes with check.',
        tone: MoveNoteTone.neutral,
      ),
    );
  }

  return notes;
}

/// How much material the move itself gained for the side that played it, in
/// pawns. Positive means material was won.
///
/// This is the change in the material *balance*, not the change in a count:
/// capturing a pawn leaves the capturing side with exactly as many pawns as it
/// started with, and only the opponent is down one.
int _materialDelta(
  Map<String, String> before,
  Map<String, String> after,
  bool isWhite,
) {
  final from = materialCount(before);
  final to = materialCount(after);
  final whiteGain = to.white - from.white;
  final blackGain = to.black - from.black;
  return isWhite ? whiteGain - blackGain : blackGain - whiteGain;
}

/// The square the move landed on, e.g. `e4` from `e2e4`.
String? _destination(String uci) =>
    uci.length == 4 ? uci.substring(2, 4) : null;

/// The value in pawns of the piece the engine wanted to take on this move, when
/// that capture was available and the move played did not take it.
///
/// Returns null when the best move was not a capture, or when the mover already
/// took something: both are covered by other notes.
int? _missedFreeCapture(AnalyzedMove move, Map<String, String> before) {
  final best = move.bestMoveUci;
  if (best.length != 4) return null;
  final bestSan = move.bestMoveSan;
  if (!bestSan.contains('x')) return null;
  if (move.san.contains('x')) return null;
  // Only worth mentioning when it actually cost something.
  if (move.cpl < 40) return null;
  final target = _destination(best);
  if (target == null) return null;
  final piece = pieceOn(before, target);
  if (piece == null) return null;
  // Only a piece the opponent had not defended is a free one.
  if (isSquareAttacked(before, target, !move.isWhite)) return null;
  return pieceValue[piece.toLowerCase()] ?? 0;
}

/// Material the move gained for the side that played it, in pawns. Positive
/// means material was won, and a mover can never lose any on their own move.
int materialWonBy(AnalyzedMove move) => _materialDelta(
  parseFenBoard(move.ply.fenBefore),
  parseFenBoard(move.ply.fenAfter),
  move.isWhite,
);

/// Material [reply] took off the side that played [move], in pawns. Zero when
/// there is no reply or the reply was not a capture.
int materialLostTo(AnalyzedMove move, AnalyzedMove? reply) =>
    _materialGivenAway(move, reply);

/// How much material the opponent's reply took off this move, in pawns, from
/// the point of view of the side that played [move].
///
/// Returns 0 when there is no reply or the reply was not a capture.
int _materialGivenAway(AnalyzedMove move, AnalyzedMove? reply) {
  if (reply == null) return 0;
  if (!reply.san.contains('x')) return 0;
  final gained = _materialDelta(
    parseFenBoard(move.ply.fenAfter),
    parseFenBoard(reply.ply.fenAfter),
    !move.isWhite,
  );
  return gained > 0 ? gained : 0;
}

String _pieceName(String letter) => switch (letter.toLowerCase()) {
  'p' => 'pawn',
  'n' => 'knight',
  'b' => 'bishop',
  'r' => 'rook',
  'q' => 'queen',
  'k' => 'king',
  _ => 'piece',
};
