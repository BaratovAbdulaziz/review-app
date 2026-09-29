enum GameOutcome { win, loss, draw, unknown }

class ChessPlayer {
  const ChessPlayer({
    required this.username,
    required this.result,
    this.rating,
  });

  final String username;
  final String result;
  final int? rating;

  factory ChessPlayer.fromJson(Map<String, dynamic> json) {
    return ChessPlayer(
      username: (json['username'] as String?) ?? 'Unknown',
      result: (json['result'] as String?) ?? '',
      rating: _asInt(json['rating']),
    );
  }
}

class ChessGame {
  const ChessGame({
    required this.url,
    required this.white,
    required this.black,
    required this.rated,
    this.timeClass = '',
    this.timeControl = '',
    this.opening,
    this.title,
    this.endTime,
    this.pgn,
  });

  final String url;
  final ChessPlayer white;
  final ChessPlayer black;
  final bool rated;
  final String timeClass;
  final String timeControl;
  final String? opening;
  final String? title;
  final DateTime? endTime;
  final String? pgn;

  factory ChessGame.fromJson(Map<String, dynamic> json) {
    return ChessGame(
      url: (json['url'] as String?) ?? '',
      white: ChessPlayer.fromJson(_asMap(json['white'])),
      black: ChessPlayer.fromJson(_asMap(json['black'])),
      rated: _asBool(json['rated']),
      timeClass: (json['time_class'] as String?) ?? '',
      timeControl: (json['time_control'] as String?) ?? '',
      opening: _opening(json),
      title:
          (json['name'] as String?) ??
          (json['tournament'] as String?) ??
          (json['match'] as String?) ??
          (json['tournament_url'] as String?) ??
          (json['match_url'] as String?),
      endTime: _asDateTime(json['end_time']),
      pgn: json['pgn'] as String?,
    );
  }

  bool isWhite(String username) =>
      white.username.toLowerCase() == username.toLowerCase();

  ChessPlayer playerFor(String username) => isWhite(username) ? white : black;

  ChessPlayer opponentOf(String username) => isWhite(username) ? black : white;

  GameOutcome outcomeFor(String username) =>
      _outcomeForResult(playerFor(username).result);

  static String? _opening(Map<String, dynamic> json) {
    final direct = json['opening'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    final eco = json['eco'] as String?;
    if (eco == null || eco.isEmpty) return null;
    final slug = Uri.parse(eco).pathSegments.last;
    if (slug.isEmpty) return null;
    return Uri.decodeComponent(slug).replaceAll('-', ' ');
  }

  static GameOutcome _outcomeForResult(String result) {
    const wins = {'win', 'threecheck_win'};
    const losses = {
      'loss',
      'resigned',
      'checkmated',
      'timeout',
      'time forfeit',
      'abandoned',
      'threecheck_loss',
      'kingofthehill_opponentwon',
    };
    const draws = {
      'draw',
      'agreed',
      'stalemate',
      'repetition',
      'insufficient',
      '50move',
      'threecheck',
      'kingofthehill',
    };
    final value = result.toLowerCase();
    if (wins.contains(value)) return GameOutcome.win;
    if (losses.contains(value)) return GameOutcome.loss;
    if (draws.contains(value)) return GameOutcome.draw;
    return GameOutcome.unknown;
  }
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}

DateTime? _asDateTime(Object? value) {
  final seconds = _asInt(value);
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).toLocal();
}
