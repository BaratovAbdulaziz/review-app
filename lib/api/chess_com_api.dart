import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chess_game.dart';

class ChessComException implements Exception {
  const ChessComException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ChessComApi {
  ChessComApi({http.Client? client}) : _client = client ?? http.Client();

  static const baseUrl = 'https://api.chess.com/pub';
  static const _timeout = Duration(seconds: 20);

  final http.Client _client;

  /// Archive URLs for [username], newest first.
  Future<List<String>> archives(String username) async {
    final json = await _get('$baseUrl/player/$username/games/archives');
    final list = json['archives'];
    if (list is! List) return const [];
    final urls = list.whereType<String>().toList();
    return urls.reversed.toList();
  }

  Future<List<ChessGame>> gamesInArchive(String archiveUrl) async {
    final json = await _get(archiveUrl);
    final list = json['games'];
    if (list is! List) return const [];
    final games =
        list.whereType<Map<String, dynamic>>().map(ChessGame.fromJson).toList()
          ..sort((a, b) {
            final aTime = a.endTime?.millisecondsSinceEpoch ?? 0;
            final bTime = b.endTime?.millisecondsSinceEpoch ?? 0;
            return bTime.compareTo(aTime);
          });
    return games;
  }

  /// Games from the most recent month that contains any.
  Future<List<ChessGame>> latestGames(String username) async {
    final archiveUrls = await archives(username);
    if (archiveUrls.isEmpty) return const [];
    return gamesInArchive(archiveUrls.first);
  }

  Future<Map<String, dynamic>> _get(String url) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(url),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'review_app/1.0 (dart; chess.com public data)',
            },
          )
          .timeout(_timeout);
    } on Exception {
      throw const ChessComException(
        'Could not reach chess.com. Check your connection.',
      );
    }

    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        throw const ChessComException('Player not found on chess.com.');
      case 429:
        throw const ChessComException(
          'chess.com rate limit hit. Try again in a moment.',
        );
      default:
        throw ChessComException(
          'chess.com returned an error (${response.statusCode}).',
        );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ChessComException('Unexpected response from chess.com.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ChessComException('Unexpected response from chess.com.');
    }
    return decoded;
  }
}
