import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';
import 'native_bridge.dart';

class InstagramSession {
  const InstagramSession({
    required this.accessToken,
    required this.expiresAt,
    required this.userId,
    required this.username,
    required this.apiVersion,
  });

  final String accessToken;
  final DateTime expiresAt;
  final String userId;
  final String username;
  final String apiVersion;

  factory InstagramSession.fromJson(Map<String, dynamic> json) {
    final accessToken = json['accessToken'];
    final expiresAt = json['expiresAt'];
    final userId = json['userId'];
    final username = json['username'];
    final apiVersion = json['apiVersion'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 10000 ||
        expiresAt is! int ||
        userId is! String ||
        username is! String ||
        apiVersion is! String ||
        !RegExp(r'^v\d+\.\d+$').hasMatch(apiVersion)) {
      throw const GatherException(
        'instagram_session',
        'Instagram authorization data is invalid. Connect the account again.',
      );
    }
    return InstagramSession(
      accessToken: accessToken,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      userId: userId,
      username: username,
      apiVersion: apiVersion,
    );
  }

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'userId': userId,
    'username': username,
    'apiVersion': apiVersion,
  };

  InstagramSession withToken(String token, DateTime expiry) => InstagramSession(
    accessToken: token,
    expiresAt: expiry,
    userId: userId,
    username: username,
    apiVersion: apiVersion,
  );
}

class InstagramHttpResponse {
  const InstagramHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final Map<String, dynamic> body;
}

abstract interface class InstagramHttpTransport {
  Future<InstagramHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  });

  Future<InstagramHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  });
}

class IoInstagramHttpTransport implements InstagramHttpTransport {
  IoInstagramHttpTransport({HttpClient? client})
    : _client = client ?? HttpClient();
  final HttpClient _client;

  @override
  Future<InstagramHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) => _send(uri, headers: headers);

  @override
  Future<InstagramHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) => _send(uri, headers: headers, body: body);

  Future<InstagramHttpResponse> _send(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    try {
      return await _sendRequest(uri, headers: headers, body: body);
    } on GatherException {
      rethrow;
    } on TimeoutException {
      throw const GatherException(
        'instagram_network',
        'Instagram took too long to respond. Check your connection and try again.',
      );
    } on IOException {
      throw const GatherException(
        'instagram_network',
        'Gather could not reach Instagram. Check your connection and try again.',
      );
    }
  }

  Future<InstagramHttpResponse> _sendRequest(
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = body == null
        ? await _client.getUrl(uri).timeout(const Duration(seconds: 15))
        : await _client.postUrl(uri).timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 25));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const GatherException(
          'instagram_response_size',
          'Instagram returned an unexpectedly large response.',
        );
      }
      bytes.addAll(chunk);
    }
    final decoded = utf8.decode(bytes, allowMalformed: true);
    Object? value;
    try {
      value = jsonDecode(decoded);
    } on FormatException {
      value = null;
    }
    return InstagramHttpResponse(
      response.statusCode,
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
    );
  }
}

class InstagramAuthService {
  InstagramAuthService({
    required NativeBridge bridge,
    InstagramHttpTransport? transport,
    Uri? authServer,
  }) : _bridge = bridge,
       _transport = transport ?? IoInstagramHttpTransport(),
       _authServer = authServer ?? _configuredAuthServer;

  static final Uri? _configuredAuthServer = _configuredServerUri();
  final NativeBridge _bridge;
  final InstagramHttpTransport _transport;
  final Uri? _authServer;
  InstagramSession? session;
  String? _pendingAttempt;
  String? _handoffSecret;

  static Uri? _configuredServerUri() {
    const value = String.fromEnvironment('INSTAGRAM_AUTH_SERVER');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.path.isNotEmpty && uri.path != '/') {
      return null;
    }
    if (uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment) {
      return uri.replace(path: '');
    }
    return null;
  }

  bool get isConfigured => _authServer != null;

  Future<InstagramSession?> restore() async {
    final stored = await _bridge.readInstagramAuth();
    if (stored == null || stored.isEmpty) return null;
    try {
      final state = jsonDecode(stored);
      if (state is! Map) throw const FormatException('Expected auth state');
      final data = Map<String, dynamic>.from(state);
      final pending = data['pendingAttempt'];
      _pendingAttempt = pending is String ? pending : null;
      final handoffSecret = data['handoffSecret'];
      _handoffSecret = handoffSecret is String ? handoffSecret : null;
      final saved = data['session'];
      session = saved is Map
          ? InstagramSession.fromJson(Map<String, dynamic>.from(saved))
          : null;
      return session;
    } on Object {
      await _bridge.clearInstagramAuth();
      session = null;
      _pendingAttempt = null;
      throw const GatherException(
        'instagram_secure_storage',
        'Saved Instagram authorization could not be decrypted. Connect the account again.',
      );
    }
  }

  Future<void> _persist() async {
    await _bridge.writeInstagramAuth(
      jsonEncode({
        'version': 1,
        'pendingAttempt': _pendingAttempt,
        'handoffSecret': _handoffSecret,
        'session': session?.toJson(),
      }),
    );
  }

  Future<void> beginConnect() async {
    final base = _authServer;
    if (base == null) {
      throw const GatherException(
        'instagram_setup',
        'Instagram sign-in is not configured. Set INSTAGRAM_AUTH_SERVER to your HTTPS OAuth backend and rebuild Gather.',
      );
    }
    final secureRandom = math.Random.secure();
    final secretBytes = List<int>.generate(
      32,
      (_) => secureRandom.nextInt(256),
    );
    final handoffSecret = base64Url.encode(secretBytes).replaceAll('=', '');
    final response = await _transport.post(
      base.resolve('/v1/instagram/oauth/start'),
      body: jsonEncode({'handoffSecret': handoffSecret}),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _backendError(response);
    }
    final authorizationUrl = Uri.tryParse(
      response.body['authorizationUrl'] as String? ?? '',
    );
    final attemptId = response.body['attemptId'];
    if (authorizationUrl == null ||
        authorizationUrl.scheme != 'https' ||
        authorizationUrl.host != 'www.instagram.com' ||
        authorizationUrl.path != '/oauth/authorize' ||
        attemptId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{40,64}$').hasMatch(attemptId)) {
      throw const GatherException(
        'instagram_setup',
        'The Instagram OAuth service returned an invalid sign-in request.',
      );
    }
    _pendingAttempt = attemptId;
    _handoffSecret = handoffSecret;
    await _persist();
    try {
      await _bridge.openInstagramAuthorization(authorizationUrl.toString());
    } catch (_) {
      _pendingAttempt = null;
      _handoffSecret = null;
      await _persist();
      rethrow;
    }
  }

  Future<void> handleOAuthCallback(String rawUri) async {
    final uri = Uri.tryParse(rawUri);
    if (uri == null ||
        uri.scheme != 'gather' ||
        uri.host != 'instagram-auth' ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        _pendingAttempt == null ||
        _handoffSecret == null) {
      return;
    }
    final base = _authServer;
    if (base == null) {
      throw const GatherException(
        'instagram_setup',
        'Instagram OAuth is not configured.',
      );
    }
    final response = await _transport.post(
      base.resolve('/v1/instagram/oauth/poll'),
      body: jsonEncode({
        'attemptId': _pendingAttempt,
        'handoffSecret': _handoffSecret,
      }),
    );
    if (response.statusCode == 202 || response.body['status'] == 'pending') {
      // A forged generic deep link must not cancel an in-progress sign-in.
      return;
    }
    if (response.statusCode != 200 || response.body['status'] != 'ready') {
      _pendingAttempt = null;
      _handoffSecret = null;
      await _persist();
      throw _backendError(response);
    }
    final payload = response.body['session'];
    if (payload is! Map) {
      throw const GatherException(
        'instagram_auth_response',
        'Instagram did not return an account session.',
      );
    }
    session = InstagramSession.fromJson(Map<String, dynamic>.from(payload));
    _pendingAttempt = null;
    _handoffSecret = null;
    await _persist();
  }

  Future<void> processPendingCallbacks() async {
    final callbacks = await _bridge.takeInstagramAuthCallbacks();
    for (final callback in callbacks) {
      await handleOAuthCallback(callback);
    }
  }

  Future<void> disconnect() async {
    session = null;
    _pendingAttempt = null;
    _handoffSecret = null;
    await _bridge.clearInstagramAuth();
  }

  Future<Post> resolveOwnedPost(PostLink link) async {
    var active = session;
    if (active == null) {
      throw const GatherException(
        'instagram_auth_required',
        'Connect your Instagram Professional account to resolve its own post links.',
      );
    }
    if (active.expiresAt.isBefore(
      DateTime.now().add(const Duration(days: 7)),
    )) {
      active = await _refresh(active);
    }
    final mediaApi = InstagramMediaApi(transport: _transport);
    try {
      return await mediaApi.resolveOwnedPost(link, active);
    } on GatherException catch (e) {
      if (e.code != 'instagram_reauth') rethrow;
      active = await _refresh(active);
      return mediaApi.resolveOwnedPost(link, active);
    }
  }

  Future<InstagramSession> _refresh(InstagramSession old) async {
    final base = _authServer;
    if (base == null) {
      throw const GatherException(
        'instagram_reauth',
        'Instagram authorization is expiring. Configure the OAuth backend and reconnect your account.',
      );
    }
    final response = await _transport.post(
      base.resolve('/v1/instagram/oauth/refresh'),
      body: jsonEncode({'accessToken': old.accessToken}),
    );
    if (response.statusCode == 401 ||
        response.body['code'] == 'reauthentication_required') {
      await disconnect();
      throw const GatherException(
        'instagram_reauth',
        'Instagram authorization expired or was revoked. Reconnect your Professional account.',
      );
    }
    if (response.statusCode != 200) throw _backendError(response);
    final token = response.body['accessToken'];
    final expiresIn = response.body['expiresIn'];
    if (token is! String ||
        token.isEmpty ||
        expiresIn is! int ||
        expiresIn <= 0) {
      throw const GatherException(
        'instagram_auth_response',
        'Instagram returned an invalid refreshed authorization.',
      );
    }
    session = old.withToken(
      token,
      DateTime.now().add(Duration(seconds: expiresIn)),
    );
    await _persist();
    return session!;
  }

  GatherException _backendError(InstagramHttpResponse response) {
    final code = response.body['code'];
    if (response.statusCode == 429 || code == 'rate_limited') {
      return const GatherException(
        'instagram_rate_limited',
        'Instagram is receiving too many requests. Wait a little and try again.',
      );
    }
    if (response.statusCode >= 500) {
      return const GatherException(
        'instagram_backend',
        'The Instagram authorization service is temporarily unavailable.',
      );
    }
    if (code == 'access_denied') {
      return const GatherException(
        'instagram_auth_cancelled',
        'Instagram authorization was declined.',
      );
    }
    if (code == 'attempt_expired') {
      return const GatherException(
        'instagram_auth_timeout',
        'Instagram sign-in expired. Connect the account again.',
      );
    }
    return GatherException(
      code is String ? code : 'instagram_auth',
      response.body['message'] is String
          ? response.body['message'] as String
          : 'Instagram could not complete this request. Connect the account again if needed.',
    );
  }
}

class InstagramMediaApi {
  InstagramMediaApi({
    InstagramHttpTransport? transport,
    this.maximumPages = 100,
  }) : _transport = transport ?? IoInstagramHttpTransport();

  final InstagramHttpTransport _transport;
  final int maximumPages;
  static const _fields =
      'id,caption,media_type,media_url,permalink,timestamp,username,thumbnail_url,children{media_type,media_url,thumbnail_url}';

  Future<Post> resolveOwnedPost(PostLink link, InstagramSession session) async {
    if (link.platform != PlatformKind.instagram || maximumPages < 1) {
      throw const GatherException(
        'unsupported',
        'This is not a supported Instagram post link.',
      );
    }
    final wantedPath = _canonicalPath(link.uri);
    if (wantedPath == null) {
      throw const GatherException(
        'unsupported',
        'This is not a supported Instagram post link.',
      );
    }
    String? after;
    final seenCursors = <String>{};
    final base = Uri.https(
      'graph.instagram.com',
      '/${session.apiVersion}/me/media',
    );
    for (var page = 0; page < maximumPages; page++) {
      final query = <String, String>{'fields': _fields, 'limit': '100'};
      if (after != null) query['after'] = after;
      final uri = base.replace(queryParameters: query);
      final response = await _get(
        uri,
        headers: {'Authorization': 'Bearer ${session.accessToken}'},
      );
      _checkGraphResponse(response);
      final rows = response.body['data'];
      if (rows is! List) {
        throw const GatherException(
          'instagram_response',
          'Instagram returned an invalid media list.',
        );
      }
      for (final raw in rows) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final permalink = Uri.tryParse(item['permalink'] as String? ?? '');
        if (_canonicalPath(permalink) == wantedPath) {
          return _toPost(item, link, session.username);
        }
      }
      final paging = response.body['paging'];
      final cursors = paging is Map ? paging['cursors'] : null;
      final cursor = cursors is Map ? cursors['after'] : null;
      if (cursor is! String || cursor.isEmpty || !seenCursors.add(cursor)) {
        return _notFound();
      }
      after = cursor;
    }
    throw const GatherException(
      'instagram_archive_limit',
      'This post is older than the current Instagram account search limit. Try a newer post.',
    );
  }

  Future<InstagramHttpResponse> _get(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    try {
      return await _transport.get(uri, headers: headers);
    } on GatherException {
      rethrow;
    } on TimeoutException {
      throw const GatherException(
        'instagram_network',
        'Instagram took too long to respond. Check your connection and try again.',
      );
    } on IOException {
      throw const GatherException(
        'instagram_network',
        'Gather could not reach Instagram. Check your connection and try again.',
      );
    }
  }

  void _checkGraphResponse(InstagramHttpResponse response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final error = response.body['error'];
    final code = error is Map ? error['code'] : null;
    if (response.statusCode == 401 || code == 190) {
      throw const GatherException(
        'instagram_reauth',
        'Instagram authorization expired or was revoked. Reconnect your Professional account.',
      );
    }
    if (response.statusCode == 429 ||
        const {'4', '17', '32', '613'}.contains(code.toString())) {
      throw const GatherException(
        'instagram_rate_limited',
        'Instagram is receiving too many requests. Wait a little and try again.',
      );
    }
    if (response.statusCode >= 500) {
      throw const GatherException(
        'instagram_network',
        'Instagram is temporarily unavailable. Try again later.',
      );
    }
    throw GatherException(
      'instagram_api',
      response.statusCode == 403
          ? 'Instagram denied this API request. Check the app review and account permissions.'
          : 'Instagram could not return this account’s media (HTTP ${response.statusCode}).',
    );
  }

  Post _toPost(Map<String, dynamic> item, PostLink link, String accountName) {
    final mediaItems = <MediaItem>[];
    final parentType = item['media_type'];
    if (parentType == 'CAROUSEL_ALBUM') {
      final children = item['children'];
      final rows = children is Map ? children['data'] : null;
      if (rows is List) {
        for (final child in rows) {
          if (child is Map) {
            final media = _toMedia(Map<String, dynamic>.from(child));
            if (media != null) mediaItems.add(media);
          }
        }
      }
    } else {
      final media = _toMedia(item);
      if (media != null) mediaItems.add(media);
    }
    if (mediaItems.isEmpty) {
      throw const GatherException(
        'instagram_media_unavailable',
        'Instagram did not provide a downloadable original for this post.',
      );
    }
    final title =
        item['caption'] is String &&
            (item['caption'] as String).trim().isNotEmpty
        ? (item['caption'] as String).trim()
        : 'Instagram post';
    final username =
        item['username'] is String && (item['username'] as String).isNotEmpty
        ? item['username'] as String
        : accountName;
    return Post(
      platform: PlatformKind.instagram,
      source: link.uri,
      id: link.id,
      title: title,
      accountName: username,
      mediaItems: mediaItems,
      access: PostAccess.ownAccount,
    );
  }

  MediaItem? _toMedia(Map<String, dynamic> item) {
    final type = switch (item['media_type']) {
      'IMAGE' => 'image',
      'VIDEO' => 'video',
      _ => null,
    };
    final url = item['media_url'];
    if (type == null ||
        url is! String ||
        !isMediaUrl(url, PlatformKind.instagram)) {
      return null;
    }
    final thumbnail = item['thumbnail_url'];
    return MediaItem(
      type: type,
      thumbnail:
          thumbnail is String && isMediaUrl(thumbnail, PlatformKind.instagram)
          ? thumbnail
          : null,
      qualities: [Quality(url, 'Original')],
    );
  }

  Post _notFound() => throw const GatherException(
    'instagram_owned_media_not_found',
    'This post was not found in the connected Professional account. Only that account’s API-listed posts can use this authorized path.',
  );

  String? _canonicalPath(Uri? uri) {
    if (uri == null ||
        uri.scheme != 'https' ||
        !const {
          'instagram.com',
          'www.instagram.com',
        }.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    final match = RegExp(
      r'^/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)/?$',
    ).firstMatch(uri.path);
    if (match == null) return null;
    return '/${uri.pathSegments.first}/${match[1]}';
  }
}
