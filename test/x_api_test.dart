import 'package:flutter_test/flutter_test.dart';
import 'package:gather/extractors.dart';
import 'package:gather/instagram_api.dart';
import 'package:gather/models.dart';
import 'package:gather/native_bridge.dart';
import 'package:gather/platform_providers.dart';
import 'package:gather/x_api.dart';

class FixtureXTransport implements XHttpTransport {
  FixtureXTransport({
    this.getResponses = const [],
    this.postResponses = const [],
  });

  final List<XHttpResponse> getResponses;
  final List<XHttpResponse> postResponses;
  final requested = <Uri>[];
  final headers = <Map<String, String>>[];
  final posted = <Uri>[];

  @override
  Future<XHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requested.add(uri);
    this.headers.add(headers);
    return getResponses.removeAt(0);
  }

  @override
  Future<XHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    posted.add(uri);
    return postResponses.removeAt(0);
  }
}

class NoPublicFallbackTransport implements PublicTransport {
  int calls = 0;

  @override
  Future<PageData> get(Uri uri) async {
    calls++;
    throw StateError('X public fallback must not run after API denial');
  }

  @override
  Future<int?> size(String url, PlatformKind platform) async => null;
}

XSession session({String id = '42', String token = 'x-access-token'}) =>
    XSession(
      accessToken: token,
      refreshToken: 'TEST_REFRESH_TOKEN',
      expiresAt: DateTime.utc(2099),
      userId: id,
      username: 'gather_user',
      name: 'Gather User',
    );

Map<String, dynamic> postResponse({
  String authorId = '7',
  bool protected = false,
  String type = 'photo',
}) => {
  'data': {
    'id': '1234567890123456789',
    'text': 'A saved post',
    'author_id': authorId,
    'attachments': {
      'media_keys': ['m1', if (type == 'photo') 'm2'],
    },
  },
  'includes': {
    'users': [
      {
        'id': authorId,
        'name': 'Post Owner',
        'username': 'post_owner',
        'protected': protected,
      },
    ],
    'media': [
      {
        'media_key': 'm1',
        'type': type,
        'url': type == 'photo'
            ? 'https://pbs.twimg.com/media/one.jpg'
            : 'https://video.twimg.com/ext_tw_video/one.mp4',
        'preview_image_url': 'https://pbs.twimg.com/media/preview.jpg',
      },
      if (type == 'photo')
        {
          'media_key': 'm2',
          'type': 'photo',
          'url': 'https://pbs.twimg.com/media/two.jpg',
        },
    ],
  },
};

class FakeBridge extends NativeBridge {
  String? saved;
  @override
  Future<String?> readProviderAuth(String provider) async => saved;
  @override
  Future<void> writeProviderAuth(String provider, String value) async =>
      saved = value;
  @override
  Future<void> clearProviderAuth(String provider) async => saved = null;
}

void main() {
  group('Official X post lookup', () {
    test(
      'maps returned carousel media and marks API-authorized protected access',
      () async {
        final transport = FixtureXTransport(
          getResponses: [XHttpResponse(200, postResponse(protected: true))],
        );
        final auth = XAuthService(
          bridge: FakeBridge(),
          transport: transport,
          authServer: Uri.parse('https://oauth.example.test'),
        )..session = session();
        final post = await XPostApi(auth: auth, transport: transport).getPost(
          PostLink.parse('https://x.com/post_owner/status/1234567890123456789'),
        );

        expect(post.access, PostAccess.authorizedPrivate);
        expect(post.accountName, 'Post Owner');
        expect(post.mediaItems.map((item) => item.type), ['image', 'image']);
        expect(
          post.mediaItems.first.qualities.single.url,
          'https://pbs.twimg.com/media/one.jpg',
        );
        expect(transport.requested.single.host, 'api.x.com');
        expect(
          transport.requested.single.path,
          '/2/tweets/1234567890123456789',
        );
        expect(
          transport.requested.single.queryParameters['expansions'],
          'author_id,attachments.media_keys',
        );
        expect(
          transport.headers.single['Authorization'],
          'Bearer x-access-token',
        );
      },
    );

    test(
      'distinguishes own-account media and uses an official video URL only when returned',
      () async {
        final transport = FixtureXTransport(
          getResponses: [
            XHttpResponse(200, postResponse(authorId: '42', type: 'video')),
          ],
        );
        final auth = XAuthService(
          bridge: FakeBridge(),
          transport: transport,
          authServer: Uri.parse('https://oauth.example.test'),
        )..session = session();
        final post = await XPostApi(auth: auth, transport: transport).getPost(
          PostLink.parse('https://x.com/i/web/status/1234567890123456789'),
        );

        expect(post.access, PostAccess.ownAccount);
        expect(post.mediaItems.single.type, 'video');
        expect(
          post.mediaItems.single.url,
          'https://video.twimg.com/ext_tw_video/one.mp4',
        );
      },
    );

    test(
      'refreshes expired X credentials once before retrying official lookup',
      () async {
        final transport = FixtureXTransport(
          getResponses: [
            const XHttpResponse(401, {}),
            XHttpResponse(200, postResponse(authorId: '42')),
          ],
          postResponses: [
            const XHttpResponse(200, {
              'accessToken': 'TEST_ACCESS_TOKEN',
              'refreshToken': 'TEST_REFRESH_TOKEN',
              'expiresIn': 3600,
            }),
          ],
        );
        final bridge = FakeBridge();
        final auth = XAuthService(
          bridge: bridge,
          transport: transport,
          authServer: Uri.parse('https://oauth.example.test'),
        )..session = session();
        final post = await XPostApi(auth: auth, transport: transport).getPost(
          PostLink.parse('https://x.com/i/web/status/1234567890123456789'),
        );

        expect(post.access, PostAccess.ownAccount);
        expect(transport.posted.single.path, '/v1/x/oauth/refresh');
        expect(auth.session!.accessToken, 'TEST_ACCESS_TOKEN');
        expect(auth.session!.refreshToken, 'TEST_REFRESH_TOKEN');
      },
    );

    test(
      'maps rate limits, missing posts, and access denial to clear errors',
      () async {
        final link = PostLink.parse(
          'https://x.com/i/web/status/1234567890123456789',
        );
        for (final item in [
          (429, 'x_rate_limited'),
          (404, 'x_post_deleted'),
          (403, 'x_access_denied'),
        ]) {
          final transport = FixtureXTransport(
            getResponses: [XHttpResponse(item.$1, {})],
          );
          final auth = XAuthService(
            bridge: FakeBridge(),
            transport: transport,
            authServer: Uri.parse('https://oauth.example.test'),
          )..session = session();
          await expectLater(
            XPostApi(auth: auth, transport: transport).getPost(link),
            throwsA(
              isA<GatherException>().having(
                (error) => error.code,
                'code',
                item.$2,
              ),
            ),
          );
        }
      },
    );

    test(
      'does not try public extraction after the authenticated API denies a post',
      () async {
        final transport = FixtureXTransport(
          getResponses: [const XHttpResponse(403, {})],
        );
        final publicTransport = NoPublicFallbackTransport();
        final auth = XAuthService(
          bridge: FakeBridge(),
          transport: transport,
          authServer: Uri.parse('https://oauth.example.test'),
        )..session = session();
        final provider = XProvider(
          extractors: ExtractorRegistry(transport: publicTransport),
          bridge: FakeBridge(),
          auth: auth,
          api: XPostApi(auth: auth, transport: transport),
        );

        await expectLater(
          provider.resolveSharedUrl(
            'https://x.com/i/web/status/1234567890123456789',
          ),
          throwsA(
            isA<GatherException>().having(
              (error) => error.code,
              'code',
              'x_access_denied',
            ),
          ),
        );
        expect(publicTransport.calls, 0);
        expect(provider.capabilities.canAccessAuthorizedPrivateMedia, isFalse);
      },
    );

    test(
      'only marks protected access after the official API returns that post',
      () async {
        final transport = FixtureXTransport(
          getResponses: [XHttpResponse(200, postResponse(protected: true))],
        );
        final auth = XAuthService(
          bridge: FakeBridge(),
          transport: transport,
          authServer: Uri.parse('https://oauth.example.test'),
        )..session = session();
        final provider = XProvider(
          extractors: ExtractorRegistry(transport: NoPublicFallbackTransport()),
          bridge: FakeBridge(),
          auth: auth,
          api: XPostApi(auth: auth, transport: transport),
        );
        expect(provider.capabilities.canAccessAuthorizedPrivateMedia, isFalse);
        await provider.resolveSharedUrl(
          'https://x.com/i/web/status/1234567890123456789',
        );
        expect(provider.capabilities.canAccessAuthorizedPrivateMedia, isTrue);
        await auth.disconnect(revoke: false);
        expect(provider.capabilities.canAccessAuthorizedPrivateMedia, isFalse);
      },
    );
  });

  group('Provider capabilities and URL routing', () {
    test(
      'detects Facebook and YouTube video URL formats without claiming download support',
      () {
        final facebook = PostLink.parse(
          'https://www.facebook.com/watch/?v=123456789',
        );
        final youtube = PostLink.parse('https://youtu.be/abcdefghijk?t=12');
        expect(facebook.platform, PlatformKind.facebook);
        expect(youtube.platform, PlatformKind.youtube);

        final bridge = FakeBridge();
        final providers = PlatformProviderRegistry(
          extractors: ExtractorRegistry(transport: NoPublicFallbackTransport()),
          bridge: bridge,
          instagramAuth: InstagramAuthService(
            bridge: bridge,
            authServer: Uri.parse('https://oauth.example.test'),
          ),
          xAuth: XAuthService(
            bridge: bridge,
            authServer: Uri.parse('https://oauth.example.test'),
          ),
        );
        expect(
          providers
              .providerFor(PlatformKind.facebook)
              .capabilities
              .canDownloadVideos,
          isFalse,
        );
        expect(
          providers
              .providerFor(PlatformKind.youtube)
              .capabilities
              .canDownloadVideos,
          isFalse,
        );
        expect(
          providers
              .providerFor(PlatformKind.instagram)
              .capabilities
              .canAccessAuthorizedPrivateMedia,
          isFalse,
        );
        expect(
          providers
              .providerFor(PlatformKind.x)
              .capabilities
              .canAccessAuthorizedPrivateMedia,
          isFalse,
        );
      },
    );
  });
}
