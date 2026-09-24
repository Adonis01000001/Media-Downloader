import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather/extractors.dart';
import 'package:gather/main.dart';
import 'package:gather/models.dart';
import 'package:gather/native_bridge.dart';

class SizeTransport implements PublicTransport {
  @override
  Future<PageData> get(Uri uri) => throw UnimplementedError();
  @override
  Future<int?> size(String url, PlatformKind platform) async => 1024 * 1024;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('preview schedules the selected quality and renamed file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method == 'download') {
            requests.add(call.arguments as Map);
            return {'duplicate': false, 'id': 'job-1'};
          }
          if (call.method == 'getState') {
            return {
              'settings': {'accepted': true},
              'jobs': [],
            };
          }
          return null;
        });
    final bridge = NativeBridge();
    addTearDown(() {
      bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null);
    });
    final post = Post(
      platform: PlatformKind.x,
      source: Uri.parse('https://x.com/i/web/status/123'),
      id: '123',
      title: 'A public video',
      accountName: 'JohnDoe',
      mediaItems: const [
        MediaItem(
          type: 'video',
          qualities: [
            Quality('https://video.twimg.com/high.mp4', '1080p'),
            Quality('https://video.twimg.com/low.mp4', '480p'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewScreen(
          post: post,
          bridge: bridge,
          transport: SizeTransport(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(DropdownButtonFormField<int>),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('480p').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'JohnDoe - A public video',
    );
    await tester.enterText(find.byType(TextField), 'my_favorite');
    await tester.tap(find.text('Download all · 1'));
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(requests.single['url'], 'https://video.twimg.com/low.mp4');
    expect(requests.single['name'], 'my_favorite');
    expect(requests.single['source'], 'https://x.com/i/web/status/123');
    expect(find.textContaining('1 item queued.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
