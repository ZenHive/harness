import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_flutter_fixture/main.dart';

void main() {
  testWidgets('screen color panel matches approved pixels', (tester) async {
    // The committed golden is the 100 logical-pixel panel at 1x. Flutter's
    // default test surface is 800x600 at 3x, which would capture 300x300.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const FixtureApp());
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('color-panel')),
      matchesGoldenFile('goldens/panel.png'),
    );
  });
}
