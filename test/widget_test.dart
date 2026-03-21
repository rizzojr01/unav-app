import 'package:flutter_test/flutter_test.dart';

import 'package:unav_app/main.dart';

void main() {
  testWidgets('UNav app boots', (tester) async {
    await tester.pumpWidget(const UNavApp());

    expect(find.text('UNav Navigation'), findsNothing);
  });
}
