import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/main.dart';

void main() {
  testWidgets('companion screen renders capture + upload controls', (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    expect(find.text('Liftosaur Companion'), findsOneWidget);
    expect(find.text('Replay synthetic set'), findsOneWidget);
    expect(find.text('Upload set'), findsOneWidget);
    // backend URL field is prefilled with the docs/02 dev base URL
    expect(find.text(kDefaultBackend), findsOneWidget);
  });

  testWidgets('uploading before capturing reports the blocker', (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    await tester.tap(find.text('Upload set'));
    await tester.pump();

    expect(find.textContaining('not ready'), findsOneWidget);
  });
}
