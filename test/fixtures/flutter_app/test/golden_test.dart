import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_flutter_fixture/main.dart';

void main() {
  testWidgets('screen color panel matches approved pixels', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('color-panel')),
      matchesGoldenFile('goldens/panel.png'),
    );
  });
}
