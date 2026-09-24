import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:html/parser.dart' as html;
import 'models.dart';

class PageData {
  const PageData(this.uri, this.body);
  final Uri uri;
  final String body;
}

abstract interface class PublicTransport {
  Future<PageData> get(Uri uri);
  Future<int?> size(String url, PlatformKind platform);
}

/// No cookie jar, credentials, authorization headers, private API, or proxy.
class PublicHttp implements PublicTransport {
  bool _allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (const {
            'x.com',
            'www.x.com',
            'twitter.com',
            'www.twitter.com',
            'cdn.syndication.twimg.com',
            'www.instagram.com',
            'instagram.com',
            'pin.it',
            'api.pinterest.com',
            'tiktok.com',
            'www.tiktok.com',
            'm.tiktok.com',
            'vm.tiktok.com',
            'vt.tiktok.com',
          }.contains(uri.host) ||
          PostLink.isPinterestHost(uri.host));

  @override
  Future<PageData> get(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var current = uri;
      for (var redirect = 0; redirect <= 5; redirect++) {
        if (!_allowed(current)) {
          throw const GatherException(
            'inaccessible',
            'The platform redirected away from a supported public page.',
          );
        }
        if (RegExp(
          r'/(accounts/login|login|challenge|checkpoint)(/|\?)',
        ).hasMatch('${current.path}/')) {
          throw const GatherException(
            'inaccessible',
            'This post requires login or an access check. Gather only fetches public posts.',
          );
        }
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'text/html,application/json',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const GatherException(
              'blocked',
              'The platform returned an invalid redirect.',
            );
          }
          current = current.resolve(location);
          continue;
        }
        if ([404, 410].contains(response.statusCode)) {
          throw const GatherException(
            'deleted',
            'This post was deleted, does not exist, or is unavailable publicly.',
          );
        }
        if ([401, 403].contains(response.statusCode)) {
          throw const GatherException(
            'inaccessible',
            'This post is private, requires login, or the platform denied access.',
          );
        }
        if (response.statusCode == 429) {
          throw const GatherException(
            'blocked',
            'The platform is limiting requests. Try again later.',
          );
        }
        if (response.statusCode != 200) {
          throw GatherException(
            'network',
            'The platform returned HTTP ${response.statusCode}. Try again later.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) {
            throw const GatherException(
              'blocked',
              'The page is too large to inspect safely.',
            );
          }
        }
        return PageData(current, utf8.decode(bytes, allowMalformed: true));
      }
      throw const GatherException(
        'blocked',
        'Too many redirects from the platform.',
      );
    } on SocketException {
      throw const GatherException(
        'network',
        'Could not connect. Check your internet connection.',
      );
    } on TimeoutException {
      throw const GatherException(
        'network',
        'The platform took too long to respond. Try again.',
      );
    } on HandshakeException {
      throw const GatherException(
        'network',
        'A secure connection could not be established.',
      );
    } on HttpException {
      throw const GatherException(
        'network',
        'The connection was interrupted. Try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<int?> size(String url, PlatformKind platform) async {
    if (!isMediaUrl(url, platform)) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      return response.statusCode == 200 && response.contentLength > 0
          ? response.contentLength
          : null;
    } on Exception {
      // Size is optional: the UI explicitly shows "Size unavailable".
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

abstract interface class PostExtractor {
  Future<Post> extract(PostLink link);
}

class ExtractorRegistry {
  ExtractorRegistry({PublicTransport? transport})
    : transport = transport ?? PublicHttp();
  final PublicTransport transport;
  Future<Post> extract(String text) async {
    final link = PostLink.parse(text);
    final PostExtractor extractor = switch (link.platform) {
      PlatformKind.x => XExtractor(transport),
      PlatformKind.instagram => InstagramExtractor(transport),
      PlatformKind.pinterest => PinterestExtractor(transport),
      PlatformKind.tiktok => TikTokExtractor(transport),
      PlatformKind.facebook => throw const GatherException(
        'facebook_api_unavailable',
        'Facebook post media is not available through an authorized Gather API integration.',
      ),
      PlatformKind.youtube => throw const GatherException(
        'youtube_download_restricted',
        'YouTube audiovisual downloads are not enabled in Gather.',
      ),
    };
    return extractor.extract(link);
  }
}

Map<String, dynamic>? _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;
List<dynamic> _list(dynamic value) => value is List ? value : const [];
int? _int(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value');
String? _str(dynamic value) =>
    value is String && value.isNotEmpty ? value : null;

String? _accountName(dynamic value) {
  final map = _map(value);
  return _str(map?['screen_name']) ??
      _str(map?['username']) ??
      _str(map?['user_name']) ??
      _str(map?['full_name']) ??
      _str(map?['display_name']) ??
      _str(map?['name']);
}

Iterable<Map<String, dynamic>> _objects(dynamic value) sync* {
  if (value is Map) {
    final object = Map<String, dynamic>.from(value);
    yield object;
    for (final child in object.values) {
      yield* _objects(child);
    }
  } else if (value is List) {
    for (final child in value) {
      yield* _objects(child);
    }
  }
}

/// Parse JSON data scripts only; never execute JavaScript from a post.
List<dynamic> pageJson(String source) {
  final document = html.parse(source);
  final roots = <dynamic>[];
  for (final script in document.querySelectorAll('script')) {
    var text = script.text.trim();
    // Pinterest streams public Relay results as JSON arguments to this wrapper.
    // Strip only the observed wrapper and decode JSON; never evaluate script.
    final relay = RegExp(
      r'^window\.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__\("(?:\\.|[^"\\])*",\s*',
    ).firstMatch(text);
    if (relay != null) {
      text = text.substring(relay.end).replaceFirst(RegExp(r'\);?\s*$'), '');
    }
    if (!text.startsWith('{') && !text.startsWith('[')) {
      continue;
    }
    try {
      roots.add(jsonDecode(text));
    } on FormatException {
      continue;
    }
  }
  return roots;
}

class TikTokExtractor implements PostExtractor {
  TikTokExtractor(this.transport);
  final PublicTransport transport;

  @override
  Future<Post> extract(PostLink link) async {
    final response = await transport.get(
      Uri.https('www.tiktok.com', '/oembed', {'url': link.uri.toString()}),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const GatherException(
        'blocked',
        'TikTok did not return a public preview. Try again later.',
      );
    }
    final data = _map(decoded);
    if (data == null || data['type'] != 'video') {
      throw const GatherException(
        'inaccessible',
        'This TikTok video is private, deleted, or unavailable through its public embed.',
      );
    }
    final thumbnail = _str(data['thumbnail_url']);
    if (thumbnail == null || !isMediaUrl(thumbnail, PlatformKind.tiktok)) {
      throw const GatherException(
        'blocked',
        'TikTok did not provide a supported preview image.',
      );
    }
    final width = _int(data['thumbnail_width']);
    final height = _int(data['thumbnail_height']);
    return Post(
      platform: PlatformKind.tiktok,
      source: link.uri,
      id: link.id,
      title: _str(data['title']) ?? 'TikTok video',
      accountName: _str(data['author_name']),
      mediaItems: [
        MediaItem(
          type: 'video',
          thumbnail: thumbnail,
          downloadable: false,
          unavailableReason:
              'TikTok provided an official preview only. Gather cannot download a video file through TikTok’s available Display API.',
          qualities: [
            Quality(
              thumbnail,
              'Official preview thumbnail',
              width: width,
              height: height,
            ),
          ],
        ),
      ],
    );
  }
}

Post _post(
  PostLink link,
  List<MediaItem> items,
  String title, {
  String? accountName,
}) {
  if (items.isEmpty) {
    throw const GatherException(
      'no_media',
      'This post has no supported downloadable photos or videos.',
    );
  }
  if (items.any(
    (m) =>
        m.qualities.isEmpty ||
        m.qualities.any((q) => !isMediaUrl(q.url, link.platform)),
  )) {
    throw const GatherException(
      'blocked',
      'The platform returned an unrecognized media source.',
    );
  }
  return Post(
    platform: link.platform,
    source: link.uri,
    id: link.id,
    title: title,
    mediaItems: items,
    accountName: accountName,
  );
}

class XExtractor implements PostExtractor {
  XExtractor(this.transport);
  final PublicTransport transport;

  // Public embedded-post renderer data, not a private API. Replace this module
  // via a signed app update if X changes its public embed implementation.
  static String embedToken(String id) {
    final value = double.parse(id) / 1e15 * math.pi;
    final whole = value.floor().toRadixString(36);
    var remainder = value - value.floor();
    final fractional = StringBuffer();
    for (var i = 0; i < 14 && remainder > 0; i++) {
      remainder *= 36;
      fractional.write(remainder.floor().toRadixString(36));
      remainder -= remainder.floor();
    }
    return '$whole$fractional'.replaceAll('0', '');
  }

  @override
  Future<Post> extract(PostLink link) async {
    final page = await transport.get(
      Uri.https('cdn.syndication.twimg.com', '/tweet-result', {
        'id': link.id,
        'lang': 'en',
        'token': embedToken(link.id),
      }),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(page.body);
    } on FormatException {
      throw const GatherException(
        'blocked',
        'X did not return public post data. Try again later.',
      );
    }
    final data = _map(decoded);
    if (data == null ||
        data['id_str'] != link.id ||
        _map(data['user'])?['protected'] == true) {
      throw const GatherException(
        'inaccessible',
        'This X post is not available through its public embed.',
      );
    }
    final items = <MediaItem>[];
    for (final raw in _list(data['mediaDetails'])) {
      final media = _map(raw);
      if (media == null) {
        continue;
      }
      final thumb = _str(media['media_url_https']);
      if (media['type'] == 'photo' && thumb != null) {
        final size = _map(media['original_info']);
        final uri = Uri.parse(thumb);
        final format = uri.path.split('.').last;
        final url = uri
            .replace(
              path: uri.path.replaceFirst(RegExp(r'\.[a-zA-Z]+$'), ''),
              queryParameters: {'format': format, 'name': 'orig'},
            )
            .toString();
        items.add(
          MediaItem(
            type: 'image',
            thumbnail: thumb,
            qualities: [
              Quality(
                url,
                'Original',
                width: _int(size?['width']),
                height: _int(size?['height']),
              ),
            ],
          ),
        );
      } else if (['video', 'animated_gif'].contains(media['type'])) {
        final video = _map(media['video_info']);
        final variants =
            _list(video?['variants'])
                .map(_map)
                .whereType<Map<String, dynamic>>()
                .where(
                  (v) =>
                      v['content_type'] == 'video/mp4' &&
                      _str(v['url']) != null,
                )
                .toList()
              ..sort(
                (a, b) => (_int(b['bitrate']) ?? 0).compareTo(
                  _int(a['bitrate']) ?? 0,
                ),
              );
        final qualities = variants.map((v) {
          final url = v['url'] as String;
          final dimensions = RegExp(r'/(\d+)x(\d+)/').firstMatch(url);
          return Quality(
            url,
            dimensions == null
                ? 'MP4 · ${(_int(v['bitrate']) ?? 0) ~/ 1000} kbps'
                : '${dimensions[1]} × ${dimensions[2]}',
            width: int.tryParse(dimensions?[1] ?? ''),
            height: int.tryParse(dimensions?[2] ?? ''),
          );
        }).toList();
        if (qualities.isEmpty) {
          throw const GatherException(
            'unsupported',
            'This X video does not expose a downloadable MP4 stream.',
          );
        }
        items.add(
          MediaItem(type: 'video', thumbnail: thumb, qualities: qualities),
        );
      }
    }
    return _post(
      link,
      items,
      _str(data['text']) ?? 'Post from X',
      accountName: _accountName(data['user']),
    );
  }
}

class InstagramExtractor implements PostExtractor {
  InstagramExtractor(this.transport);
  final PublicTransport transport;
  @override
  Future<Post> extract(PostLink link) async {
    final page = await transport.get(link.uri);
    for (final root in pageJson(page.body)) {
      for (final node in _objects(root)) {
        if (node['shortcode'] != link.id && node['code'] != link.id) {
          continue;
        }
        if (_map(node['owner'])?['is_private'] == true ||
            _map(node['user'])?['is_private'] == true) {
          throw const GatherException(
            'inaccessible',
            'Private Instagram posts are outside Gather’s scope.',
          );
        }
        final edges = _list(_map(node['edge_sidecar_to_children'])?['edges']);
        final carousel = _list(node['carousel_media']);
        final children = edges.isNotEmpty
            ? edges.map((e) => _map(e)?['node']).toList()
            : carousel;
        if ((node['__typename'] == 'GraphSidecar' || node['media_type'] == 8) &&
            children.isEmpty) {
          throw const GatherException(
            'blocked',
            'Instagram did not expose this carousel’s items publicly.',
          );
        }
        final media = (children.isEmpty ? [node] : children)
            .map((child) => _instagramMedia(_map(child)))
            .toList();
        final accountName =
            _accountName(node['owner']) ?? _accountName(node['user']);
        return _post(
          link,
          media,
          _str(_map(node['caption'])?['text']) ?? 'Post from Instagram',
          accountName: accountName,
        );
      }
    }
    throw const GatherException(
      'blocked',
      'Instagram has not exposed the complete post publicly. It may require login, block automated requests, or use a new page format. No credentials are requested.',
    );
  }

  MediaItem _instagramMedia(Map<String, dynamic>? node) {
    if (node == null) {
      throw const GatherException(
        'blocked',
        'Instagram returned an incomplete carousel.',
      );
    }
    final candidates = _list(_map(node['image_versions2'])?['candidates']);
    final thumbnail =
        _str(node['display_url']) ??
        _str(node['thumbnail_src']) ??
        (candidates.isEmpty ? null : _str(_map(candidates.first)?['url']));
    final videos = _list(node['video_versions']);
    final videoUrl = _str(node['video_url']);
    final isVideo =
        node['is_video'] == true ||
        node['media_type'] == 2 ||
        videoUrl != null ||
        videos.isNotEmpty;
    final qualities = <Quality>[];
    final sources = isVideo
        ? videos
        : (_list(node['display_resources']).isNotEmpty
              ? _list(node['display_resources'])
              : candidates);
    for (final raw in sources) {
      final source = _map(raw);
      final url = _str(source?['src']) ?? _str(source?['url']);
      if (url == null || !isMediaUrl(url, PlatformKind.instagram)) {
        continue;
      }
      final width = _int(source?['config_width']) ?? _int(source?['width']);
      final height = _int(source?['config_height']) ?? _int(source?['height']);
      if (qualities.any((q) => q.url == url)) {
        continue;
      }
      qualities.add(
        Quality(
          url,
          width != null && height != null
              ? '$width × $height'
              : 'Source quality',
          width: width,
          height: height,
        ),
      );
    }
    if (qualities.isEmpty) {
      final url = isVideo ? videoUrl : thumbnail;
      if (url != null) {
        qualities.add(Quality(url, 'Source quality'));
      }
    }
    if (qualities.isEmpty) {
      throw const GatherException(
        'blocked',
        'Instagram did not expose every media item.',
      );
    }
    qualities.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
    return MediaItem(
      type: isVideo ? 'video' : 'image',
      thumbnail: thumbnail,
      qualities: qualities,
    );
  }
}

class PinterestExtractor implements PostExtractor {
  PinterestExtractor(this.transport);
  final PublicTransport transport;
  @override
  Future<Post> extract(PostLink link) async {
    final page = await transport.get(link.uri);
    final resolved = link.id == 'short'
        ? PostLink.parse(page.uri.toString())
        : link;
    if (resolved.id == 'short') {
      throw const GatherException(
        'unsupported',
        'This short link did not resolve to a Pinterest pin.',
      );
    }
    for (final root in pageJson(page.body)) {
      for (final node in _objects(root)) {
        if ('${node['entityId'] ?? node['id']}' != resolved.id ||
            (node['images'] == null &&
                node['images_orig'] == null &&
                node['videos'] == null)) {
          continue;
        }
        if (node['is_private'] == true ||
            _map(node['board'])?['privacy'] == 'secret') {
          throw const GatherException(
            'inaccessible',
            'Secret Pinterest pins are outside Gather’s scope.',
          );
        }
        final accountName =
            _accountName(node['pinner']) ??
            _accountName(node['creator']) ??
            _accountName(node['owner']) ??
            _accountName(node['user']);
        final images =
            _map(node['images']) ??
            <String, dynamic>{
              for (final entry in node.entries)
                if (entry.key.startsWith('images_'))
                  entry.key.substring(7): entry.value,
            };
        final orig = _map(images['orig']);
        final thumb = _str(orig?['url']);
        final videoData = _map(node['videos']);
        final videos =
            _map(videoData?['video_list']) ?? _map(videoData?['videoList']);
        if ((videoData != null || node['isVideo'] == true) && videos == null) {
          throw const GatherException(
            'blocked',
            'Pinterest did not expose this video’s downloadable streams.',
          );
        }
        if (videos != null) {
          final qualities = <Quality>[];
          for (final raw in videos.values) {
            final v = _map(raw);
            final url = _str(v?['url']);
            if (url == null || !Uri.parse(url).path.endsWith('.mp4')) {
              continue;
            }
            qualities.add(
              Quality(
                url,
                '${v?['width'] ?? '?'} × ${v?['height'] ?? '?'}',
                width: _int(v?['width']),
                height: _int(v?['height']),
                bytes: _int(v?['size']),
              ),
            );
          }
          qualities.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
          if (qualities.isEmpty) {
            throw const GatherException(
              'unsupported',
              'This pin does not expose a downloadable MP4 stream.',
            );
          }
          return _post(
            resolved,
            [MediaItem(type: 'video', thumbnail: thumb, qualities: qualities)],
            _str(node['title']) ?? 'Video pin',
            accountName: accountName,
          );
        }
        if (node['story_pin_data'] != null || node['storyPinData'] != null) {
          throw const GatherException(
            'unsupported',
            'Multi-page idea pins are not supported in this version.',
          );
        }
        final qualities = <Quality>[];
        if (images.isNotEmpty) {
          for (final entry in images.entries) {
            if (!RegExp(r'^(orig|\d+x?)$').hasMatch(entry.key)) {
              continue;
            }
            final image = _map(entry.value);
            final url = _str(image?['url']);
            if (url == null || qualities.any((q) => q.url == url)) {
              continue;
            }
            qualities.add(
              Quality(
                url,
                entry.key == 'orig'
                    ? 'Original'
                    : '${image?['width'] ?? entry.key} × ${image?['height'] ?? '?'}',
                width: _int(image?['width']),
                height: _int(image?['height']),
              ),
            );
          }
        }
        qualities.sort(
          (a, b) => a.label == 'Original'
              ? -1
              : b.label == 'Original'
              ? 1
              : (b.width ?? 0).compareTo(a.width ?? 0),
        );
        if (qualities.isNotEmpty) {
          return _post(
            resolved,
            [
              MediaItem(
                type: 'image',
                thumbnail: thumb ?? qualities.first.url,
                qualities: qualities,
              ),
            ],
            _str(node['title']) ?? _str(node['gridTitle']) ?? 'Image pin',
            accountName: accountName,
          );
        }
      }
    }
    // Schema.org must identify this pin; never harvest recommendation grids.
    for (final root in pageJson(page.body)) {
      for (final node in _objects(root)) {
        if (!['ImageObject', 'VideoObject'].contains(node['@type'])) {
          continue;
        }
        final owner = _str(node['url']) ?? _str(node['mainEntityOfPage']);
        if (owner == null || !owner.contains('/pin/${resolved.id}/')) {
          continue;
        }
        final url = _str(node['contentUrl']);
        if (url == null) {
          continue;
        }
        return _post(
          resolved,
          [
            MediaItem(
              type: node['@type'] == 'VideoObject' ? 'video' : 'image',
              thumbnail: _str(node['thumbnailUrl']),
              qualities: [Quality(url, 'Source quality')],
            ),
          ],
          _str(node['name']) ?? 'Pinterest pin',
          accountName: _accountName(node['author']),
        );
      }
    }
    throw const GatherException(
      'blocked',
      'Pinterest did not expose this pin’s media on its public page. Try again later.',
    );
  }
}
