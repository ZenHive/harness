import 'package:flutter_test/flutter_test.dart';
import 'package:harness_flutter_fixture/main.dart';

void main() {
  testWidgets('counter starts at zero and increments', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.text('Count: 0'), findsOneWidget);
    await tester.tap(find.text('Increment'));
    await tester.pumpAndSettle();
    expect(find.text('Count: 1'), findsOneWidget);
    expect(find.text('Count: 0'), findsNothing);
  });
}
