import 'package:chess/chess.dart' show Chess;

/// One position along a game's move tree.
class Ply {
  const Ply({
    required this.index,
    required this.san,
    required this.uci,
    required this.isWhite,
    required this.fenBefore,
    required this.fenAfter,
  });

  /// Zero based ply index.
  final int index;

  /// The move as written in the PGN, e.g. `Nf3`.
  final String san;

  /// The same move in engine notation, e.g. `g1f3`.
  final String uci;

  final bool isWhite;
  final String fenBefore;
  final String fenAfter;

  /// One based move number.
  int get moveNumber => index ~/ 2 + 1;
}

class PgnParseException implements Exception {
  const PgnParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GameLadder {
  const GameLadder({
    required this.startFen,
    required this.plies,
    required this.sanByPly,
    required this.pgn,
    this.movesInPgn = 0,
  });

  /// FEN of the starting position (custom setups are preserved).
  final String startFen;

  final List<Ply> plies;

  /// uci -> san lookup for every position, used to render engine lines.
  final List<Map<String, String>> sanByPly;

  final String pgn;

  /// How many half moves the PGN claims to contain.
  final int movesInPgn;

  bool get isEmpty => plies.isEmpty;

  /// True when some moves could not be read, e.g. an unsupported notation.
  bool get isTruncated => plies.length < movesInPgn;

  int get missingPly => (movesInPgn - plies.length).clamp(0, movesInPgn);

  String fenAfterAllMoves() => plies.isEmpty ? startFen : plies.last.fenAfter;

  String sanForUci(int plyIndex, String uci) => sanByPly[plyIndex][uci] ?? uci;

  /// Renders a principal variation as SAN, clipped to the game's length.
  String pvToSan(int fromPly, List<String> pv) {
    final parts = <String>[];
    var ply = fromPly;
    for (final uci in pv) {
      if (ply >= sanByPly.length) break;
      final san = sanByPly[ply][uci];
      if (san == null) break;
      parts.add(san);
      ply++;
    }
    return parts.join(' ');
  }
}

/// Parses a PGN into per-ply FENs plus UCI moves for the engine.
///
/// Moves are replayed one by one so an unsupported or illegal move stops the
/// walk at a known point instead of silently dropping the rest of the game.
GameLadder? parsePgnOrNull(String pgn) {
  try {
    return parsePgn(pgn);
  } on PgnParseException {
    return null;
  }
}

GameLadder parsePgn(String pgn) {
  final text = pgn.trim();
  if (text.isEmpty) {
    throw const PgnParseException('This game has no PGN data.');
  }

  final headers = _parseHeaders(text);
  final startFen = headers['FEN'] ?? Chess.DEFAULT_POSITION;
  final chess = Chess();
  if (!chess.load(startFen)) {
    throw const PgnParseException(
      'This game starts from a position this app cannot replay, such as a '
      'Chess960 start.',
    );
  }

  final tokens = pgnSanMoves(text);
  if (tokens.isEmpty) {
    throw const PgnParseException('No moves could be read from this game.');
  }

  final plies = <Ply>[];
  final sanByPly = <Map<String, String>>[];

  for (var i = 0; i < tokens.length; i++) {
    final san = tokens[i];
    final legal = chess.moves({'verbose': true}).cast<Map>();
    final match = _matchSan(legal, san);
    if (match == null) break;

    final fenBefore = chess.fen;
    // Applying the generated SAN (not the PGN token) keeps promotions working:
    // the library can only apply a promotion from a SAN string, and it needs
    // the exact spelling including the check or mate suffix.
    if (!chess.move(match['san'] as String)) break;

    final move = chess.history.last.move;
    // Lower case matches what the engine sends, so the two can be compared.
    final uci =
        '${move.fromAlgebraic}${move.toAlgebraic}'
        '${move.promotion?.toLowerCase() ?? ''}';

    sanByPly.add({
      for (final option in legal)
        '${option['from']}${option['to']}${_promotionSuffix(option)}':
            option['san'] as String,
    });

    plies.add(
      Ply(
        index: i,
        san: match['san'] as String,
        uci: uci,
        isWhite: i.isEven,
        fenBefore: fenBefore,
        fenAfter: chess.fen,
      ),
    );
  }

  if (plies.isEmpty) {
    throw PgnParseException('Could not read the first move ($tokens.first).');
  }

  return GameLadder(
    startFen: startFen,
    plies: plies,
    sanByPly: sanByPly,
    pgn: text,
    movesInPgn: tokens.length,
  );
}

Map? _matchSan(List<Map> legal, String san) {
  final wanted = _stripDecoration(san);
  for (final move in legal) {
    if (_stripDecoration(move['san'] as String) == wanted) return move;
  }
  return null;
}

String _stripDecoration(String san) =>
    san.replaceAll(RegExp(r'[+#!?]+$'), '').trim();

Map<String, String> _parseHeaders(String pgn) {
  final headers = <String, String>{};
  for (final match in RegExp(
    r'^\s*\[([A-Za-z]+)\s+"([^"]*)"\]',
    multiLine: true,
  ).allMatches(pgn)) {
    headers[match.group(1)!.toUpperCase()] = match.group(2)!;
  }
  return headers;
}

String _promotionSuffix(Map move) {
  final flags = move['flags'] as String? ?? '';
  if (!flags.contains('p')) return '';
  final san = move['san'] as String;
  return san[san.length - 1].toLowerCase();
}

/// The half moves written in a PGN, ignoring headers, comments, variations,
/// annotations, move numbers and results.
List<String> pgnSanMoves(String pgn) {
  var text = pgn.replaceAll(RegExp(r'^\s*\[.*\]\s*$', multiLine: true), ' ');
  text = _stripBalanced(text, '{', '}');
  text = _stripBalanced(text, '(', ')');
  text = text
      .replaceAll(RegExp(r';[^\n]*'), ' ')
      .replaceAll(RegExp(r'\$\d+'), ' ')
      .replaceAll(RegExp(r'\d+\s*\.{1,3}'), ' ')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), ' ');
  return text
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
}

int countPgnMoves(String pgn) => pgnSanMoves(pgn).length;

String _stripBalanced(String input, String open, String close) {
  final result = StringBuffer();
  var depth = 0;
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (char == open) {
      depth++;
    } else if (char == close) {
      if (depth > 0) depth--;
    } else if (depth == 0) {
      result.write(char);
    }
  }
  return result.toString();
}
