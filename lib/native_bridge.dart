import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeBridge extends ChangeNotifier {
  static const channel = MethodChannel('app.gather/native');
  Map<String, dynamic> settings = {
    'darkMode': 'system',
    'wifiOnly': false,
    'folderName': 'Pictures/Gather · Movies/Gather',
    'folderUri': '',
    'accepted': false,
  };
  List<Map<String, dynamic>> jobs = [];
  String? error;
  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;
  Future<void> Function()? onShares;
  Future<void> Function()? onInstagramAuth;
  Future<void> Function()? onXAuth;

  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sharesAvailable') {
        await onShares?.call();
      } else if (call.method == 'instagramAuthAvailable') {
        await onInstagramAuth?.call();
      } else if (call.method == 'xAuthAvailable') {
        await onXAuth?.call();
      }
    });
    await refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) {
      return;
    }
    _refreshing = true;
    try {
      final state = await channel.invokeMapMethod<String, dynamic>('getState');
      if (state == null) {
        throw PlatformException(
          code: 'empty',
          message: 'Android returned no download state.',
        );
      }
      settings = Map<String, dynamic>.from(state['settings'] as Map);
      jobs = (state['jobs'] as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList();
      error = null;
    } on PlatformException catch (e) {
      error = e.message ?? 'Could not read Android download state.';
    } on MissingPluginException {
      error =
          'Gather requires its Android service. Install the Android APK to download files.';
    } finally {
      _refreshing = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<List<String>> takeShares() async =>
      (await channel.invokeListMethod<String>('takeShares')) ?? [];
  Future<List<String>> takeInstagramAuthCallbacks() async =>
      (await channel.invokeListMethod<String>('takeInstagramAuthCallbacks')) ??
      [];
  Future<String?> readInstagramAuth() =>
      channel.invokeMethod<String>('readInstagramAuth');
  Future<void> writeInstagramAuth(String value) =>
      channel.invokeMethod<void>('writeInstagramAuth', {'value': value});
  Future<void> clearInstagramAuth() =>
      channel.invokeMethod<void>('clearInstagramAuth');
  Future<void> openInstagramAuthorization(String url) =>
      channel.invokeMethod<void>('openInstagramAuthorization', {'url': url});
  Future<List<String>> takeProviderAuthCallbacks(String provider) async =>
      (await channel.invokeListMethod<String>('takeProviderAuthCallbacks', {
        'provider': provider,
      })) ??
      [];
  Future<String?> readProviderAuth(String provider) =>
      channel.invokeMethod<String>('readProviderAuth', {'provider': provider});
  Future<void> writeProviderAuth(String provider, String value) =>
      channel.invokeMethod<void>('writeProviderAuth', {
        'provider': provider,
        'value': value,
      });
  Future<void> clearProviderAuth(String provider) =>
      channel.invokeMethod<void>('clearProviderAuth', {'provider': provider});
  Future<void> openProviderAuthorization(String provider, String url) =>
      channel.invokeMethod<void>('openProviderAuthorization', {
        'provider': provider,
        'url': url,
      });
  Future<void> saveSettings(Map<String, dynamic> values) async {
    await channel.invokeMethod<void>('setSettings', values);
    await refresh();
  }

  Future<void> chooseFolder() async {
    await channel.invokeMethod<dynamic>('chooseFolder');
    await refresh();
  }

  Future<Map<String, dynamic>> download(Map<String, dynamic> request) async {
    final response = await channel.invokeMapMethod<String, dynamic>(
      'download',
      request,
    );
    if (response == null) {
      throw PlatformException(
        code: 'empty',
        message: 'Android did not schedule the download.',
      );
    }
    await refresh();
    return response;
  }

  Future<void> notifications() => channel.invokeMethod<void>('notifications');
  Future<void> cancel(String id) async {
    await channel.invokeMethod<void>('cancel', {'id': id});
    await refresh();
  }

  Future<void> openFile(Map<String, dynamic> job) => channel.invokeMethod<void>(
    'openFile',
    {'uri': job['uri'], 'mime': job['mime']},
  );
  Future<void> openSource(String url) =>
      channel.invokeMethod<void>('openSource', {'url': url});
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
