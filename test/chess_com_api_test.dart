import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:review_app/api/chess_com_api.dart';

void main() {
  late List<Uri> requested;

  setUp(() {
    requested = <Uri>[];
  });

  http.Client clientReturning(Object body, {int status = 200}) {
    return MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
    });
  }

  test('archives returns newest month first', () async {
    final api = ChessComApi(
      client: clientReturning({
        'archives': [
          'https://api.chess.com/pub/player/x/games/2026/08',
          'https://api.chess.com/pub/player/x/games/2026/09',
        ],
      }),
    );

    expect(await api.archives('x'), [
      'https://api.chess.com/pub/player/x/games/2026/09',
      'https://api.chess.com/pub/player/x/games/2026/08',
    ]);
    expect(requested.single.path, '/pub/player/x/games/archives');
  });

  test('gamesInArchive sorts by end_time descending', () async {
    final api = ChessComApi(
      client: clientReturning({
        'games': [
          {
            'url': 'https://www.chess.com/game/daily/1',
            'end_time': '1700000000',
            'white': {'username': 'x', 'result': 'win'},
            'black': {'username': 'y', 'result': 'loss'},
          },
          {
            'url': 'https://www.chess.com/game/daily/2',
            'end_time': '1800000000',
            'white': {'username': 'x', 'result': 'draw'},
            'black': {'username': 'y', 'result': 'draw'},
          },
        ],
      }),
    );

    final games = await api.gamesInArchive(
      'https://api.chess.com/pub/player/x/games/2026/09',
    );

    expect(games.map((game) => game.url), [
      'https://www.chess.com/game/daily/2',
      'https://www.chess.com/game/daily/1',
    ]);
  });

  test('latestGames loads the most recent archive', () async {
    final api = ChessComApi(
      client: clientReturning({
        'archives': ['https://a/2026/09'],
      }),
    );

    expect(await api.latestGames('x'), isEmpty);
  });

  test('throws a friendly error on 404', () {
    final api = ChessComApi(client: clientReturning({}, status: 404));

    expect(
      () => api.archives('nobody'),
      throwsA(
        isA<ChessComException>().having(
          (error) => error.message,
          'message',
          'Player not found on chess.com.',
        ),
      ),
    );
  });

  test('throws a friendly error on 429', () {
    final api = ChessComApi(client: clientReturning({}, status: 429));

    expect(() => api.archives('x'), throwsA(isA<ChessComException>()));
  });

  test('archives is empty when the payload has no games', () async {
    final api = ChessComApi(client: clientReturning({'games': <dynamic>[]}));

    expect(await api.archives('x'), isEmpty);
  });
}
