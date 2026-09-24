import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';
import 'native_bridge.dart';

class XHttpResponse {
  const XHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final Map<String, dynamic> body;
}

abstract interface class XHttpTransport {
  Future<XHttpResponse> get(Uri uri, {Map<String, String> headers = const {}});
  Future<XHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  });
}

class IoXHttpTransport implements XHttpTransport {
  IoXHttpTransport({HttpClient? client})
    : _client = client ?? HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);

  final HttpClient _client;

  @override
  Future<XHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) => _send(uri, headers: headers);

  @override
  Future<XHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) => _send(uri, headers: headers, body: body);

  Future<XHttpResponse> _send(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const GatherException(
        'x_api_url',
        'X API requests must use HTTPS.',
      );
    }
    try {
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
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const GatherException(
            'x_api_response',
            'X returned an unexpectedly large response.',
          );
        }
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      return XHttpResponse(
        response.statusCode,
        decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{},
      );
    } on GatherException {
      rethrow;
    } on TimeoutException {
      throw const GatherException(
        'x_network',
        'X took too long to respond. Check your connection and try again.',
      );
    } on SocketException {
      throw const GatherException(
        'x_network',
        'Gather could not reach X. Check your internet connection.',
      );
    } on HandshakeException {
      throw const GatherException(
        'x_network',
        'A secure connection to X could not be established.',
      );
    } on HttpException {
      throw const GatherException(
        'x_network',
        'The connection to X was interrupted. Try again.',
      );
    }
  }
}

class XSession {
  const XSession({
    required this.accessToken,
    required this.expiresAt,
    required this.userId,
    required this.username,
    required this.name,
    this.refreshToken,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final String userId;
  final String username;
  final String name;

  factory XSession.fromJson(Map<String, dynamic> json) {
    final accessToken = json['accessToken'];
    final expiresAt = DateTime.tryParse('${json['expiresAt'] ?? ''}');
    final userId = json['userId'];
    final username = json['username'];
    final name = json['name'];
    final refreshToken = json['refreshToken'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        expiresAt == null ||
        userId is! String ||
        userId.isEmpty ||
        username is! String ||
        username.isEmpty ||
        name is! String ||
        (refreshToken != null && refreshToken is! String)) {
      throw const FormatException('Invalid X account session');
    }
    return XSession(
      accessToken: accessToken,
      refreshToken: refreshToken as String?,
      expiresAt: expiresAt,
      userId: userId,
      username: username,
      name: name,
    );
  }

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
    'userId': userId,
    'username': username,
    'name': name,
  };
}

class XAuthService {
  XAuthService({
    required NativeBridge bridge,
    XHttpTransport? transport,
    Uri? authServer,
  }) : _bridge = bridge,
       _transport = transport ?? IoXHttpTransport(),
       _authServer = authServer ?? _configuredAuthServer;

  static final Uri? _configuredAuthServer = _configuredServerUri();
  final NativeBridge _bridge;
  final XHttpTransport _transport;
  final Uri? _authServer;
  XSession? session;
  int sessionEpoch = 0;
  String? _pendingAttempt;
  String? _handoffSecret;
  bool _disconnecting = false;

  bool get isConfigured => _authServer != null;

  static Uri? _configuredServerUri() {
    const value = String.fromEnvironment('X_AUTH_SERVER');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.replace(path: '');
  }

  Future<XSession?> restore() async {
    final stored = await _bridge.readProviderAuth('x');
    if (stored == null || stored.isEmpty) return null;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(stored) as Map);
      _pendingAttempt = data['pendingAttempt'] as String?;
      _handoffSecret = data['handoffSecret'] as String?;
      final saved = data['session'];
      session = saved is Map
          ? XSession.fromJson(Map<String, dynamic>.from(saved))
          : null;
      if (session != null) sessionEpoch++;
      return session;
    } on Object {
      await _bridge.clearProviderAuth('x');
      session = null;
      _pendingAttempt = null;
      _handoffSecret = null;
      throw const GatherException(
        'x_secure_storage',
        'Saved X authorization could not be decrypted. Connect the account again.',
      );
    }
  }

  Future<void> _persist() => _bridge.writeProviderAuth(
    'x',
    jsonEncode({
      'version': 1,
      'pendingAttempt': _pendingAttempt,
      'handoffSecret': _handoffSecret,
      'session': session?.toJson(),
    }),
  );

  Future<void> authenticate() async {
    final base = _authServer;
    if (base == null) {
      throw const GatherException(
        'x_setup',
        'X sign-in is not configured. Set X_AUTH_SERVER to your HTTPS OAuth backend and rebuild Gather.',
      );
    }
    final random = math.Random.secure();
    final handoff = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final response = await _transport.post(
      base.resolve('/v1/x/oauth/start'),
      body: jsonEncode({'handoffSecret': handoff}),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _backendError(response);
    }
    final authorizationUrl = Uri.tryParse(
      response.body['authorizationUrl'] as String? ?? '',
    );
    final attemptId = response.body['attemptId'];
    final scopes =
        authorizationUrl?.queryParameters['scope']?.split(' ').toSet() ??
        const <String>{};
    if (authorizationUrl == null ||
        authorizationUrl.scheme != 'https' ||
        authorizationUrl.host != 'x.com' ||
        authorizationUrl.path != '/i/oauth2/authorize' ||
        authorizationUrl.queryParameters['response_type'] != 'code' ||
        authorizationUrl.queryParameters['code_challenge_method'] != 'S256' ||
        (authorizationUrl.queryParameters['code_challenge']?.isEmpty ?? true) ||
        !scopes.containsAll(const {
          'tweet.read',
          'users.read',
          'offline.access',
        }) ||
        attemptId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{40,64}$').hasMatch(attemptId)) {
      throw const GatherException(
        'x_setup',
        'The X OAuth service returned an invalid sign-in request.',
      );
    }
    _pendingAttempt = attemptId;
    _handoffSecret = handoff;
    await _persist();
    try {
      await _bridge.openProviderAuthorization('x', authorizationUrl.toString());
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
        uri.host != 'x-auth' ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        _pendingAttempt == null ||
        _handoffSecret == null) {
      return;
    }
    final base = _authServer;
    if (base == null) {
      throw const GatherException('x_setup', 'X OAuth is not configured.');
    }
    final response = await _transport.post(
      base.resolve('/v1/x/oauth/poll'),
      body: jsonEncode({
        'attemptId': _pendingAttempt,
        'handoffSecret': _handoffSecret,
      }),
    );
    if (response.statusCode == 202 || response.body['status'] == 'pending') {
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
        'x_auth_response',
        'X did not return an authenticated account session.',
      );
    }
    session = XSession.fromJson(Map<String, dynamic>.from(payload));
    sessionEpoch++;
    _pendingAttempt = null;
    _handoffSecret = null;
    await _persist();
  }

  Future<void> processPendingCallbacks() async {
    for (final callback in await _bridge.takeProviderAuthCallbacks('x')) {
      await handleOAuthCallback(callback);
    }
  }

  Future<XSession> validSession({bool forceRefresh = false}) async {
    final active = session;
    if (active == null) {
      throw const GatherException(
        'x_auth_required',
        'Connect your X account to ask the official API for this post.',
      );
    }
    if (forceRefresh ||
        active.expiresAt.isBefore(
          DateTime.now().add(const Duration(minutes: 2)),
        )) {
      return _refresh(active);
    }
    return active;
  }

  Future<XSession> _refresh(XSession old) async {
    final base = _authServer;
    final refreshToken = old.refreshToken;
    if (base == null || refreshToken == null || refreshToken.isEmpty) {
      await disconnect(revoke: false);
      throw const GatherException(
        'x_auth_expired',
        'X authorization expired or was revoked. Connect the account again.',
      );
    }
    final response = await _transport.post(
      base.resolve('/v1/x/oauth/refresh'),
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    if (response.statusCode == 401 ||
        response.body['code'] == 'reauthentication_required') {
      await disconnect(revoke: false);
      throw const GatherException(
        'x_auth_expired',
        'X authorization expired or was revoked. Connect the account again.',
      );
    }
    if (response.statusCode != 200) throw _backendError(response);
    final accessToken = response.body['accessToken'];
    final expiresIn = response.body['expiresIn'];
    final rotatedRefresh = response.body['refreshToken'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        expiresIn is! int ||
        expiresIn <= 0 ||
        (rotatedRefresh != null && rotatedRefresh is! String)) {
      throw const GatherException(
        'x_auth_response',
        'X returned invalid refreshed authorization details.',
      );
    }
    session = XSession(
      accessToken: accessToken,
      refreshToken: rotatedRefresh as String? ?? old.refreshToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      userId: old.userId,
      username: old.username,
      name: old.name,
    );
    await _persist();
    return session!;
  }

  Future<void> disconnect({bool revoke = true}) async {
    if (_disconnecting) return;
    _disconnecting = true;
    final old = session;
    session = null;
    sessionEpoch++;
    _pendingAttempt = null;
    _handoffSecret = null;
    Object? revokeError;
    try {
      if (revoke && old != null && _authServer != null) {
        final response = await _transport.post(
          _authServer.resolve('/v1/x/oauth/revoke'),
          body: jsonEncode({'token': old.refreshToken ?? old.accessToken}),
        );
        if (response.statusCode != 200) revokeError = _backendError(response);
      }
    } catch (error) {
      revokeError = error;
    } finally {
      await _bridge.clearProviderAuth('x');
      _disconnecting = false;
    }
    if (revokeError != null) {
      throw GatherException(
        'x_revoke',
        'X was disconnected from this device, but remote token revocation could not be confirmed. Revoke Gather in X account settings if needed. $revokeError',
      );
    }
  }

  GatherException _backendError(XHttpResponse response) {
    final code = response.body['code'];
    if (response.statusCode == 429 || code == 'rate_limited') {
      return const GatherException(
        'x_rate_limited',
        'X is rate limiting requests. Wait and try again.',
      );
    }
    if (response.statusCode >= 500) {
      return const GatherException(
        'x_backend',
        'The X authorization service is temporarily unavailable.',
      );
    }
    if (code == 'access_denied') {
      return const GatherException(
        'x_auth_cancelled',
        'X authorization was declined.',
      );
    }
    return GatherException(
      code is String ? code : 'x_auth',
      response.body['message'] is String
          ? response.body['message'] as String
          : 'X could not complete authorization. Reconnect the account if needed.',
    );
  }
}

class XPostApi {
  XPostApi({required XAuthService auth, XHttpTransport? transport})
    : _auth = auth,
      _transport = transport ?? IoXHttpTransport();

  final XAuthService _auth;
  final XHttpTransport _transport;

  Future<Post> getPost(PostLink link) async {
    if (link.platform != PlatformKind.x ||
        !RegExp(r'^\d{1,19}$').hasMatch(link.id)) {
      throw const GatherException(
        'unsupported_url',
        'This is not a supported X post URL.',
      );
    }
    var active = await _auth.validSession();
    var response = await _lookup(link, active);
    if (response.statusCode == 401) {
      active = await _auth.validSession(forceRefresh: true);
      response = await _lookup(link, active);
    }
    if (response.statusCode == 401) {
      await _auth.disconnect(revoke: false);
      throw const GatherException(
        'x_auth_expired',
        'X authorization expired or was revoked. Connect the account again.',
      );
    }
    if (response.statusCode == 404 || _hasError(response, {34, 50})) {
      throw const GatherException(
        'x_post_deleted',
        'This X post was deleted or is unavailable through the official API.',
      );
    }
    if (response.statusCode == 403) {
      throw const GatherException(
        'x_access_denied',
        'X did not authorize this account to access the post. Protected content is unavailable through the API.',
      );
    }
    if (response.statusCode == 429) {
      throw const GatherException(
        'x_rate_limited',
        'X is rate limiting post lookups. Wait and try again.',
      );
    }
    if (response.statusCode >= 500) {
      throw const GatherException(
        'x_api_unavailable',
        'The X API is temporarily unavailable. Try again later.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const GatherException(
        'x_post_unavailable',
        'X could not return this post to the connected account.',
      );
    }
    return _toPost(link, response.body, active);
  }

  Future<XHttpResponse> _lookup(PostLink link, XSession session) {
    final uri = Uri.https('api.x.com', '/2/tweets/${link.id}', {
      'tweet.fields': 'id,text,author_id,attachments,possibly_sensitive',
      'expansions': 'author_id,attachments.media_keys',
      'user.fields': 'id,name,username,protected',
      'media.fields':
          'media_key,type,url,preview_image_url,width,height,duration_ms',
    });
    return _transport.get(
      uri,
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
    );
  }

  Post _toPost(PostLink link, Map<String, dynamic> body, XSession session) {
    final data = body['data'];
    if (data is! Map || '${data['id']}' != link.id) {
      throw const GatherException(
        'x_post_unavailable',
        'X did not return the requested post.',
      );
    }
    final post = Map<String, dynamic>.from(data);
    final includes = body['includes'] is Map
        ? Map<String, dynamic>.from(body['includes'] as Map)
        : <String, dynamic>{};
    final authorId = '${post['author_id'] ?? ''}';
    final users = includes['users'] is List
        ? includes['users'] as List
        : const [];
    final author = users
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .firstWhere(
          (user) => '${user['id']}' == authorId,
          orElse: () => <String, dynamic>{},
        );
    final protected = author['protected'] == true;
    final access = authorId == session.userId
        ? PostAccess.ownAccount
        : protected
        ? PostAccess.authorizedPrivate
        : PostAccess.public;
    final includeMedia = includes['media'] is List
        ? includes['media'] as List
        : const [];
    final mediaByKey = <String, Map<String, dynamic>>{};
    for (final raw in includeMedia.whereType<Map>()) {
      final media = Map<String, dynamic>.from(raw);
      if (media['media_key'] is String) {
        mediaByKey[media['media_key'] as String] = media;
      }
    }
    final attachments = post['attachments'] is Map
        ? Map<String, dynamic>.from(post['attachments'] as Map)
        : <String, dynamic>{};
    final keys = attachments['media_keys'] is List
        ? attachments['media_keys'] as List
        : const [];
    final mediaItems = <MediaItem>[];
    for (final key in keys.whereType<String>()) {
      final media = mediaByKey[key];
      if (media == null) continue;
      final type = media['type'];
      final preview = media['preview_image_url'];
      final thumbnail = preview is String && isMediaUrl(preview, PlatformKind.x)
          ? preview
          : null;
      if (type == 'photo') {
        final url = media['url'];
        if (url is String && isMediaUrl(url, PlatformKind.x)) {
          mediaItems.add(
            MediaItem(
              type: 'image',
              thumbnail: thumbnail ?? url,
              qualities: [
                Quality(
                  url,
                  'API source',
                  width: media['width'] is num
                      ? (media['width'] as num).toInt()
                      : null,
                  height: media['height'] is num
                      ? (media['height'] as num).toInt()
                      : null,
                ),
              ],
            ),
          );
        }
      } else if (type == 'video' || type == 'animated_gif') {
        final variants = media['variants'] is List
            ? media['variants'] as List
            : const [];
        final urls = <Quality>[];
        for (final rawVariant in variants.whereType<Map>()) {
          final variant = Map<String, dynamic>.from(rawVariant);
          final url = variant['url'];
          if (variant['content_type'] == 'video/mp4' &&
              url is String &&
              isMediaUrl(url, PlatformKind.x)) {
            urls.add(Quality(url, 'MP4 · X API source'));
          }
        }
        final url = media['url'];
        if (urls.isEmpty && url is String && isMediaUrl(url, PlatformKind.x)) {
          urls.add(Quality(url, 'X API source'));
        }
        if (urls.isNotEmpty) {
          mediaItems.add(
            MediaItem(type: 'video', thumbnail: thumbnail, qualities: urls),
          );
        }
      }
    }
    if (mediaItems.isEmpty) {
      throw const GatherException(
        'x_media_unavailable',
        'The X API returned no downloadable media for this post. It may contain unsupported media or the API may not expose a media file.',
      );
    }
    final name =
        author['name'] is String && (author['name'] as String).isNotEmpty
        ? author['name'] as String
        : session.name;
    return Post(
      platform: PlatformKind.x,
      source: link.uri,
      id: link.id,
      title:
          post['text'] is String && (post['text'] as String).trim().isNotEmpty
          ? (post['text'] as String).trim()
          : 'X post ${link.id}',
      accountName: name,
      mediaItems: mediaItems,
      access: access,
    );
  }

  bool _hasError(XHttpResponse response, Set<int> codes) {
    final errors = response.body['errors'];
    if (errors is! List) return false;
    return errors.whereType<Map>().any(
      (error) => codes.contains(error['code']),
    );
  }
}
