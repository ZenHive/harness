import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:harness_flutter_fixture/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final screen = GlobalKey();
  final screenshots = <String, String>{};
  binding.reportData = {'screenshots': screenshots};

  Future<void> capture(String name) async {
    final boundary = screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    screenshots[name] = base64Encode(bytes!.buffer.asUint8List());
    image.dispose();
  }

  testWidgets('increment flow on device', (tester) async {
    await tester.pumpWidget(RepaintBoundary(key: screen, child: const FixtureApp()));
    await tester.pumpAndSettle();
    expect(find.text('Count: 0'), findsOneWidget);
    await capture('before');
    await tester.tap(find.text('Increment'));
    await tester.pumpAndSettle();
    expect(find.text('Count: 1'), findsOneWidget);
    await capture('after');
  });
}
