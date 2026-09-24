import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'extractors.dart';
import 'instagram_api.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'platform_providers.dart';
import 'x_api.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GatherApp());
}

const forest = Color(0xff164d3e);
const lime = Color(0xffd6ef93);
const paper = Color(0xfff6f7f2);

class GatherApp extends StatefulWidget {
  const GatherApp({super.key});
  @override
  State<GatherApp> createState() => _GatherAppState();
}

class _GatherAppState extends State<GatherApp> {
  final bridge = NativeBridge();
  @override
  void dispose() {
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bridge,
    builder: (context, _) {
      ThemeData theme(Brightness brightness) {
        final dark = brightness == Brightness.dark;
        final scheme = ColorScheme.fromSeed(
          seedColor: forest,
          brightness: brightness,
          primary: dark ? lime : forest,
          surface: dark ? const Color(0xff141d19) : paper,
        );
        return ThemeData(
          useMaterial3: true,
          colorScheme: scheme,
          scaffoldBackgroundColor: scheme.surface,
          appBarTheme: AppBarTheme(
            backgroundColor: scheme.surface,
            scrolledUnderElevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: dark ? const Color(0xff202e27) : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.all(18),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            color: dark ? const Color(0xff202e27) : Colors.white,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
          ),
          dividerTheme: DividerThemeData(
            color: scheme.outlineVariant.withValues(alpha: .5),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: scheme.surface,
            indicatorColor: dark ? forest : lime,
          ),
        );
      }

      return MaterialApp(
        title: 'Gather',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: switch (bridge.settings['darkMode']) {
          'dark' => ThemeMode.dark,
          'light' => ThemeMode.light,
          _ => ThemeMode.system,
        },
        home: HomeScreen(bridge: bridge),
      );
    },
  );
}

String fileSize(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return 'Size unavailable';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

void showError(BuildContext context, Object error) {
  final message = error is PlatformException
      ? error.message ?? error.code
      : error.toString();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.bridge});
  final NativeBridge bridge;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final link = TextEditingController();
  final search = TextEditingController();
  final publicExtractors = ExtractorRegistry();
  final pending = <String>[];
  int tab = 0;
  bool busy = false;
  bool previewOpen = false;
  bool ready = false;
  final Map<PlatformKind, bool> providerAuthBusy = {};
  String? fetchError;
  late final InstagramAuthService instagramAuth;
  late final XAuthService xAuth;
  late final PlatformProviderRegistry providerRegistry;
  NativeBridge get bridge => widget.bridge;

  @override
  void initState() {
    super.initState();
    instagramAuth = InstagramAuthService(bridge: bridge);
    xAuth = XAuthService(bridge: bridge);
    providerRegistry = PlatformProviderRegistry(
      extractors: publicExtractors,
      bridge: bridge,
      instagramAuth: instagramAuth,
      xAuth: xAuth,
    );
    WidgetsBinding.instance.addObserver(this);
    bridge.onShares = receiveShares;
    bridge.onInstagramAuth = processInstagramAuthCallbacks;
    bridge.onXAuth = processXAuthCallbacks;
    WidgetsBinding.instance.addPostFrameCallback((_) => initialize());
  }

  Future<void> initialize() async {
    await bridge.start();
    for (final work in [
      instagramAuth.restore,
      instagramAuth.processPendingCallbacks,
      xAuth.restore,
      xAuth.processPendingCallbacks,
    ]) {
      try {
        await work();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => ready = true);
    if (bridge.error == null && bridge.settings['accepted'] != true) {
      await acknowledge();
    }
    if (bridge.error == null && bridge.settings['accepted'] == true) {
      await receiveShares();
    }
  }

  Future<void> acknowledge() async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bookmark_added_outlined, size: 32),
        title: const Text('Save with care'),
        content: const Text(
          'Gather saves public media and media returned by an official API to a connected account. Instagram authorization is limited to the connected Professional account’s own API-listed media. X protected-post access is used only if X’s authenticated API returns that post. Some platforms provide previews or no download API. Save only content you own or have permission to save; you are responsible for respecting copyright and platform terms.\n\nPersonal use. No ads, no telemetry, and no platform passwords.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      try {
        await bridge.saveSettings({'accepted': true});
      } catch (e) {
        if (mounted) {
          showError(context, e);
        }
      }
    }
  }

  Future<void> receiveShares() async {
    try {
      final shares = await bridge.takeShares();
      if (!mounted) {
        return;
      }
      for (final text in shares) {
        if (pending.length < 20) {
          pending.add(text);
        }
      }
      setState(() {});
      if (!busy &&
          !previewOpen &&
          pending.isNotEmpty &&
          bridge.settings['accepted'] == true) {
        await fetch(pending.removeAt(0));
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    }
  }

  Future<void> processInstagramAuthCallbacks() async {
    try {
      await instagramAuth.processPendingCallbacks();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> processXAuthCallbacks() async {
    try {
      await xAuth.processPendingCallbacks();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> connectProvider(PlatformKind platform) async {
    if (providerAuthBusy[platform] == true) return;
    setState(() => providerAuthBusy[platform] = true);
    try {
      await providerRegistry.providerFor(platform).authenticate();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => providerAuthBusy[platform] = false);
    }
  }

  Future<void> disconnectProvider(PlatformKind platform) async {
    try {
      await providerRegistry.providerFor(platform).disconnect();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {});
        showError(context, e);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ready) {
      bridge.refresh();
      unawaited(receiveShares());
      unawaited(processInstagramAuthCallbacks());
      unawaited(processXAuthCallbacks());
    }
  }

  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) {
      return;
    }
    if (data?.text?.trim().isNotEmpty == true) {
      link.text = data!.text!.trim();
    } else {
      showError(context, 'Your clipboard has no text link.');
    }
  }

  Future<void> fetch(String text) async {
    if (busy) {
      return;
    }
    if (bridge.settings['accepted'] != true) {
      await acknowledge();
      if (bridge.settings['accepted'] != true) {
        return;
      }
    }
    if (!mounted) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      fetchError = null;
      tab = 0;
      link.text = text;
    });
    try {
      final resolved = await providerRegistry.resolveSharedUrl(text);
      if (!mounted) {
        return;
      }
      setState(() {
        busy = false;
        previewOpen = true;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PreviewScreen(
            post: resolved.post,
            bridge: bridge,
            transport: publicExtractors.transport,
            provider: resolved.provider,
          ),
        ),
      );
      if (mounted) {
        setState(() => previewOpen = false);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        busy = false;
        fetchError = e is GatherException
            ? e.message
            : 'Could not read this post (${e.runtimeType}). Please try again.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    bridge.onShares = null;
    bridge.onInstagramAuth = null;
    bridge.onXAuth = null;
    link.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bridge,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: forest,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.south_rounded, color: lime, size: 23),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'gather',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  fontSize: 26,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (MediaQuery.sizeOf(context).width >= 440)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Text(
                'YOUR MEDIA, SAVED.',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: !ready
                ? const Center(child: CircularProgressIndicator())
                : switch (tab) {
                    1 => library(),
                    2 => SettingsScreen(
                      bridge: bridge,
                      providers: providerRegistry,
                      providerAuthBusy: providerAuthBusy,
                      onConnectProvider: connectProvider,
                      onDisconnectProvider: disconnectProvider,
                    ),
                    _ => home(),
                  },
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.add_link_rounded),
            selectedIcon: Icon(Icons.add_link_rounded),
            label: 'Save',
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            label: 'Settings',
          ),
        ],
      ),
    ),
  );

  Widget home() {
    final recent = bridge.jobs.take(3).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
            color: forest,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.circle, size: 7, color: lime),
                  SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'A LITTLE PLACE FOR YOUR FINDS',
                      style: TextStyle(
                        color: lime,
                        fontSize: 9,
                        letterSpacing: 1.7,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'Worth keeping.\nEasy to save.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 37,
                  fontWeight: FontWeight.w700,
                  height: 1.08,
                  letterSpacing: -1.8,
                ),
              ),
              const SizedBox(height: 13),
              const Text(
                'Paste a link, or connect Instagram or X for official API access.',
                style: TextStyle(
                  color: Color(0xffc3d6cb),
                  height: 1.5,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children:
                    [
                          'X',
                          'Instagram',
                          'Facebook',
                          'TikTok',
                          'YouTube',
                          'Pinterest',
                        ]
                        .map(
                          (name) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xff628474),
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        )
                        .toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        const Text(
          'Start with a link',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          'Paste below, or share a post directly to Gather.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 15),
        TextField(
          controller: link,
          enabled: !busy,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (value) => fetch(value),
          decoration: InputDecoration(
            hintText: 'https://…',
            prefixIcon: const Icon(Icons.link_rounded),
            suffixIcon: IconButton(
              tooltip: 'Paste link',
              onPressed: busy ? null : paste,
              icon: const Icon(Icons.content_paste_rounded, size: 20),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy || bridge.error != null
              ? null
              : () => fetch(link.text),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: Text(busy ? 'Finding media…' : 'Find media'),
        ),
        if (fetchError != null) ...[
          const SizedBox(height: 14),
          Notice(icon: Icons.info_outline, text: fetchError!),
        ],
        if (bridge.error != null) ...[
          const SizedBox(height: 14),
          Notice(icon: Icons.error_outline, text: bridge.error!),
        ],
        if (pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => fetch(pending.removeAt(0)),
              icon: const Icon(Icons.queue),
              label: Text('Open next shared link (${pending.length})'),
            ),
          ),
        const SizedBox(height: 27),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Recently saved',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.4,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => tab = 1),
              child: const Text('View all'),
            ),
          ],
        ),
        if (recent.isEmpty)
          const EmptyLibrary(compact: true)
        else
          ...recent.map(
            (job) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: jobCard(job),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Public posts · API-returned account media · No ads · No telemetry',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget library() {
    final query = search.text.toLowerCase();
    final jobs = bridge.jobs
        .where(
          (j) => '${j['name']} ${j['platform']} ${j['source']}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final completed = bridge.jobs
        .where((j) => j['status'] == 'complete')
        .length;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          'Your collection',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          '$completed saved · Stored on your device',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 23),
        TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Search your downloads',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 20),
        if (jobs.isEmpty)
          EmptyLibrary(compact: false, searching: query.isNotEmpty),
        ...jobs.map(
          (job) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: jobCard(job),
          ),
        ),
      ],
    );
  }

  Widget jobCard(Map<String, dynamic> job) {
    final status = job['status'] as String;
    final complete = status == 'complete';
    final active = ['queued', 'running', 'retrying', 'saving'].contains(status);
    final progress = (job['progress'] as num?)?.toDouble() ?? 0;
    final date = DateTime.fromMillisecondsSinceEpoch(
      ((job['downloadedAt'] as num?)?.toInt() ??
          (job['created'] as num).toInt()),
    );
    final subtitle = complete
        ? '${fileSize((job['bytes'] as num?)?.toInt())} · ${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'
        : switch (status) {
            'queued' =>
              job['wifiOnly'] == true
                  ? 'Queued · waiting for unmetered Wi-Fi'
                  : 'Queued · waiting for Android',
            'running' =>
              'Downloading ${progress < 0 ? '' : '${progress.toInt()}%'}',
            'saving' => 'Saving to your folder…',
            'retrying' => 'Network interrupted · retrying',
            'cancelled' => 'Cancelled',
            _ => 'Download failed',
          };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: MediaThumbnail(
                    url: job['thumbnail'] as String?,
                    platform: job['platform'] as String,
                    type: job['type'] as String,
                    width: 58,
                    height: 64,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (job['platform'] as String).toUpperCase(),
                        style: const TextStyle(fontSize: 9, letterSpacing: 1.3),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Download actions',
                  onSelected: (action) async {
                    try {
                      if (action == 'open') {
                        await bridge.openFile(job);
                      }
                      if (action == 'source') {
                        await bridge.openSource(job['source'] as String);
                      }
                      if (action == 'again') {
                        await fetch(job['source'] as String);
                      }
                      if (action == 'cancel') {
                        await bridge.cancel(job['id'] as String);
                      }
                    } catch (e) {
                      if (mounted) {
                        showError(context, e);
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (complete)
                      const PopupMenuItem(
                        value: 'open',
                        child: Text('Open saved file'),
                      ),
                    const PopupMenuItem(
                      value: 'source',
                      child: Text('Open source post'),
                    ),
                    if (!active)
                      const PopupMenuItem(
                        value: 'again',
                        child: Text('Fetch again'),
                      ),
                    if (active)
                      const PopupMenuItem(
                        value: 'cancel',
                        child: Text('Cancel download'),
                      ),
                  ],
                ),
              ],
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(
                  value: status == 'running' && progress >= 0
                      ? progress / 100
                      : null,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            if (['failed', 'retrying'].contains(status) &&
                (job['error'] as String?)?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Text(
                  job['error'] as String,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({
    super.key,
    required this.url,
    required this.platform,
    required this.type,
    this.width,
    this.height,
  });
  final String? url;
  final String platform;
  final String type;
  final double? width;
  final double? height;
  @override
  Widget build(BuildContext context) {
    final kind = PlatformKind.values
        .where((p) => p.name == platform)
        .firstOrNull;
    Widget placeholder() => Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          type == 'video' ? Icons.play_circle_outline : Icons.image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (url == null || kind == null || !isMediaUrl(url!, kind)) {
      return placeholder();
    }
    return Image.network(
      url!,
      width: width,
      height: height,
      fit: BoxFit.cover,
      cacheWidth: 800,
      errorBuilder: (_, error, stackTrace) => placeholder(),
      loadingBuilder: (context, child, event) =>
          event == null ? child : placeholder(),
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({
    super.key,
    required this.compact,
    this.searching = false,
  });
  final bool compact;
  final bool searching;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: EdgeInsets.all(compact ? 23 : 35),
      child: Column(
        children: [
          Icon(
            searching ? Icons.search_off : Icons.collections_bookmark_outlined,
            size: compact ? 28 : 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 13),
          Text(
            searching ? 'No matches yet' : 'Your next good find goes here',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            searching
                ? 'Try another name or platform.'
                : 'Saved photos and videos will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class Notice extends StatelessWidget {
  const Notice({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 11),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, height: 1.5)),
        ),
      ],
    ),
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.bridge,
    required this.providers,
    required this.providerAuthBusy,
    required this.onConnectProvider,
    required this.onDisconnectProvider,
  });
  final NativeBridge bridge;
  final PlatformProviderRegistry providers;
  final Map<PlatformKind, bool> providerAuthBusy;
  final Future<void> Function(PlatformKind) onConnectProvider;
  final Future<void> Function(PlatformKind) onDisconnectProvider;
  Future<void> action(
    BuildContext context,
    Future<void> Function() work,
  ) async {
    try {
      await work();
    } catch (e) {
      if (context.mounted) {
        showError(context, e);
      }
    }
  }

  Widget accountCard(BuildContext context, PlatformProvider provider) {
    final capabilities = provider.capabilities;
    final busy = providerAuthBusy[provider.platform] == true;
    final note = capabilities.unavailableNote.isNotEmpty
        ? capabilities.unavailableNote
        : capabilities.privateContentNote;
    final features = <String>[
      if (capabilities.canResolvePosts) 'Post links',
      if (capabilities.canDownloadImages) 'Images',
      if (capabilities.canDownloadVideos) 'Videos',
      if (capabilities.supportsCarousel) 'Carousels',
      if (capabilities.supportsOfficialApi) 'Official API',
      if (capabilities.canAccessOwnMedia) 'Own account media',
      if (capabilities.canAccessAuthorizedPrivateMedia)
        'Protected post returned by API',
    ];
    final icon = switch (provider.platform) {
      PlatformKind.instagram => Icons.camera_alt_outlined,
      PlatformKind.x => Icons.alternate_email_rounded,
      PlatformKind.facebook => Icons.facebook_rounded,
      PlatformKind.tiktok => Icons.music_video_outlined,
      PlatformKind.youtube => Icons.smart_display_outlined,
      PlatformKind.pinterest => Icons.push_pin_outlined,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.platform.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        provider.isConnected
                            ? provider.accountStatus
                            : capabilities.unavailableNote.isNotEmpty
                            ? 'Unavailable in this build'
                            : 'Not connected · ${provider.accountStatus}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  provider.isConnected
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: provider.isConnected
                      ? forest
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ],
            ),
            if (features.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final feature in features)
                    Chip(
                      label: Text(feature),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                note,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (capabilities.canAuthenticate ||
                provider.setupStatus.isNotEmpty) ...[
              const SizedBox(height: 11),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (capabilities.canAuthenticate)
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () => onConnectProvider(provider.platform),
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login_rounded),
                      label: Text(
                        busy
                            ? 'Opening ${provider.platform.label}…'
                            : provider.isConnected
                            ? 'Reconnect'
                            : 'Connect account',
                      ),
                    ),
                  if (provider.isConnected)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () => onDisconnectProvider(provider.platform),
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Disconnect'),
                    ),
                ],
              ),
              if (provider.setupStatus.isNotEmpty) ...[
                const SizedBox(height: 7),
                Notice(icon: Icons.info_outline, text: provider.setupStatus),
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      const Text(
        'Make it yours',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'A few preferences. Nothing extra.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 25),
      const Text(
        'ACCOUNT ACCESS',
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 11),
      for (final provider in providers.providers) ...[
        accountCard(context, provider),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 25),
      const Text(
        'SAVING',
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 11),
      Card(
        child: Column(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 9,
              ),
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Save folder'),
              subtitle: Text(bridge.settings['folderName'] as String),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => action(context, bridge.chooseFolder),
            ),
            if ((bridge.settings['folderUri'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton(
                  onPressed: () => action(
                    context,
                    () => bridge.saveSettings({
                      'folderUri': '',
                      'folderName': 'Pictures/Gather · Movies/Gather',
                    }),
                  ),
                  child: const Text('Use Gallery folders'),
                ),
              ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 9,
              ),
              secondary: const Icon(Icons.wifi),
              title: const Text('Wi-Fi only'),
              subtitle: const Text('New downloads wait for unmetered Wi-Fi.'),
              value: bridge.settings['wifiOnly'] == true,
              onChanged: (value) => action(
                context,
                () => bridge.saveSettings({'wifiOnly': value}),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 11),
      const Text(
        'Folder and network changes apply to new downloads. Android controls which folders can be selected.',
        style: TextStyle(fontSize: 11, height: 1.5),
      ),
      const SizedBox(height: 25),
      const Text(
        'APPEARANCE',
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 11),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Color theme',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 15),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('Auto')),
                    ButtonSegment(value: 'light', label: Text('Light')),
                    ButtonSegment(value: 'dark', label: Text('Dark')),
                  ],
                  selected: {bridge.settings['darkMode'] as String},
                  onSelectionChanged: (value) => action(
                    context,
                    () => bridge.saveSettings({'darkMode': value.first}),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 25),
      const Notice(
        icon: Icons.verified_user_outlined,
        text:
            'Your collection stays yours. Gather has no ads or telemetry. Instagram and X sign-in use official authorization; the app never asks for your password.',
      ),
      const SizedBox(height: 15),
      const Text(
        'Save responsibly',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Save only content you own or have permission to save. You are responsible for respecting copyright and each platform’s terms. Gather is for personal use. Instagram’s authorized path is limited to the connected Professional account’s own media. X protected-post access is considered authorized only when the official API returns that post to the connected account. Other providers show their current limits above.\n\nGather does not bypass login, private-account access, or platform access checks.',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 18),
      const Text(
        'Gather 1.0.0 · Made for your good finds',
        style: TextStyle(fontSize: 11),
      ),
    ],
  );
}

class PreviewScreen extends StatefulWidget {
  const PreviewScreen({
    super.key,
    required this.post,
    required this.bridge,
    required this.transport,
    this.provider,
  });
  final Post post;
  final NativeBridge bridge;
  final PublicTransport transport;
  final PlatformProvider? provider;
  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final List<int> selected;
  late final List<TextEditingController> names;
  final Map<String, int?> sizes = {};
  final Set<int> queued = {};
  bool scheduling = false;
  @override
  void initState() {
    super.initState();
    selected = List.filled(widget.post.mediaItems.length, 0);
    names = List.generate(
      selected.length,
      (i) => TextEditingController(text: suggestedFileName(widget.post, i)),
    );
    for (final media in widget.post.mediaItems) {
      readSize(media.qualities.first);
    }
  }

  Future<void> readSize(Quality quality) async {
    final size =
        quality.bytes ??
        await widget.transport.size(quality.url, widget.post.platform);
    if (mounted) {
      setState(() => sizes[quality.url] = size);
    }
  }

  @override
  void dispose() {
    for (final name in names) {
      name.dispose();
    }
    super.dispose();
  }

  Future<bool> enqueue(int index) async {
    final media = widget.post.mediaItems[index];
    if (!media.downloadable) {
      return false;
    }
    final fileName = names[index].text.trim().isEmpty
        ? suggestedFileName(widget.post, index)
        : names[index].text.trim();
    final result = await _schedule(index, fileName, force: false);
    if (result['duplicate'] == true) {
      if (!mounted) {
        return false;
      }
      final again = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Already in your collection'),
          content: const Text(
            'This item is saved or already queued. Save another copy?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep existing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save a copy'),
            ),
          ],
        ),
      );
      if (again != true) {
        return false;
      }
      await _schedule(index, fileName, force: true);
    }
    if (mounted) {
      setState(() => queued.add(index));
    }
    return true;
  }

  Future<Map<String, dynamic>> _schedule(
    int index,
    String fileName, {
    required bool force,
  }) {
    final provider = widget.provider;
    if (provider != null) {
      return provider.downloadMedia(
        widget.post,
        index,
        qualityIndex: selected[index],
        fileName: fileName,
        force: force,
      );
    }
    final media = widget.post.mediaItems[index];
    final quality = media.qualities[selected[index]];
    return widget.bridge.download({
      'url': quality.url,
      'source': widget.post.source.toString(),
      'platform': widget.post.platform.name,
      'type': media.type,
      'thumbnail': media.thumbnail ?? '',
      'name': fileName,
      'itemKey': '${widget.post.source}#$index',
      'force': force,
    });
  }

  Future<void> download(List<int> indices) async {
    setState(() => scheduling = true);
    var count = 0;
    try {
      await widget.bridge.notifications();
      for (final index in indices) {
        if (await enqueue(index)) {
          count++;
        }
      }
      if (mounted && count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$count ${count == 1 ? 'item' : 'items'} queued. Follow progress in Library.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => scheduling = false);
      }
    }
  }

  Future<void> openSource() async {
    try {
      await widget.bridge.openSource(widget.post.source.toString());
    } on Exception catch (error) {
      if (mounted) {
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final downloadable = [
      for (var i = 0; i < post.mediaItems.length; i++)
        if (post.mediaItems[i].downloadable) i,
    ];
    final previewOnly = downloadable.isEmpty;
    final previewOnlyReasons = post.mediaItems
        .map((media) => media.unavailableReason)
        .whereType<String>()
        .where((reason) => reason.trim().isNotEmpty)
        .toList();
    final previewOnlyReason = previewOnlyReasons.isEmpty
        ? 'The platform did not provide a media file that its API authorizes Gather to save.'
        : previewOnlyReasons.first;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Ready to keep',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 24),
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Chip(
                        label: Text(post.platform.label),
                        avatar: const Icon(Icons.public, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${post.mediaItems.length} ${post.mediaItems.length == 1 ? 'item' : 'items'} · ${post.postType}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  if (post.access != PostAccess.public)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Chip(
                        label: Text(switch (post.access) {
                          PostAccess.public => 'Public',
                          PostAccess.ownAccount => 'Your connected account',
                          PostAccess.authorizedPrivate =>
                            'Protected · returned by API',
                        }),
                        avatar: const Icon(
                          Icons.verified_user_outlined,
                          size: 16,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                post.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                post.source.toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: scheduling ? null : openSource,
                  icon: const Icon(Icons.open_in_new_rounded, size: 17),
                  label: const Text('Open original post'),
                ),
              ),
              if (previewOnly) ...[
                const SizedBox(height: 14),
                Notice(
                  icon: Icons.visibility_outlined,
                  text: previewOnlyReason,
                ),
              ],
              const SizedBox(height: 21),
              ...List.generate(post.mediaItems.length, (index) {
                final media = post.mediaItems[index];
                final quality = media.qualities[selected[index]];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Stack(
                          children: [
                            AspectRatio(
                              aspectRatio: 4 / 3,
                              child: MediaThumbnail(
                                url:
                                    media.thumbnail ??
                                    (media.type == 'image'
                                        ? quality.url
                                        : null),
                                platform: post.platform.name,
                                type: media.type,
                                width: double.infinity,
                                height: double.infinity,
                              ),
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: forest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${index + 1} / ${post.mediaItems.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                            if (media.type == 'video')
                              const Positioned.fill(
                                child: Center(
                                  child: Icon(
                                    Icons.play_circle_fill,
                                    size: 54,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.all(17),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    media.type == 'video'
                                        ? Icons.videocam_outlined
                                        : Icons.image_outlined,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      media.type == 'video'
                                          ? 'Video · MP4'
                                          : 'Photo',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      media.downloadable
                                          ? (sizes.containsKey(quality.url)
                                                ? fileSize(sizes[quality.url])
                                                : 'Checking size…')
                                          : 'Preview only',
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 15),
                              if (media.qualities.length > 1)
                                DropdownButtonFormField<int>(
                                  initialValue: selected[index],
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Quality',
                                  ),
                                  items: List.generate(
                                    media.qualities.length,
                                    (q) => DropdownMenuItem(
                                      value: q,
                                      child: Text(media.qualities[q].label),
                                    ),
                                  ),
                                  onChanged: scheduling
                                      ? null
                                      : (value) {
                                          if (value != null) {
                                            setState(
                                              () => selected[index] = value,
                                            );
                                            readSize(media.qualities[value]);
                                          }
                                        },
                                ),
                              if (media.qualities.length == 1)
                                Text(
                                  quality.width != null &&
                                          quality.height != null
                                      ? '${quality.label} · ${quality.width} × ${quality.height}'
                                      : quality.label,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              if (media.downloadable) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  controller: names[index],
                                  enabled: !scheduling,
                                  decoration: const InputDecoration(
                                    labelText: 'File name',
                                    helperText:
                                        'The correct file extension is added automatically.',
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                ),
                                const SizedBox(height: 14),
                              ],
                              OutlinedButton.icon(
                                onPressed: scheduling
                                    ? null
                                    : media.downloadable
                                    ? () => download([index])
                                    : openSource,
                                icon: Icon(
                                  !media.downloadable
                                      ? Icons.open_in_new_rounded
                                      : queued.contains(index)
                                      ? Icons.check_circle_outline
                                      : Icons.south_rounded,
                                ),
                                label: Text(
                                  !media.downloadable
                                      ? 'Open in TikTok'
                                      : queued.contains(index)
                                      ? 'Queued · save again'
                                      : 'Download this item',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const Notice(
                icon: Icons.folder_outlined,
                text:
                    'Downloads continue when you leave Gather. Android may pause jobs for battery or network conditions. Force-stopping the app pauses work until it is reopened.',
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
          child: previewOnly
              ? OutlinedButton.icon(
                  onPressed: scheduling ? null : openSource,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open in TikTok'),
                )
              : FilledButton.icon(
                  onPressed: scheduling ? null : () => download(downloadable),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    scheduling
                        ? 'Adding to your downloads…'
                        : 'Download all · ${downloadable.length}',
                  ),
                ),
        ),
      ),
    );
  }
}
