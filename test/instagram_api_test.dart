import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather/instagram_api.dart';
import 'package:gather/models.dart';

class InstagramFixtureTransport implements InstagramHttpTransport {
  InstagramFixtureTransport(this.responses);

  final List<InstagramHttpResponse> responses;
  final requested = <Uri>[];
  final headers = <Map<String, String>>[];

  @override
  Future<InstagramHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requested.add(uri);
    this.headers.add(headers);
    return responses.removeAt(0);
  }

  @override
  Future<InstagramHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) => throw UnimplementedError();
}

class OfflineInstagramTransport implements InstagramHttpTransport {
  @override
  Future<InstagramHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async => throw const SocketException('offline');

  @override
  Future<InstagramHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) => throw UnimplementedError();
}

InstagramHttpResponse page(List<Map<String, dynamic>> rows, {String? after}) =>
    InstagramHttpResponse(200, {
      'data': rows,
      if (after != null)
        'paging': {
          'cursors': {'after': after},
        },
    });

InstagramSession account() => InstagramSession(
  accessToken: 'TEST_ACCESS_TOKEN',
  expiresAt: DateTime.utc(2027, 1, 1),
  userId: '123',
  username: 'gather_owner',
  apiVersion: 'v26.0',
);

void main() {
  group('Instagram Professional account media API', () {
    test(
      'matches only the exact API-listed post and returns carousel items',
      () async {
        final transport = InstagramFixtureTransport([
          page([
            {
              'permalink': 'https://www.instagram.com/p/OTHER/',
              'media_type': 'IMAGE',
              'media_url': 'https://scontent.cdninstagram.com/other.jpg',
            },
            {
              'permalink': 'https://www.instagram.com/p/AbC_123/',
              'media_type': 'CAROUSEL_ALBUM',
              'caption': 'My own post',
              'username': 'gather_owner',
              'children': {
                'data': [
                  {
                    'media_type': 'IMAGE',
                    'media_url': 'https://scontent.cdninstagram.com/one.jpg',
                  },
                  {
                    'media_type': 'VIDEO',
                    'media_url': 'https://scontent.cdninstagram.com/two.mp4',
                    'thumbnail_url':
                        'https://scontent.cdninstagram.com/two.jpg',
                  },
                ],
              },
            },
          ]),
        ]);

        final post = await InstagramMediaApi(transport: transport)
            .resolveOwnedPost(
              PostLink.parse('https://instagram.com/p/AbC_123/?igsh=tracking'),
              account(),
            );

        expect(post.accountName, 'gather_owner');
        expect(post.title, 'My own post');
        expect(post.mediaItems.map((item) => item.type), ['image', 'video']);
        expect(
          post.mediaItems.last.thumbnail,
          'https://scontent.cdninstagram.com/two.jpg',
        );
        expect(transport.requested.single.host, 'graph.instagram.com');
        expect(transport.requested.single.path, '/v26.0/me/media');
        expect(transport.headers.single['Authorization'], 'Bearer TEST_ACCESS_TOKEN');
      },
    );

    test(
      'paginates own media and reports when a link is not in that account',
      () async {
        final transport = InstagramFixtureTransport([
          page([], after: 'cursor-1'),
          page([
            {
              'permalink': 'https://www.instagram.com/reel/REEL_1/',
              'media_type': 'VIDEO',
              'media_url': 'https://scontent.cdninstagram.com/reel.mp4',
            },
          ]),
        ]);

        final post = await InstagramMediaApi(transport: transport)
            .resolveOwnedPost(
              PostLink.parse('https://www.instagram.com/reel/REEL_1/'),
              account(),
            );

        expect(post.mediaItems.single.type, 'video');
        expect(transport.requested, hasLength(2));
        expect(transport.requested.last.queryParameters['after'], 'cursor-1');

        final notFound = InstagramFixtureTransport([page([])]);
        await expectLater(
          InstagramMediaApi(transport: notFound).resolveOwnedPost(
            PostLink.parse('https://www.instagram.com/p/NOT_MINE/'),
            account(),
          ),
          throwsA(
            isA<GatherException>().having(
              (error) => error.code,
              'code',
              'instagram_owned_media_not_found',
            ),
          ),
        );
      },
    );

    test('rejects revoked authorization and untrusted CDN media', () async {
      final unauthorized = InstagramFixtureTransport([
        const InstagramHttpResponse(401, {
          'error': {'code': 190},
        }),
      ]);
      await expectLater(
        InstagramMediaApi(transport: unauthorized).resolveOwnedPost(
          PostLink.parse('https://www.instagram.com/p/AbC_123/'),
          account(),
        ),
        throwsA(
          isA<GatherException>().having(
            (error) => error.code,
            'code',
            'instagram_reauth',
          ),
        ),
      );

      final untrusted = InstagramFixtureTransport([
        page([
          {
            'permalink': 'https://www.instagram.com/p/AbC_123/',
            'media_type': 'IMAGE',
            'media_url': 'https://cdninstagram.com.attacker.test/image.jpg',
          },
        ]),
      ]);
      await expectLater(
        InstagramMediaApi(transport: untrusted).resolveOwnedPost(
          PostLink.parse('https://www.instagram.com/p/AbC_123/'),
          account(),
        ),
        throwsA(
          isA<GatherException>().having(
            (error) => error.code,
            'code',
            'instagram_media_unavailable',
          ),
        ),
      );
    });

    test('classifies rate limits and network failures for users', () async {
      for (final response in [
        const InstagramHttpResponse(429, <String, dynamic>{}),
        const InstagramHttpResponse(400, {
          'error': {'code': 4},
        }),
      ]) {
        await expectLater(
          InstagramMediaApi(
            transport: InstagramFixtureTransport([response]),
          ).resolveOwnedPost(
            PostLink.parse('https://www.instagram.com/p/AbC_123/'),
            account(),
          ),
          throwsA(
            isA<GatherException>().having(
              (error) => error.code,
              'code',
              'instagram_rate_limited',
            ),
          ),
        );
      }

      await expectLater(
        InstagramMediaApi(
          transport: OfflineInstagramTransport(),
        ).resolveOwnedPost(
          PostLink.parse('https://www.instagram.com/p/AbC_123/'),
          account(),
        ),
        throwsA(
          isA<GatherException>().having(
            (error) => error.code,
            'code',
            'instagram_network',
          ),
        ),
      );
    });
  });
}
