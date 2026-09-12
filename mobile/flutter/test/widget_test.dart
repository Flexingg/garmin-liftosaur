import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/main.dart';

void main() {
  testWidgets('companion screen shows capture controls and the debug tab',
      (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    expect(find.text('Liftosaur Companion'), findsOneWidget);
    // Capture tab: manual BLE controls
    expect(find.text('Start BLE link'), findsOneWidget);
    expect(find.text('Stop advertising'), findsOneWidget);
    expect(find.text('Upload set'), findsOneWidget);
    // backend URL is prefilled with the docs/02 dev base URL
    expect(find.text(kDefaultBackend), findsOneWidget);
    // The debug tab exists — this is the manual-control surface.
    expect(find.text('Debug'), findsOneWidget);
  });

  testWidgets('debug tab exposes manual link controls', (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();

    expect(find.text('Start advertising'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Inject test frame'), findsOneWidget);
    expect(find.text('log (newest first)'), findsOneWidget);
  });

  testWidgets('injecting a test frame updates the live buffer', (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inject test frame'));
    await tester.pump();

    // The buffer summary now reports stats, proving the frame went through the
    // same path a real BLE frame takes. ('peak=' is unique to that summary -
    // 'n=20' also appears in the session summary and in the log line.)
    expect(find.textContaining('peak='), findsOneWidget);
    expect(find.textContaining('m/s²'), findsWidgets);
  });

  testWidgets('uploading before capturing reports the blocker', (tester) async {
    await tester.pumpWidget(const LiftosaurApp());
    await tester.pump();

    await tester.tap(find.text('Upload set'));
    await tester.pump();

    expect(find.textContaining('not ready'), findsOneWidget);
  });
}
