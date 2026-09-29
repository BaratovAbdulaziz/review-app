import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/ui/chess_board_view.dart';

/// Renders the board once and writes it to [path], so the arrows and pieces can
/// be looked at rather than only reasoned about.
///
/// This is a developer tool, not a test: it always passes and only produces a
/// file. Run it with `flutter test tool/render_board.dart`.
void main() {
  testWidgets('render the board', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ColoredBox(
          color: Color(0xFFFFFFFF),
          child: Center(
            child: SizedBox(
              width: 480,
              height: 480,
              child: RepaintBoundary(
                child: ChessBoardView(
                  fen:
                      'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/'
                      'RNBQK2R w KQkq - 0 1',
                  lastMove: 'f3f5',
                  bestMove: 'c4e6',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The piece SVGs load asynchronously; let them finish before capturing.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final file = File('build/board-preview.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!);
    // ignore: avoid_print
    print('wrote ${file.path} (${bytes.length} bytes)');
  });
}
