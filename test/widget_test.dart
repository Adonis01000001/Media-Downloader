import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app.gather/native'), (
          call,
        ) async {
          if (call.method == 'getState') {
            return {
              'settings': {
                'darkMode': 'system',
                'wifiOnly': false,
                'folderName': 'Pictures/Gather · Movies/Gather',
                'folderUri': '',
                'accepted': true,
              },
              'jobs': [],
            };
          }
          if (call.method == 'takeShares') {
            return <String>[];
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.gather/native'),
          null,
        ),
  );

  testWidgets('home, history, settings and unsupported-link error are usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GatherApp());
    await tester.pumpAndSettle();
    expect(find.text('Worth keeping.\nEasy to save.'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).first,
      'https://evil.test/p/123',
    );
    await tester.scrollUntilVisible(
      find.text('Find media'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Find media'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Share an HTTPS post link'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Share an HTTPS post link'), findsOneWidget);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Your collection'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Wi-Fi only'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Wi-Fi only'), findsOneWidget);
    expect(find.text('Pictures/Gather · Movies/Gather'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
