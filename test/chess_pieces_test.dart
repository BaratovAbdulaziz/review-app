import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/ui/chess_pieces.dart';

Future<ChessPieceSet> loadSet(WidgetTester tester) async {
  await tester.pumpWidget(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.shrink(),
    ),
  );
  return ChessPieceSet.load(tester.element(find.byType(SizedBox)));
}

void main() {
  testWidgets('parses all twelve bundled pieces', (tester) async {
    final set = await loadSet(tester);

    for (final letter in ['P', 'N', 'B', 'R', 'Q', 'K']) {
      expect(set[letter], isNotNull, reason: 'white $letter is bundled');
      expect(set[letter]!.shapes, isNotEmpty);
      expect(set[letter]!.isWhite, isTrue);
    }
    for (final letter in ['p', 'n', 'b', 'r', 'q', 'k']) {
      expect(set[letter], isNotNull, reason: 'black $letter is bundled');
      expect(set[letter]!.shapes, isNotEmpty);
      expect(set[letter]!.isWhite, isFalse);
    }
  });

  testWidgets('keeps the artwork inside its viewBox', (tester) async {
    final set = await loadSet(tester);

    for (final letter in [
      'P',
      'N',
      'B',
      'R',
      'Q',
      'K',
      'p',
      'n',
      'b',
      'r',
      'q',
      'k',
    ]) {
      final art = set[letter]!;
      final ink = art.ink;
      // The set is free to pick its own coordinate space, so the frame is read
      // from the artwork rather than assumed here.
      expect(ink.left, greaterThanOrEqualTo(0), reason: letter);
      expect(ink.top, greaterThanOrEqualTo(0), reason: letter);
      expect(ink.right, lessThanOrEqualTo(art.canvas.width), reason: letter);
      expect(ink.bottom, lessThanOrEqualTo(art.canvas.height), reason: letter);
      expect(ink.width, greaterThan(5), reason: letter);
      expect(ink.height, greaterThan(5), reason: letter);
      expect(art.canvas.width, art.canvas.height, reason: letter);
    }
  });

  testWidgets('reads the colours the artwork asks for', (tester) async {
    final set = await loadSet(tester);

    // The board picks how to make each piece readable from its colour, so the
    // two sets have to come out light and dark however the artwork spells it:
    // `fill`, an inherited value, or a `style` declaration.
    double luminance(Color colour) =>
        0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b;

    for (final letter in ['P', 'N', 'B', 'R', 'Q', 'K']) {
      final shapes = set[letter]!.shapes;
      expect(
        shapes.map((shape) => luminance(shape.fill!)),
        contains(greaterThan(0.6)),
        reason: 'white $letter has a light body',
      );
      expect(
        shapes.map((shape) => luminance(shape.fill!)),
        contains(lessThan(0.4)),
        reason: 'white $letter keeps dark detail',
      );
    }

    for (final letter in ['p', 'n', 'b', 'r', 'q', 'k']) {
      final shapes = set[letter]!.shapes;
      expect(
        shapes.map((shape) => luminance(shape.fill!)),
        contains(lessThan(0.4)),
        reason: 'black $letter has a dark body',
      );
      expect(
        shapes.map((shape) => luminance(shape.fill!)),
        contains(greaterThan(0.6)),
        reason: 'black $letter keeps light detail',
      );
    }
  });

  testWidgets('reads every piece as more than one shape', (tester) async {
    // Each piece is drawn as a body and at least one detail shape, so a parser
    // that only looks at the first path would drop half the artwork.
    final set = await loadSet(tester);
    for (final letter in [
      'P',
      'N',
      'B',
      'R',
      'Q',
      'K',
      'p',
      'n',
      'b',
      'r',
      'q',
      'k',
    ]) {
      expect(set[letter]!.shapes.length, greaterThan(1), reason: letter);
    }
  });

  testWidgets('keeps the set\'s own size hierarchy', (tester) async {
    final set = await loadSet(tester);

    double extent(String letter) => set[letter]!.inkExtent;

    // A pawn is a small shape next to a queen in the same set, and the shared
    // scale the board derives from maxInkExtent depends on that ordering.
    expect(extent('P'), lessThan(extent('Q')));
    expect(extent('p'), lessThan(extent('q')));
    // The hierarchy is not a rounding accident: the gap has to be wide enough
    // that the two pieces are told apart at a glance on a small board.
    expect(extent('Q') / extent('P'), greaterThan(1.1));
    expect(set.maxInkExtent, greaterThanOrEqualTo(extent('Q')));
    // The shared scale is derived from the largest piece, so it has to fit in
    // the frame the set declared.
    expect(set.maxInkExtent, lessThanOrEqualTo(set['Q']!.canvas.longestSide));
  });
}
