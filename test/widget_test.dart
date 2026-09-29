import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/main.dart';

void main() {
  testWidgets('renders a blank white window', (WidgetTester tester) async {
    await tester.pumpWidget(const ReviewApp());

    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.white,
    );
  });
}
