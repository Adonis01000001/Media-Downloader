import 'extractors.dart';
import 'instagram_api.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'x_api.dart';

class ResolvedProviderPost {
  const ResolvedProviderPost({required this.post, required this.provider});
  final Post post;
  final PlatformProvider provider;
}

abstract interface class PlatformProvider {
  PlatformKind get platform;
  PlatformCapabilities get capabilities;
  bool get isConnected;
  String get accountStatus;
  String get setupStatus;
  Future<void> authenticate();
  Future<void> disconnect();
  Future<PlatformAccount?> getCurrentUser();
  Future<Post> resolveSharedUrl(String text);
  Future<Post> getPost(PostLink link);
  Future<List<MediaItem>> getMedia(Post post);
  Future<Map<String, dynamic>> downloadMedia(
    Post post,
    int itemIndex, {
    required int qualityIndex,
    String? fileName,
    bool force = false,
  });
}

abstract class BasePlatformProvider implements PlatformProvider {
  BasePlatformProvider({required this.extractors, required this.bridge});

  final ExtractorRegistry extractors;
  final NativeBridge bridge;

  @override
  bool get isConnected => false;

  @override
  String get accountStatus => 'Public access only';

  @override
  String get setupStatus => '';

  @override
  Future<void> authenticate() async {
    throw GatherException(
      '${platform.name}_auth_unavailable',
      '${platform.label} authentication is not available in this build.',
    );
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<PlatformAccount?> getCurrentUser() async => null;

  @override
  Future<Post> getPost(PostLink link) async =>
      resolveSharedUrl(link.uri.toString());

  @override
  Future<List<MediaItem>> getMedia(Post post) async {
    if (post.platform != platform) {
      throw const GatherException(
        'unsupported_url',
        'The post belongs to another platform.',
      );
    }
    return post.mediaItems;
  }

  @override
  Future<Map<String, dynamic>> downloadMedia(
    Post post,
    int itemIndex, {
    required int qualityIndex,
    String? fileName,
    bool force = false,
  }) async {
    if (post.platform != platform ||
        itemIndex < 0 ||
        itemIndex >= post.mediaItems.length) {
      throw const GatherException(
        'unsupported_media',
        'This media item cannot be downloaded.',
      );
    }
    final media = post.mediaItems[itemIndex];
    if (!media.downloadable ||
        qualityIndex < 0 ||
        qualityIndex >= media.qualities.length) {
      throw GatherException(
        '${platform.name}_download_unavailable',
        media.unavailableReason ??
            '${platform.label} did not authorize a downloadable media file.',
      );
    }
    return bridge.download({
      'url': media.qualities[qualityIndex].url,
      'source': post.source.toString(),
      'platform': post.platform.name,
      'type': media.type,
      'thumbnail': media.thumbnail ?? '',
      'name': fileName ?? suggestedFileName(post, itemIndex),
      'itemKey': '${post.source}#$itemIndex',
      'force': force,
    });
  }
}

class InstagramProvider extends BasePlatformProvider {
  InstagramProvider({
    required super.extractors,
    required super.bridge,
    required this.auth,
  });

  final InstagramAuthService auth;

  @override
  PlatformKind get platform => PlatformKind.instagram;

  @override
  bool get isConnected => auth.session != null;

  @override
  String get accountStatus => auth.session == null
      ? 'Public posts only'
      : 'Connected as @${auth.session!.username}';

  @override
  String get setupStatus => auth.isConfigured
      ? ''
      : 'Configure an HTTPS Instagram OAuth backend to connect a Professional account.';

  @override
  PlatformCapabilities get capabilities => PlatformCapabilities(
    canAuthenticate: auth.isConfigured,
    canResolvePosts: true,
    canAccessOwnMedia: isConnected,
    canAccessAuthorizedPrivateMedia: false,
    canDownloadImages: true,
    canDownloadVideos: true,
    supportsCarousel: true,
    supportsOfficialApi: true,
    privateContentNote:
        'The official Instagram API path is limited to the connected Professional account’s own /me/media list. It does not access posts from accounts the user follows.',
  );

  @override
  Future<void> authenticate() => auth.beginConnect();

  @override
  Future<void> disconnect() => auth.disconnect();

  @override
  Future<PlatformAccount?> getCurrentUser() async {
    final session = auth.session;
    return session == null
        ? null
        : PlatformAccount(
            id: session.userId,
            name: session.username,
            username: session.username,
          );
  }

  @override
  Future<Post> resolveSharedUrl(String text) async {
    final link = PostLink.parse(text);
    if (link.platform != platform) {
      throw const GatherException(
        'unsupported_url',
        'This is not an Instagram link.',
      );
    }
    try {
      return await extractors.extract(text);
    } on GatherException catch (error) {
      if (!const {'inaccessible', 'blocked'}.contains(error.code)) {
        rethrow;
      }
      if (auth.session == null) {
        throw const GatherException(
          'instagram_auth_required',
          'Instagram did not provide this post publicly. Connect your own Professional account to check only its official /me/media list; Gather cannot access posts from accounts you follow.',
        );
      }
      final own = await auth.resolveOwnedPost(link);
      return _withAccess(own, PostAccess.ownAccount);
    }
  }
}

class XProvider extends BasePlatformProvider {
  XProvider({
    required super.extractors,
    required super.bridge,
    required this.auth,
    XPostApi? api,
  }) : api = api ?? XPostApi(auth: auth);

  final XAuthService auth;
  final XPostApi api;
  int? _verifiedPrivateSessionEpoch;

  @override
  PlatformKind get platform => PlatformKind.x;

  @override
  bool get isConnected => auth.session != null;

  @override
  String get accountStatus => auth.session == null
      ? 'Public posts only'
      : 'Connected as @${auth.session!.username}';

  @override
  String get setupStatus => auth.isConfigured
      ? ''
      : 'Configure X OAuth and API credentials on the backend to connect an account.';

  @override
  PlatformCapabilities get capabilities => PlatformCapabilities(
    canAuthenticate: auth.isConfigured,
    canResolvePosts: true,
    canAccessOwnMedia: isConnected,
    // This changes only after the official API actually returns a protected post
    // to the connected account. A token alone is not treated as authorization.
    canAccessAuthorizedPrivateMedia:
        auth.session != null &&
        _verifiedPrivateSessionEpoch == auth.sessionEpoch,
    canDownloadImages: true,
    canDownloadVideos: true,
    supportsCarousel: true,
    supportsOfficialApi: true,
    privateContentNote:
        auth.session != null &&
            _verifiedPrivateSessionEpoch == auth.sessionEpoch
        ? 'The official X API returned protected media for this connected account. Access remains subject to X API permissions.'
        : 'Protected-post access is unverified for this account. Gather uses only results returned by the official authenticated X API and reports API denial; no private-page fallback is used. Requested OAuth scopes: tweet.read, users.read, offline.access.',
  );

  @override
  Future<void> authenticate() => auth.authenticate();

  @override
  Future<void> disconnect() => auth.disconnect();

  @override
  Future<PlatformAccount?> getCurrentUser() async {
    final session = auth.session;
    return session == null
        ? null
        : PlatformAccount(
            id: session.userId,
            name: session.name,
            username: session.username,
          );
  }

  @override
  Future<Post> resolveSharedUrl(String text) async {
    final link = PostLink.parse(text);
    if (link.platform != platform) {
      throw const GatherException(
        'unsupported_url',
        'This is not an X post link.',
      );
    }
    if (auth.session == null) {
      // Preserve the existing no-cookie public renderer path for public posts.
      // It has no access to the user's session, and never runs after API denial.
      try {
        return await extractors.extract(text);
      } on GatherException catch (error) {
        if (!const {'inaccessible', 'blocked'}.contains(error.code)) rethrow;
        throw const GatherException(
          'x_auth_required',
          'X did not expose this post publicly. Connect an X account to ask the official API; if X does not return the post, Gather cannot access it.',
        );
      }
    }
    final post = await api.getPost(link);
    if (post.access == PostAccess.authorizedPrivate) {
      _verifiedPrivateSessionEpoch = auth.sessionEpoch;
    }
    return post;
  }

  @override
  Future<Post> getPost(PostLink link) async {
    if (link.platform != platform) {
      throw const GatherException(
        'unsupported_url',
        'This is not an X post link.',
      );
    }
    if (auth.session == null) {
      try {
        return await extractors.extract(link.uri.toString());
      } on GatherException catch (error) {
        if (!const {'inaccessible', 'blocked'}.contains(error.code)) rethrow;
        throw const GatherException(
          'x_auth_required',
          'X did not expose this post publicly. Connect an X account to ask the official API; if X does not return the post, Gather cannot access it.',
        );
      }
    }
    final post = await api.getPost(link);
    if (post.access == PostAccess.authorizedPrivate) {
      _verifiedPrivateSessionEpoch = auth.sessionEpoch;
    }
    return post;
  }
}

class PinterestProvider extends BasePlatformProvider {
  PinterestProvider({required super.extractors, required super.bridge});

  @override
  PlatformKind get platform => PlatformKind.pinterest;

  @override
  PlatformCapabilities get capabilities => const PlatformCapabilities(
    canAuthenticate: false,
    canResolvePosts: true,
    canAccessOwnMedia: false,
    canAccessAuthorizedPrivateMedia: false,
    canDownloadImages: true,
    canDownloadVideos: true,
    supportsCarousel: false,
    supportsOfficialApi: false,
    privateContentNote:
        'Pinterest links use the existing public-only path; secret Pins are not accessed.',
  );

  @override
  Future<Post> resolveSharedUrl(String text) => extractors.extract(text);
}

class TikTokProvider extends BasePlatformProvider {
  TikTokProvider({required super.extractors, required super.bridge});

  @override
  PlatformKind get platform => PlatformKind.tiktok;

  @override
  PlatformCapabilities get capabilities => const PlatformCapabilities(
    canAuthenticate: false,
    canResolvePosts: true,
    canAccessOwnMedia: false,
    canAccessAuthorizedPrivateMedia: false,
    canDownloadImages: false,
    canDownloadVideos: false,
    supportsCarousel: false,
    supportsOfficialApi: true,
    privateContentNote:
        'Public oEmbed previews only. The Display API does not expose a downloadable video file.',
  );

  @override
  Future<Post> resolveSharedUrl(String text) => extractors.extract(text);
}

class FacebookProvider extends BasePlatformProvider {
  FacebookProvider({required super.extractors, required super.bridge});

  @override
  PlatformKind get platform => PlatformKind.facebook;

  @override
  PlatformCapabilities get capabilities => const PlatformCapabilities(
    canAuthenticate: false,
    canResolvePosts: false,
    canAccessOwnMedia: false,
    canAccessAuthorizedPrivateMedia: false,
    canDownloadImages: false,
    canDownloadVideos: false,
    supportsCarousel: false,
    supportsOfficialApi: false,
    unavailableNote:
        'A reviewed Facebook Graph API configuration is not implemented in this build.',
  );

  @override
  Future<Post> resolveSharedUrl(
    String text,
  ) async => throw const GatherException(
    'facebook_api_unavailable',
    'Gather recognizes this Facebook link, but this build has no reviewed Graph API integration that can return its media. No Facebook page scraping is used.',
  );
}

class YouTubeProvider extends BasePlatformProvider {
  YouTubeProvider({required super.extractors, required super.bridge});

  @override
  PlatformKind get platform => PlatformKind.youtube;

  @override
  PlatformCapabilities get capabilities => const PlatformCapabilities(
    canAuthenticate: false,
    canResolvePosts: false,
    canAccessOwnMedia: false,
    canAccessAuthorizedPrivateMedia: false,
    canDownloadImages: false,
    canDownloadVideos: false,
    supportsCarousel: false,
    supportsOfficialApi: false,
    unavailableNote:
        'YouTube video downloads require prior written approval under YouTube’s developer policies.',
  );

  @override
  Future<Post> resolveSharedUrl(
    String text,
  ) async => throw const GatherException(
    'youtube_download_restricted',
    'YouTube links are recognized, but this app cannot download YouTube audiovisual content without prior written approval. Use YouTube’s own permitted offline features.',
  );
}

class PlatformProviderRegistry {
  PlatformProviderRegistry({
    required ExtractorRegistry extractors,
    required NativeBridge bridge,
    required InstagramAuthService instagramAuth,
    required XAuthService xAuth,
  }) : _providers = {
         PlatformKind.instagram: InstagramProvider(
           extractors: extractors,
           bridge: bridge,
           auth: instagramAuth,
         ),
         PlatformKind.x: XProvider(
           extractors: extractors,
           bridge: bridge,
           auth: xAuth,
         ),
         PlatformKind.facebook: FacebookProvider(
           extractors: extractors,
           bridge: bridge,
         ),
         PlatformKind.tiktok: TikTokProvider(
           extractors: extractors,
           bridge: bridge,
         ),
         PlatformKind.youtube: YouTubeProvider(
           extractors: extractors,
           bridge: bridge,
         ),
         PlatformKind.pinterest: PinterestProvider(
           extractors: extractors,
           bridge: bridge,
         ),
       };

  final Map<PlatformKind, PlatformProvider> _providers;

  List<PlatformProvider> get providers => List.unmodifiable(_providers.values);

  PlatformProvider providerFor(PlatformKind platform) {
    final provider = _providers[platform];
    if (provider == null) {
      throw const GatherException(
        'unsupported_url',
        'This platform is not supported.',
      );
    }
    return provider;
  }

  Future<ResolvedProviderPost> resolveSharedUrl(String text) async {
    final link = PostLink.parse(text);
    final provider = providerFor(link.platform);
    final post = await provider.resolveSharedUrl(text);
    return ResolvedProviderPost(post: post, provider: provider);
  }
}

Post _withAccess(Post post, PostAccess access) => Post(
  platform: post.platform,
  source: post.source,
  id: post.id,
  title: post.title,
  mediaItems: post.mediaItems,
  accountName: post.accountName,
  access: access,
);
