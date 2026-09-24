enum PlatformKind { x, instagram, pinterest, tiktok, facebook, youtube }

extension PlatformLabel on PlatformKind {
  String get label => switch (this) {
    PlatformKind.x => 'X',
    PlatformKind.instagram => 'Instagram',
    PlatformKind.pinterest => 'Pinterest',
    PlatformKind.tiktok => 'TikTok',
    PlatformKind.facebook => 'Facebook',
    PlatformKind.youtube => 'YouTube',
  };
}

class PlatformCapabilities {
  const PlatformCapabilities({
    required this.canAuthenticate,
    required this.canResolvePosts,
    required this.canAccessOwnMedia,
    required this.canAccessAuthorizedPrivateMedia,
    required this.canDownloadImages,
    required this.canDownloadVideos,
    required this.supportsCarousel,
    required this.supportsOfficialApi,
    this.privateContentNote = '',
    this.unavailableNote = '',
  });

  final bool canAuthenticate;
  final bool canResolvePosts;
  final bool canAccessOwnMedia;
  final bool canAccessAuthorizedPrivateMedia;
  final bool canDownloadImages;
  final bool canDownloadVideos;
  final bool supportsCarousel;
  final bool supportsOfficialApi;
  final String privateContentNote;
  final String unavailableNote;
}

class PlatformAccount {
  const PlatformAccount({required this.id, required this.name, this.username});

  final String id;
  final String name;
  final String? username;
}

class GatherException implements Exception {
  const GatherException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class Quality {
  const Quality(this.url, this.label, {this.width, this.height, this.bytes});
  final String url;
  final String label;
  final int? width;
  final int? height;
  final int? bytes;
}

class MediaItem {
  const MediaItem({
    required this.type,
    required this.qualities,
    this.thumbnail,
    this.downloadable = true,
    this.unavailableReason,
  });
  final String type;
  final List<Quality> qualities;
  final String? thumbnail;
  final bool downloadable;
  final String? unavailableReason;
  String get url => qualities.first.url;
}

String _filenamePart(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '';
  }
  var cleaned = value.runes
      .where((rune) => rune >= 32)
      .map(String.fromCharCode)
      .join()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (cleaned.length > 120) {
    cleaned = cleaned.substring(0, 120).trimRight();
  }
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$',
    caseSensitive: false,
  ).hasMatch(cleaned)) {
    cleaned = '_$cleaned';
  }
  return cleaned;
}

String suggestedFileName(Post post, int index) {
  final account = _filenamePart(post.accountName);
  final title = _filenamePart(post.title);
  final parts = [account, title].where((part) => part.isNotEmpty).toList();
  if (parts.isNotEmpty) {
    return parts.join(' - ');
  }
  return '${post.platform.name}_${post.id}_${index + 1}';
}

class Post {
  const Post({
    required this.platform,
    required this.source,
    required this.id,
    required this.title,
    required this.mediaItems,
    this.accountName,
    this.access = PostAccess.public,
  });
  final PlatformKind platform;
  final Uri source;
  final String id;
  final String title;
  final List<MediaItem> mediaItems;
  final String? accountName;
  final PostAccess access;
  String get postType =>
      mediaItems.length > 1 ? 'carousel' : mediaItems.first.type;
}

enum PostAccess { public, ownAccount, authorizedPrivate }

class PostLink {
  const PostLink(this.platform, this.uri, this.id);
  final PlatformKind platform;
  final Uri uri;
  final String id;

  static PostLink parse(String text) {
    for (final match in RegExp(r'https?://[^\s<>]+').allMatches(text)) {
      final raw = match
          .group(0)!
          .replaceFirst(RegExp(r'''[\)\]\.,!"']+$'''), '');
      final uri = Uri.tryParse(raw);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443)) {
        continue;
      }
      final host = uri.host.toLowerCase();
      final x = RegExp(
        r'^/(?:[A-Za-z0-9_]+/status|i/web/status)/(\d+)(?:/.*)?$',
      ).firstMatch(uri.path);
      if ([
            'x.com',
            'www.x.com',
            'twitter.com',
            'www.twitter.com',
            'mobile.twitter.com',
          ].contains(host) &&
          x != null) {
        return PostLink(
          PlatformKind.x,
          Uri.parse('https://x.com/i/web/status/${x[1]}'),
          x[1]!,
        );
      }
      final ig = RegExp(
        r'^/(p|reel|reels|tv)/([A-Za-z0-9_-]+)/?$',
      ).firstMatch(uri.path);
      if (['instagram.com', 'www.instagram.com'].contains(host) && ig != null) {
        return PostLink(
          PlatformKind.instagram,
          Uri.parse('https://www.instagram.com/${ig[1]}/${ig[2]}/'),
          ig[2]!,
        );
      }
      final pin = RegExp(r'^/pin/(?:[^/]+--)?(\d+)/?$').firstMatch(uri.path);
      if (isPinterestHost(host) && pin != null) {
        return PostLink(
          PlatformKind.pinterest,
          Uri.parse('https://www.pinterest.com/pin/${pin[1]}/'),
          pin[1]!,
        );
      }
      if (host == 'pin.it' && RegExp(r'^/[A-Za-z0-9]+/?$').hasMatch(uri.path)) {
        return PostLink(
          PlatformKind.pinterest,
          uri.replace(query: '', fragment: ''),
          'short',
        );
      }
      final tiktok = RegExp(
        r'^/@([A-Za-z0-9._-]+)/video/(\d+)/?$',
      ).firstMatch(uri.path);
      if (isTikTokHost(host) && tiktok != null) {
        return PostLink(
          PlatformKind.tiktok,
          Uri.parse('https://www.tiktok.com/@${tiktok[1]}/video/${tiktok[2]}'),
          tiktok[2]!,
        );
      }
      if (isTikTokShortHost(host) &&
          RegExp(r'^/[A-Za-z0-9]+/?$').hasMatch(uri.path)) {
        return PostLink(
          PlatformKind.tiktok,
          uri.replace(query: '', fragment: ''),
          'short',
        );
      }
      if (isFacebookHost(host)) {
        final watchId = uri.queryParameters['v'] ?? uri.queryParameters['fbid'];
        final facebookPath = RegExp(
          r'^/(?:[^/]+/)?(?:posts|videos|reel|photo(?:\.php)?)/([A-Za-z0-9._-]+)/?$',
        ).firstMatch(uri.path);
        final sharedPath = RegExp(
          r'^/share/(?:p|v)/([A-Za-z0-9._-]+)/?$',
        ).firstMatch(uri.path);
        final id = watchId ?? facebookPath?.group(1) ?? sharedPath?.group(1);
        if (id != null && RegExp(r'^[A-Za-z0-9._-]{3,128}$').hasMatch(id)) {
          return PostLink(
            PlatformKind.facebook,
            Uri.https('www.facebook.com', '/watch/', {'v': id}),
            id,
          );
        }
        final fbWatch = RegExp(
          r'^/([A-Za-z0-9_-]{3,128})/?$',
        ).firstMatch(uri.path);
        if (host == 'fb.watch' && fbWatch != null) {
          return PostLink(
            PlatformKind.facebook,
            Uri.https('fb.watch', '/${fbWatch[1]}'),
            fbWatch[1]!,
          );
        }
      }
      if (isYouTubeHost(host)) {
        String? videoId;
        if (host == 'youtu.be') {
          videoId = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
        } else if (uri.path == '/watch') {
          videoId = uri.queryParameters['v'];
        } else {
          final youtubePath = RegExp(
            r'^/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})/?$',
          ).firstMatch(uri.path);
          videoId = youtubePath?.group(1);
        }
        if (videoId != null &&
            RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
          return PostLink(
            PlatformKind.youtube,
            Uri.https('www.youtube.com', '/watch', {'v': videoId}),
            videoId,
          );
        }
      }
    }
    throw const GatherException(
      'unsupported',
      'Share an HTTPS post link from X, Instagram, Facebook, TikTok, Pinterest, or YouTube. Profile, story, and search links are not supported.',
    );
  }

  static bool isPinterestHost(String host) => const {
    'pinterest.com',
    'www.pinterest.com',
    'in.pinterest.com',
    'uk.pinterest.com',
    'au.pinterest.com',
    'ca.pinterest.com',
    'fr.pinterest.com',
    'de.pinterest.com',
    'at.pinterest.com',
    'es.pinterest.com',
    'it.pinterest.com',
    'br.pinterest.com',
    'jp.pinterest.com',
    'www.pinterest.co.uk',
    'pinterest.co.uk',
  }.contains(host);

  static bool isTikTokHost(String host) =>
      const {'tiktok.com', 'www.tiktok.com', 'm.tiktok.com'}.contains(host);

  static bool isTikTokShortHost(String host) =>
      const {'vm.tiktok.com', 'vt.tiktok.com'}.contains(host);

  static bool isFacebookHost(String host) => const {
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'fb.com',
    'www.fb.com',
    'fb.watch',
  }.contains(host);

  static bool isYouTubeHost(String host) => const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  }.contains(host);
}

bool isMediaUrl(String value, PlatformKind platform) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  final domains = switch (platform) {
    PlatformKind.x => ['twimg.com'],
    PlatformKind.instagram => ['cdninstagram.com', 'fbcdn.net'],
    PlatformKind.pinterest => ['pinimg.com'],
    PlatformKind.tiktok => [
      'tiktokcdn.com',
      'muscdn.com',
      'ibytedtos.com',
      'byteimg.com',
    ],
    PlatformKind.facebook => ['fbcdn.net', 'fbsbx.com'],
    PlatformKind.youtube => const <String>[],
  };
  return domains.any((d) => uri.host == d || uri.host.endsWith('.$d'));
}
