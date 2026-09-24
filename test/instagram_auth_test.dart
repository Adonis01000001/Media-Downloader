import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather/instagram_api.dart';
import 'package:gather/native_bridge.dart';

class InstagramAuthFixtureTransport implements InstagramHttpTransport {
  final requests = <({Uri uri, String body})>[];

  @override
  Future<InstagramHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) => throw UnimplementedError();

  @override
  Future<InstagramHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    requests.add((uri: uri, body: body));
    if (uri.path.endsWith('/oauth/start')) {
      return InstagramHttpResponse(201, {
        'attemptId': 'A' * 43,
        'authorizationUrl':
            'https://www.instagram.com/oauth/authorize?response_type=code&scope=instagram_business_basic',
      });
    }
    if (uri.path.endsWith('/oauth/poll')) {
      return InstagramHttpResponse(200, {
        'status': 'ready',
        'session': {
          'accessToken': 'TEST_ACCESS_TOKEN',
          'expiresAt': DateTime.now()
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
          'userId': 'instagram-user-1',
          'username': 'my_professional_account',
          'apiVersion': 'v26.0',
        },
      });
    }
    throw StateError('Unexpected OAuth route: ${uri.path}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = NativeBridge.channel;
  late String? encryptedState;
  late String? openedAuthorizationUrl;

  setUp(() {
    encryptedState = null;
    openedAuthorizationUrl = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'readInstagramAuth':
              return encryptedState;
            case 'writeInstagramAuth':
              encryptedState = (call.arguments as Map)['value'] as String;
              return null;
            case 'clearInstagramAuth':
              encryptedState = null;
              return null;
            case 'openInstagramAuthorization':
              openedAuthorizationUrl = (call.arguments as Map)['url'] as String;
              return null;
            case 'takeInstagramAuthCallbacks':
              return <String>[];
            default:
              throw MissingPluginException('Unexpected method ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'OAuth handoff keeps its verifier private and sign-out clears local state',
    () async {
      final bridge = NativeBridge();
      final transport = InstagramAuthFixtureTransport();
      final auth = InstagramAuthService(
        bridge: bridge,
        transport: transport,
        authServer: Uri.parse('https://oauth.example.test'),
      );

      await auth.beginConnect();
      expect(
        openedAuthorizationUrl,
        contains('scope=instagram_business_basic'),
      );
      final persisted = jsonDecode(encryptedState!) as Map<String, dynamic>;
      final secret = persisted['handoffSecret'] as String;
      expect(secret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(openedAuthorizationUrl, isNot(contains(secret)));

      await auth.handleOAuthCallback(
        'gather://instagram-auth?attempt_id=${'A' * 43}',
      );
      expect(transport.requests, hasLength(1));

      await auth.handleOAuthCallback('gather://instagram-auth');
      expect(transport.requests, hasLength(2));
      final pollBody =
          jsonDecode(transport.requests.last.body) as Map<String, dynamic>;
      expect(pollBody['attemptId'], 'A' * 43);
      expect(pollBody['handoffSecret'], secret);
      expect(auth.session?.username, 'my_professional_account');
      expect(jsonDecode(encryptedState!)['handoffSecret'], isNull);

      await auth.disconnect();
      expect(auth.session, isNull);
      expect(encryptedState, isNull);
      bridge.dispose();
    },
  );
}
