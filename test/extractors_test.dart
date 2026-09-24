import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather/extractors.dart';
import 'package:gather/models.dart';

class FixtureTransport implements PublicTransport {
  FixtureTransport(this.body, {this.finalUri});
  final String body;
  final Uri? finalUri;
  Uri? requested;
  @override
  Future<PageData> get(Uri uri) async {
    requested = uri;
    return PageData(finalUri ?? uri, body);
  }

  @override
  Future<int?> size(String url, PlatformKind platform) async => null;
}

String page(Object json) =>
    '<html><script type="application/json">${jsonEncode(json)}</script></html>';

void main() {
  group('Share URL boundary', () {
    test('finds a post in share text and removes tracking parameters', () {
      final link = PostLink.parse(
        'A good find https://www.instagram.com/p/AbC_123/?igsh=tracking',
      );
      expect(link.platform, PlatformKind.instagram);
      expect(link.uri.toString(), 'https://www.instagram.com/p/AbC_123/');
      expect(
        PostLink.parse(
          'https://twitter.com/user/status/12345?s=20',
        ).uri.toString(),
        'https://x.com/i/web/status/12345',
      );
    });
    test('rejects malicious, insecure, and unsupported links', () {
      for (final value in [
        'https://instagram.com.attacker.test/p/AbC/',
        'https://www.instagram.com@attacker.test/p/AbC/',
        'https://user:secret@www.instagram.com/p/AbC/',
        'http://www.instagram.com/p/AbC/',
        'https://www.instagram.com:444/p/AbC/',
        'https://www.instagram.com/private_profile/',
        'https://www.instagram.com/stories/user/123/',
        'https://127.0.0.1/p/AbC/',
      ]) {
        expect(
          () => PostLink.parse(value),
          throwsA(isA<GatherException>()),
          reason: value,
        );
      }
    });
    test('media must use HTTPS and the right platform CDN', () {
      expect(
        isMediaUrl(
          'https://scontent.cdninstagram.com/photo.jpg',
          PlatformKind.instagram,
        ),
        isTrue,
      );
      expect(
        isMediaUrl(
          'https://cdninstagram.com.evil.test/photo.jpg',
          PlatformKind.instagram,
        ),
        isFalse,
      );
      expect(
        isMediaUrl('https://i.pinimg.com/photo.jpg', PlatformKind.instagram),
        isFalse,
      );
      expect(
        isMediaUrl('http://pbs.twimg.com/media/photo.jpg', PlatformKind.x),
        isFalse,
      );
      expect(
        isMediaUrl(
          'https://user@pbs.twimg.com/media/photo.jpg',
          PlatformKind.x,
        ),
        isFalse,
      );
    });
    test('normalizes a TikTok video URL and short-link boundary', () {
      final link = PostLink.parse(
        'https://www.tiktok.com/@creator_name/video/7345678901234567890?is_from_webapp=1',
      );
      expect(link.platform, PlatformKind.tiktok);
      expect(
        link.uri.toString(),
        'https://www.tiktok.com/@creator_name/video/7345678901234567890',
      );
      expect(link.id, '7345678901234567890');
      expect(PostLink.parse('https://vm.tiktok.com/ZMshort/').id, 'short');
    });
    test('builds a safe account-title filename with graceful fallbacks', () {
      final post = Post(
        platform: PlatformKind.x,
        source: Uri.parse('https://x.com/i/web/status/1'),
        id: '1',
        accountName: 'John/Doe',
        title: 'My: Vacation* Photos',
        mediaItems: const [],
      );
      expect(suggestedFileName(post, 0), 'John_Doe - My_ Vacation_ Photos');
      final missing = Post(
        platform: PlatformKind.x,
        source: Uri.parse('https://x.com/i/web/status/2'),
        id: '2',
        title: '',
        mediaItems: const [],
      );
      expect(suggestedFileName(missing, 1), 'x_2_2');
    });
  });

  group('TikTok official oEmbed', () {
    test('maps preview metadata and disables file saving', () async {
      final transport = FixtureTransport(
        jsonEncode({
          'type': 'video',
          'title': 'A public TikTok video',
          'author_name': 'Creator',
          'author_url': 'https://www.tiktok.com/@creator',
          'thumbnail_url':
              'https://p16-sign-sg.tiktokcdn.com/obj/tos/example~tplv-noop.image',
          'thumbnail_width': 720,
          'thumbnail_height': 1280,
        }),
      );
      final post = await ExtractorRegistry(
        transport: transport,
      ).extract('https://www.tiktok.com/@creator/video/7345678901234567890');
      expect(post.platform, PlatformKind.tiktok);
      expect(post.title, 'A public TikTok video');
      expect(post.accountName, 'Creator');
      expect(post.mediaItems.single.downloadable, isFalse);
      expect(post.mediaItems.single.type, 'video');
      expect(post.mediaItems.single.qualities.single.width, 720);
      expect(
        transport.requested?.queryParameters['url'],
        'https://www.tiktok.com/@creator/video/7345678901234567890',
      );
    });

    test('rejects an untrusted preview host', () async {
      final transport = FixtureTransport(
        jsonEncode({
          'type': 'video',
          'title': 'Unsafe',
          'thumbnail_url': 'https://evil.example/thumb.jpg',
        }),
      );
      expect(
        () => ExtractorRegistry(
          transport: transport,
        ).extract('https://www.tiktok.com/@creator/video/7345678901234567890'),
        throwsA(
          isA<GatherException>().having(
            (error) => error.code,
            'code',
            'blocked',
          ),
        ),
      );
    });
  });

  group('X public embed', () {
    test('extracts all photos and sorted progressive MP4 qualities', () async {
      final transport = FixtureTransport(
        jsonEncode({
          'id_str': '12345',
          'text': 'A carousel',
          'user': {'protected': false, 'screen_name': 'alice'},
          'mediaDetails': [
            {
              'type': 'photo',
              'media_url_https': 'https://pbs.twimg.com/media/one.jpg',
              'original_info': {'width': 2048, 'height': 1365},
            },
            {
              'type': 'photo',
              'media_url_https': 'https://pbs.twimg.com/media/two.png',
            },
            {
              'type': 'video',
              'media_url_https': 'https://pbs.twimg.com/media/poster.jpg',
              'video_info': {
                'variants': [
                  {
                    'content_type': 'application/x-mpegURL',
                    'url': 'https://video.twimg.com/a.m3u8',
                  },
                  {
                    'content_type': 'video/mp4',
                    'bitrate': 256000,
                    'url': 'https://video.twimg.com/vid/320x180/a.mp4',
                  },
                  {
                    'content_type': 'video/mp4',
                    'bitrate': 2000000,
                    'url': 'https://video.twimg.com/vid/1280x720/a.mp4',
                  },
                ],
              },
            },
          ],
        }),
      );
      final post = await ExtractorRegistry(
        transport: transport,
      ).extract('https://x.com/user/status/12345');
      expect(post.postType, 'carousel');
      expect(post.accountName, 'alice');
      expect(post.mediaItems.length, 3);
      expect(
        post.mediaItems.first.url,
        'https://pbs.twimg.com/media/one?format=jpg&name=orig',
      );
      expect(post.mediaItems.last.qualities.length, 2);
      expect(post.mediaItems.last.qualities.first.height, 720);
      expect(transport.requested!.host, 'cdn.syndication.twimg.com');
      expect(transport.requested!.queryParameters['token'], isNotEmpty);
    });
    test('rejects private and mismatched post data', () async {
      for (final body in [
        {
          'id_str': '12345',
          'user': {'protected': true},
        },
        {
          'id_str': '999',
          'user': {'protected': false},
        },
        <String, dynamic>{},
      ]) {
        await expectLater(
          ExtractorRegistry(
            transport: FixtureTransport(jsonEncode(body)),
          ).extract('https://x.com/user/status/12345'),
          throwsA(
            isA<GatherException>().having(
              (e) => e.code,
              'code',
              'inaccessible',
            ),
          ),
        );
      }
    });
  });

  group('Instagram public page', () {
    test('extracts every item of a mixed carousel', () async {
      final transport = FixtureTransport(
        page({
          'data': {
            'xdt_shortcode_media': {
              'shortcode': 'AbC',
              '__typename': 'GraphSidecar',
              'owner': {'is_private': false, 'username': 'insta_user'},
              'edge_sidecar_to_children': {
                'edges': [
                  {
                    'node': {
                      'is_video': false,
                      'display_url':
                          'https://scontent.cdninstagram.com/one.jpg',
                      'display_resources': [
                        {
                          'src': 'https://scontent.cdninstagram.com/small.jpg',
                          'config_width': 640,
                          'config_height': 640,
                        },
                        {
                          'src': 'https://scontent.cdninstagram.com/one.jpg',
                          'config_width': 1080,
                          'config_height': 1080,
                        },
                      ],
                    },
                  },
                  {
                    'node': {
                      'is_video': true,
                      'display_url':
                          'https://scontent.cdninstagram.com/poster.jpg',
                      'video_url':
                          'https://scontent.cdninstagram.com/video.mp4',
                    },
                  },
                ],
              },
            },
          },
        }),
      );
      final post = await ExtractorRegistry(
        transport: transport,
      ).extract('https://www.instagram.com/p/AbC/');
      expect(post.mediaItems.length, 2);
      expect(post.accountName, 'insta_user');
      expect(post.mediaItems.first.qualities.first.width, 1080);
      expect(post.mediaItems.last.type, 'video');
    });
    test('supports the public media_type schema for reels', () async {
      final post = await ExtractorRegistry(
        transport: FixtureTransport(
          page({
            'code': 'Reel1',
            'media_type': 2,
            'image_versions2': {
              'candidates': [
                {'url': 'https://a.fbcdn.net/poster.jpg'},
              ],
            },
            'video_versions': [
              {
                'url': 'https://a.fbcdn.net/video.mp4',
                'width': 1080,
                'height': 1920,
              },
            ],
          }),
        ),
      ).extract('https://www.instagram.com/reel/Reel1/');
      expect(post.mediaItems.single.type, 'video');
      expect(post.mediaItems.single.qualities.single.height, 1920);
    });
    test(
      'never converts an inaccessible carousel into a cover download',
      () async {
        final transport = FixtureTransport(
          page({
            'shortcode': 'AbC',
            '__typename': 'GraphSidecar',
            'display_url': 'https://scontent.cdninstagram.com/cover.jpg',
          }),
        );
        await expectLater(
          ExtractorRegistry(
            transport: transport,
          ).extract('https://www.instagram.com/p/AbC/'),
          throwsA(
            isA<GatherException>().having((e) => e.code, 'code', 'blocked'),
          ),
        );
      },
    );
    test('rejects private accounts and a login-only page', () async {
      final transport = FixtureTransport(
        page({
          'shortcode': 'AbC',
          'owner': {'is_private': true},
          'display_url': 'https://scontent.cdninstagram.com/photo.jpg',
        }),
      );
      await expectLater(
        ExtractorRegistry(
          transport: transport,
        ).extract('https://www.instagram.com/p/AbC/'),
        throwsA(
          isA<GatherException>().having((e) => e.code, 'code', 'inaccessible'),
        ),
      );
      await expectLater(
        ExtractorRegistry(
          transport: FixtureTransport('<html>Log in to Instagram</html>'),
        ).extract('https://www.instagram.com/p/AbC/'),
        throwsA(isA<GatherException>()),
      );
    });
  });

  group('Pinterest public pin', () {
    test('current videoList yields MP4, never the poster image', () async {
      final transport = FixtureTransport(
        page({
          'entityId': '123',
          'pinner': {'username': 'pin_user'},
          'images_orig': {'url': 'https://i.pinimg.com/poster.jpg'},
          'videos': {
            'videoList': {
              '__typename': 'VideoList',
              'vHLSV4': {'url': 'https://v1.pinimg.com/video.m3u8'},
              'v720P': {
                'url': 'https://v1.pinimg.com/video.mp4',
                'width': 720,
                'height': 720,
              },
            },
          },
        }),
      );
      final post = await ExtractorRegistry(
        transport: transport,
      ).extract('https://www.pinterest.com/pin/123/');
      expect(post.mediaItems.single.type, 'video');
      expect(post.accountName, 'pin_user');
      expect(post.mediaItems.single.qualities.length, 1);
      expect(post.mediaItems.single.url, 'https://v1.pinimg.com/video.mp4');
    });
    test(
      'reads streamed public Relay JSON and slug URLs without evaluating scripts',
      () async {
        final response = jsonEncode({
          'data': {
            'pin': {
              'entityId': '123',
              '__typename': 'Pin',
              'images_orig': {
                'url': 'https://i.pinimg.com/originals/right.jpg',
              },
              'images_236x': {
                'url': 'https://i.pinimg.com/236x/right.jpg',
                'width': 236,
                'height': 354,
              },
              'images_60x60': {'url': 'https://i.pinimg.com/60x60/crop.jpg'},
              'gridTitle': 'Public pin',
              'board': {'privacy': 'public'},
            },
          },
        });
        final body =
            '<script>window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("%7B%7D", $response);</script>';
        final post = await ExtractorRegistry(
          transport: FixtureTransport(body),
        ).extract('https://ca.pinterest.com/pin/public-pin--123/');
        expect(post.id, '123');
        expect(post.title, 'Public pin');
        expect(post.mediaItems.single.qualities.length, 2);
        expect(
          post.mediaItems.single.url,
          'https://i.pinimg.com/originals/right.jpg',
        );
      },
    );
    test(
      'selects the requested pin, not recommended images, and prefers original',
      () async {
        final transport = FixtureTransport(
          page({
            'pins': [
              {
                'id': '999',
                'images': {
                  'orig': {'url': 'https://i.pinimg.com/originals/wrong.jpg'},
                },
              },
              {
                'id': '123',
                'title': 'The right pin',
                'images': {
                  '236x': {
                    'url': 'https://i.pinimg.com/236x/right.jpg',
                    'width': 236,
                    'height': 354,
                  },
                  'orig': {
                    'url': 'https://i.pinimg.com/originals/right.jpg',
                    'width': 1000,
                    'height': 1500,
                  },
                },
              },
            ],
          }),
        );
        final post = await ExtractorRegistry(
          transport: transport,
        ).extract('https://www.pinterest.com/pin/123/');
        expect(post.title, 'The right pin');
        expect(
          post.mediaItems.single.url,
          'https://i.pinimg.com/originals/right.jpg',
        );
      },
    );
    test('resolves short links and extracts video quality variants', () async {
      final transport = FixtureTransport(
        page({
          'id': '123',
          'images': {
            'orig': {'url': 'https://i.pinimg.com/poster.jpg'},
          },
          'videos': {
            'video_list': {
              'V_720P': {
                'url': 'https://v.pinimg.com/video720.mp4',
                'width': 720,
                'height': 1280,
              },
              'V_1080P': {
                'url': 'https://v.pinimg.com/video1080.mp4',
                'width': 1080,
                'height': 1920,
              },
            },
          },
        }),
        finalUri: Uri.parse('https://www.pinterest.com/pin/123/'),
      );
      final post = await ExtractorRegistry(
        transport: transport,
      ).extract('https://pin.it/Abc123');
      expect(post.id, '123');
      expect(post.mediaItems.single.type, 'video');
      expect(post.mediaItems.single.qualities.first.width, 1080);
    });
    test('rejects untrusted media URLs in embedded data', () async {
      final transport = FixtureTransport(
        page({
          'id': '123',
          'images': {
            'orig': {'url': 'https://attacker.test/payload.jpg'},
          },
        }),
      );
      await expectLater(
        ExtractorRegistry(
          transport: transport,
        ).extract('https://www.pinterest.com/pin/123/'),
        throwsA(isA<GatherException>()),
      );
    });
  });
}
