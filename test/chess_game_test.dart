import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/models/chess_game.dart';

void main() {
  group('ChessGame.fromJson', () {
    test('parses a live archive game payload', () {
      final game = ChessGame.fromJson({
        'url': 'https://www.chess.com/game/live/183193101523',
        'time_control': '300',
        'end_time': '1788880073',
        'rated': 'True',
        'time_class': 'blitz',
        'eco':
            'https://www.chess.com/openings/Sicilian-Defense-Najdorf-Variation',
        'white': {'username': 'hikaru', 'rating': 2709, 'result': 'win'},
        'black': {'username': 'Someone', 'rating': 2400, 'result': 'resigned'},
      });

      expect(game.url, 'https://www.chess.com/game/live/183193101523');
      expect(game.timeClass, 'blitz');
      expect(game.timeControl, '300');
      expect(game.rated, isTrue);
      expect(game.opening, 'Sicilian Defense Najdorf Variation');
      expect(game.endTime, isNotNull);
      expect(game.isWhite('HiKaRu'), isTrue);
      expect(game.outcomeFor('hikaru'), GameOutcome.win);
      expect(game.outcomeFor('someone'), GameOutcome.loss);
    });

    test('tolerates string booleans and missing fields', () {
      final game = ChessGame.fromJson({
        'url': 'https://www.chess.com/game/daily/1',
        'rated': 'false',
        'end_time': 'not-a-number',
        'white': {'username': 'a'},
        'black': {'username': 'b', 'result': 'draw'},
      });

      expect(game.rated, isFalse);
      expect(game.endTime, isNull);
      expect(game.opening, isNull);
      expect(game.white.rating, isNull);
      expect(game.outcomeFor('a'), GameOutcome.unknown);
      expect(game.outcomeFor('b'), GameOutcome.draw);
    });

    test('falls back to unknown outcome for unexpected results', () {
      final game = ChessGame.fromJson({
        'url': '',
        'white': {'username': 'a', 'result': 'something_new'},
        'black': {'username': 'b', 'result': ''},
      });

      expect(game.outcomeFor('a'), GameOutcome.unknown);
      expect(game.outcomeFor('b'), GameOutcome.unknown);
    });
  });
}
