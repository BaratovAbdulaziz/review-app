import 'package:chess/chess.dart' show Chess, Color, PieceType;

import 'game_analyzer.dart';
import 'pgn_parser.dart';
import 'stockfish_engine.dart';

/// What the engine found in the position a move led to.
///
/// This is a second, shallow search of the position after the move, which is
/// where the words about a move come from: the engine is asked what the opponent
/// does next, and the board is replayed to see what that reply actually wins.
/// Nothing here is guessed from the first search.
class MoveConsequence {
  const MoveConsequence({
    required this.replySan,
    this.materialSwing = 0,
    this.givesCheck = false,
  });

  /// The opponent's best reply, e.g. `cxd5+`.
  final String replySan;

  /// What the reply wins for the side that played it, in pawns: 1 for a pawn,
  /// 3 for a minor piece, 5 for a rook, 9 for a queen. Negative when the reply
  /// hangs a piece of its own.
  final int materialSwing;

  final bool givesCheck;

  bool get winsMaterial => materialSwing > 0;
}

/// Searches the position after the move at [plyIndex] and reads the opponent's
/// best reply off it, along with what that reply wins on the board.
///
/// Returns null when the engine has nothing to say, so a move without a
/// consequence is left unexplained rather than guessed at.
Future<MoveConsequence?> probeConsequence(
  ChessEngine engine,
  GameLadder ladder,
  int plyIndex, {
  int depth = 4,
  Duration? maxTime,
}) async {
  final plies = ladder.plies;
  if (plyIndex < 0 || plyIndex >= plies.length) return null;
  final played = [
    for (final earlier in plies.take(plyIndex)) earlier.uci,
    plies[plyIndex].uci,
  ];
  final EngineResult result;
  try {
    result = await engine.analyse(
      fen: ladder.startFen,
      moves: played,
      depth: depth,
      multiPv: 3,
      maxTime: maxTime,
    );
  } on EngineException {
    return null;
  }
  final line = result.lines.first;
  if (line.pv.isEmpty) return null;
  final reply = _replyAfter(ladder.startFen, played, line.pv.first);
  if (reply == null) return null;
  return MoveConsequence(
    replySan: reply.san,
    materialSwing: reply.materialSwing,
    givesCheck: reply.san.endsWith('+') || reply.san.endsWith('#'),
  );
}

/// Searches the position after every move that gave something away, and reports
/// what the opponent's best reply wins in each, keyed by ply.
///
/// Only the moves that were actually wrong are searched: an explanation of a
/// good move has nothing to add, and a second search of every ply would double
/// the cost of a review. The replies are one ply deep, so a few at a time is
/// enough to keep the engine busy.
Future<Map<int, MoveConsequence>> probeConsequences({
  required ChessEngine engine,
  required GameLadder ladder,
  required List<AnalyzedMove> moves,
  int depth = 4,
  int concurrency = 4,
  Duration? maxTime,
  void Function(int completed, int total)? onProgress,
}) async {
  final worthExplaining = <int>[
    for (final move in moves)
      if (_worthExplaining(move.verdict)) move.ply.index,
  ];
  final found = <int, MoveConsequence>{};
  if (worthExplaining.isEmpty) return found;

  var next = 0;
  var completed = 0;
  Future<void> worker() async {
    while (true) {
      final slot = next++;
      if (slot >= worthExplaining.length) return;
      final i = worthExplaining[slot];
      final consequence = await probeConsequence(
        engine,
        ladder,
        i,
        depth: depth,
        maxTime: maxTime,
      );
      if (consequence != null) found[i] = consequence;
      onProgress?.call(++completed, worthExplaining.length);
    }
  }

  final workers = concurrency.clamp(1, worthExplaining.length);
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  return found;
}

/// Whether a move gave enough away to be worth a second look.
bool _worthExplaining(MoveVerdict verdict) => switch (verdict) {
  MoveVerdict.inaccuracy || MoveVerdict.mistake || MoveVerdict.blunder => true,
  MoveVerdict.book ||
  MoveVerdict.wasLost ||
  MoveVerdict.decisive ||
  MoveVerdict.best ||
  MoveVerdict.good => false,
};

/// The opponent's reply, read off the replayed board.
class _Reply {
  const _Reply(this.san, this.materialSwing);

  final String san;
  final int materialSwing;
}

/// Replays the moves and applies [replyUci], naming it the way the game does.
///
/// The SAN comes from the board rather than from the parser's tables, because
/// the position after the last move of a game has no table entry. The material
/// is counted on the board rather than read out of the notation, so a reply
/// that takes a rook is reported as a rook, and a reply that hangs a piece of
/// its own is not counted as a win.
_Reply? _replyAfter(String startFen, List<String> moves, String replyUci) {
  final board = Chess();
  if (!board.load(startFen)) return null;
  for (final uci in moves) {
    if (!_apply(board, uci)) return null;
  }
  final before = _material(board);
  final replierIsWhite = board.turn == Color.WHITE;
  for (final candidate in board.generate_moves()) {
    if ('${candidate.fromAlgebraic}${candidate.toAlgebraic}' != replyUci) {
      continue;
    }
    final san = board.move_to_san(candidate);
    board.make_move(candidate);
    // Material is counted from White's side, so it is turned around here to
    // read as what the reply wins for the side that played it.
    final after = _material(board);
    return _Reply(san, replierIsWhite ? after - before : before - after);
  }
  return null;
}

/// Applies a uci move, returning false when it is not legal on the board.
bool _apply(Chess board, String uci) {
  if (uci.length < 4) return false;
  try {
    return board.move({'from': uci.substring(0, 2), 'to': uci.substring(2, 4)});
  } on Object {
    return false;
  }
}

/// What is on the board in pawns, from White's point of view.
int _material(Chess board) {
  var total = 0;
  for (final file in _files) {
    for (var rank = 1; rank <= 8; rank++) {
      final piece = board.get('$file$rank');
      if (piece == null) continue;
      final value = _value(piece.type);
      total += piece.color == Color.WHITE ? value : -value;
    }
  }
  return total;
}

const _files = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

/// The usual values: pawn 1, knight and bishop 3, rook 5, queen 9. The king is
/// worth nothing, because a king is never taken.
int _value(PieceType type) {
  if (type == PieceType.PAWN) return 1;
  if (type == PieceType.KNIGHT || type == PieceType.BISHOP) return 3;
  if (type == PieceType.ROOK) return 5;
  if (type == PieceType.QUEEN) return 9;
  // A king is never taken, so it is worth nothing here.
  return 0;
}

/// Writes out what happened on a move: what the engine wanted instead, how much
/// the move gave away, where the position ended up, and what the engine's reply
/// wins.
///
/// [playerName] is used instead of "White" or "Black" when the caller knows who
/// was playing, so the sentence can be about a person.
String explainMove(
  AnalyzedMove move, {
  MoveConsequence? consequence,
  String? playerName,
  String? opponentName,
}) {
  final who = playerName == null || playerName.isEmpty
      ? (move.isWhite ? 'White' : 'Black')
      : playerName;
  final against = opponentName == null || opponentName.isEmpty
      ? (move.isWhite ? 'Black' : 'White')
      : opponentName;
  final number = move.moveNumber;
  final text = switch (move.verdict) {
    MoveVerdict.book =>
      '$who played ${move.san} on move $number, which is still opening theory, '
          'so it is not scored.',
    MoveVerdict.wasLost => _lostAlready(move, who),
    MoveVerdict.decisive =>
      'The engine saw a forced result on move $number: $who played ${move.san}, '
          'and ${_standingClause(move, who)} either way, so it is not scored.',
    MoveVerdict.best =>
      "$who played ${move.san} on move $number, the engine's first choice."
          '${_swing(move)}',
    MoveVerdict.good =>
      "$who played ${move.san} on move $number and gave up only "
          '${_loss(move.cpl)}.${_bestInstead(move)}${_swing(move)}',
    MoveVerdict.inaccuracy =>
      "$who played ${move.san} on move $number and gave up ${_loss(move.cpl)}: "
          'an inaccuracy.${_bestInstead(move)}${_swing(move)}',
    MoveVerdict.mistake =>
      '$who made a mistake on move $number with ${move.san}, giving up '
          '${_loss(move.cpl)}.${_bestInstead(move)}${_swing(move)}',
    MoveVerdict.blunder =>
      '$who blundered on move $number with ${move.san}, throwing away '
          '${_loss(move.cpl)}.${_bestInstead(move)}${_swing(move)}',
  };
  return text +
      (consequence == null
          ? ''
          : _consequence(consequence, who: who, against: against)) +
      _truncation(move);
}

/// Short, speech-friendly version of [explainMove].
///
/// The written panel remains precise and complete. Speech uses one factual idea
/// at a time and expands notation into words, because letters such as `Nf3` are
/// inconsistent and unpleasant when read by a device voice.
String spokenMoveCommentary(AnalyzedMove move, {String? playerName}) {
  final who = playerName == null || playerName.isEmpty
      ? (move.isWhite ? 'White' : 'Black')
      : playerName;
  final intro = 'Move ${move.moveNumber}. $who played ${_spokenSan(move.san)}.';
  final line = switch (move.verdict) {
    MoveVerdict.book => '$intro Opening theory.',
    MoveVerdict.wasLost => '$intro The position was already difficult.',
    MoveVerdict.decisive => '$intro The result was already taking shape.',
    MoveVerdict.best => '$intro Best move.',
    MoveVerdict.good => '$intro Good move.',
    MoveVerdict.inaccuracy => '$intro Inaccuracy.',
    MoveVerdict.mistake => '$intro Mistake.',
    MoveVerdict.blunder => '$intro Blunder.',
  };
  return line;
}

/// Turns standard algebraic notation into the simple words a device voice
/// reads reliably. The full notation stays on screen; this only affects speech.
String _spokenSan(String san) {
  var notation = san.trim();
  if (notation.startsWith('O-O-O')) {
    return 'queenside castle${_spokenResult(notation)}';
  }
  if (notation.startsWith('O-O')) {
    return 'kingside castle${_spokenResult(notation)}';
  }

  final result = _spokenResult(notation);
  notation = notation.replaceFirst(RegExp(r'[+#]+$'), '');
  final promotion = RegExp(r'=([QRBN])').firstMatch(notation);
  notation = notation.replaceFirst(RegExp(r'=[QRBN]'), '');
  final destination = RegExp(r'[a-h][1-8]').allMatches(notation).lastOrNull;
  if (destination == null) return san;

  final piece = switch (notation[0]) {
    'K' => 'King',
    'Q' => 'Queen',
    'R' => 'Rook',
    'B' => 'Bishop',
    'N' => 'Knight',
    _ => 'Pawn',
  };
  final action = notation.contains('x') ? 'takes' : 'to';
  final promoted = promotion == null
      ? ''
      : ', promoting to ${switch (promotion.group(1)) {
          'Q' => 'queen',
          'R' => 'rook',
          'B' => 'bishop',
          _ => 'knight',
        }}';
  final square = destination.group(0)!;
  return '$piece $action ${square[0]} ${square[1]}$promoted$result';
}

String _spokenResult(String san) {
  if (san.endsWith('#')) return '. Checkmate';
  if (san.endsWith('+')) return '. Check';
  return '';
}

/// What the engine would have played instead, and whether that matters.
String _bestInstead(AnalyzedMove move) {
  if (move.bestMoveSan.isEmpty) return ' The engine had nothing better here.';
  if (move.isBestMove) {
    return ' ${move.bestMoveSan} is what the engine wanted, so the choice '
        'itself was right.';
  }
  return ' The engine wanted ${move.bestMoveSan} instead.';
}

/// How the move changed the mover's own position, said only when it moved.
String _swing(AnalyzedMove move) {
  final before = move.moverEvalBefore;
  final after = move.moverEvalAfter;
  if (before >= _wonCp && after < _wonCp) {
    return ' That gives up a won position.';
  }
  if (before <= -_wonCp && after > -_wonCp) {
    return ' That saves a lost position.';
  }
  if (before - after < 20) return ' ${_standingSentence(move)}';
  return ' That takes the position from ${_signed(before)} to ${_signed(after)}.';
}

/// Where the position stands, as a sentence, without a number when the engine
/// has a forced result rather than a centipawn score.
String _standingSentence(AnalyzedMove move) {
  if (move.moverEvalAfter >= _wonCp) return 'The position is won.';
  if (move.moverEvalAfter <= -_wonCp) return 'The position is lost.';
  return 'The position holds at ${_signed(move.moverEvalAfter)}.';
}

/// The same thing as a clause, for use in the middle of a sentence.
String _standingClause(AnalyzedMove move, String who) {
  if (move.moverEvalAfter >= _wonCp) return 'the position is won for $who';
  if (move.moverEvalAfter <= -_wonCp) return 'the position is lost for $who';
  return 'the position holds at ${_signed(move.moverEvalAfter)}';
}

/// The sentence for a move played from a position that was already lost.
String _lostAlready(AnalyzedMove move, String who) {
  if (move.moverEvalBefore >= _wonCp) {
    return '$who was already winning on move ${move.moveNumber}, so ${move.san} '
        'is played from a won position and is not scored.';
  }
  if (move.moverEvalBefore <= -_wonCp) {
    return '$who was already lost on move ${move.moveNumber}, so ${move.san} is '
        'played from a lost position and is not scored.';
  }
  return '$who was already ${_loss(move.moverEvalBefore.abs())} down on move '
      '${move.moveNumber}, so ${move.san} is played from a lost position and is '
      'not scored.';
}

/// The evaluation the analyzer clamps a forced result to, so a mate score is
/// never printed as a number of pawns.
final int _wonCp = clampEval(1500);

/// What a move gave away, in words. A loss past the clamp is the game itself,
/// not a number of pawns.
String _loss(int centipawns) {
  if (centipawns >= _wonCp) return 'the game';
  final pawns = (centipawns / 100).toStringAsFixed(1);
  return '$pawns ${pawns == '1.0' ? 'pawn' : 'pawns'}';
}

String _consequence(
  MoveConsequence consequence, {
  required String who,
  required String against,
}) {
  final check = consequence.givesCheck ? ' with check' : '';
  if (!consequence.winsMaterial) {
    return ' ${_answers(against)} ${consequence.replySan}$check, which is the '
        'move that holds the position together.';
  }
  return ' ${_answers(against)} ${consequence.replySan}, and that wins '
      '${_materialName(consequence.materialSwing)}$check, so ${_losesIt(who)}.';
}

/// "you" is not a third-person singular, so it takes its own verb forms rather
/// than the ones a name or "White"/"Black" would.
String _answers(String who) => who == 'you' ? 'you answer' : '$who answers';

String _losesIt(String who) => who == 'you' ? 'you lose it' : '$who loses it';

String _materialName(int pawns) {
  if (pawns >= 9) return 'a queen';
  if (pawns >= 5) return 'a rook';
  if (pawns >= 3) return 'a piece';
  return 'a pawn';
}

String _truncation(AnalyzedMove move) {
  if (!move.truncated) return '';
  return ' The search for this position ran out of time at depth '
      '${move.reachedDepth} instead of ${move.depth}, so the numbers for it are '
      'softer than the rest of the game.';
}

/// An evaluation with a sign, e.g. `+1.2` or `-0.4`.
String _signed(int centipawns) {
  final pawns = (centipawns.abs() / 100).toStringAsFixed(1);
  final sign = centipawns < 0 ? '-' : '+';
  return '$sign$pawns';
}
