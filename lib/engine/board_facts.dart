/// Small board queries used to work out what actually happened on a move.
///
/// The analyzer already knows the evaluation either side of a move, but that
/// only says a move was bad. To say *why* — a pawn that was hanging, a capture
/// that should not have been taken — the board itself has to be read.
library;

/// Piece values in pawns.
const Map<String, int> pieceValue = {
  'p': 1,
  'n': 3,
  'b': 3,
  'r': 5,
  'q': 9,
  'k': 0,
};

/// The squares of a board, keyed by name such as `e4`.
Map<String, String> parseFenBoard(String fen) {
  final board = <String, String>{};
  final rows = fen.split(' ').first.split('/');
  if (rows.length != 8) return board;
  for (var row = 0; row < 8; row++) {
    var file = 0;
    for (final character in rows[row].split('')) {
      final digits = int.tryParse(character);
      if (digits != null) {
        file += digits;
        continue;
      }
      if (file > 7) continue;
      board['${'abcdefgh'[file]}${8 - row}'] = character;
      file++;
    }
  }
  return board;
}

/// White's and Black's total material in pawns.
({int white, int black}) materialCount(Map<String, String> board) {
  var white = 0;
  var black = 0;
  for (final piece in board.values) {
    final value = pieceValue[piece.toLowerCase()] ?? 0;
    if (piece == piece.toUpperCase()) {
      white += value;
    } else {
      black += value;
    }
  }
  return (white: white, black: black);
}

int _file(String square) => square.codeUnitAt(0) - 97;

/// Zero based row, so 0 is the first rank and 7 is the eighth.
int _rank(String square) => square.codeUnitAt(1) - 49;

bool _onBoard(int file, int rank) =>
    file >= 0 && file < 8 && rank >= 0 && rank < 8;

String _name(int file, int rank) => '${'abcdefgh'[file]}${rank + 1}';

/// Whether any piece of [byWhite] attacks [square].
///
/// This answers "is this piece safe", which is what a hanging piece is: it only
/// has to be attacked once to be a problem, and it has to be defended to not be
/// one.
bool isSquareAttacked(Map<String, String> board, String square, bool byWhite) {
  final targetFile = _file(square);
  final targetRank = _rank(square);

  bool isEnemy(String? piece) {
    if (piece == null) return false;
    return (piece == piece.toUpperCase()) == byWhite;
  }

  // Pawns capture forwards only, so a white pawn on rank r attacks r + 1.
  final pawnRank = byWhite ? targetRank - 1 : targetRank + 1;
  if (_onBoard(targetFile - 1, pawnRank) &&
      isEnemy(board[_name(targetFile - 1, pawnRank)]) &&
      board[_name(targetFile - 1, pawnRank)]!.toLowerCase() == 'p') {
    return true;
  }
  if (_onBoard(targetFile + 1, pawnRank) &&
      isEnemy(board[_name(targetFile + 1, pawnRank)]) &&
      board[_name(targetFile + 1, pawnRank)]!.toLowerCase() == 'p') {
    return true;
  }

  for (final offset in const [
    [1, 2],
    [2, 1],
    [2, -1],
    [1, -2],
    [-1, -2],
    [-2, -1],
    [-2, 1],
    [-1, 2],
  ]) {
    final file = targetFile + offset[0];
    final rank = targetRank + offset[1];
    if (!_onBoard(file, rank)) continue;
    final piece = board[_name(file, rank)];
    if (isEnemy(piece) && piece!.toLowerCase() == 'n') return true;
  }

  for (final offset in const [
    [1, 0],
    [-1, 0],
    [0, 1],
    [0, -1],
  ]) {
    if (_slides(board, square, byWhite, isEnemy, offset, const ['r', 'q'])) {
      return true;
    }
  }
  for (final offset in const [
    [1, 1],
    [1, -1],
    [-1, 1],
    [-1, -1],
  ]) {
    if (_slides(board, square, byWhite, isEnemy, offset, const ['b', 'q'])) {
      return true;
    }
  }

  // The king only needs to be next door.
  for (var file = targetFile - 1; file <= targetFile + 1; file++) {
    for (var rank = targetRank - 1; rank <= targetRank + 1; rank++) {
      if (!_onBoard(file, rank) || (file == targetFile && rank == targetRank)) {
        continue;
      }
      final piece = board[_name(file, rank)];
      if (isEnemy(piece) && piece!.toLowerCase() == 'k') return true;
    }
  }
  return false;
}

/// Walks a line from [square] and reports whether an enemy slider of one of
/// [kinds] can see it.
bool _slides(
  Map<String, String> board,
  String square,
  bool byWhite,
  bool Function(String?) isEnemy,
  List<int> step,
  List<String> kinds,
) {
  var file = _file(square) + step[0];
  var rank = _rank(square) + step[1];
  while (_onBoard(file, rank)) {
    final name = _name(file, rank);
    final piece = board[name];
    if (piece != null) {
      return isEnemy(piece) && kinds.contains(piece.toLowerCase());
    }
    file += step[0];
    rank += step[1];
  }
  return false;
}

/// The piece standing on [square], or null when the square is empty.
String? pieceOn(Map<String, String> board, String square) => board[square];

/// Whether the piece on [square] is attacked by the other side and has no
/// defender of its own, which is what makes a piece hanging.
bool isHanging(Map<String, String> board, String square) {
  final piece = pieceOn(board, square);
  if (piece == null) return false;
  final byWhite = piece == piece.toUpperCase();
  if (!isSquareAttacked(board, square, !byWhite)) return false;
  return !isSquareAttacked(board, square, byWhite);
}
