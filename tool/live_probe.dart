import 'dart:convert';
import 'dart:io';
import 'package:gather/extractors.dart';
import 'package:gather/models.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/live_probe.dart <public post URL>');
    exitCode = 64;
    return;
  }
  final registry = ExtractorRegistry();
  for (final url in args) {
    try {
      final post = await registry.extract(url);
      stdout.writeln(
        jsonEncode({
          'source': post.source.toString(),
          'platform': post.platform.name,
          'status': 'extracted',
          'items': post.mediaItems
              .map(
                (m) => {
                  'type': m.type,
                  'qualities': m.qualities
                      .map((q) => {'url': q.url, 'label': q.label})
                      .toList(),
                },
              )
              .toList(),
        }),
      );
    } on GatherException catch (e) {
      stdout.writeln(
        jsonEncode({'source': url, 'status': e.code, 'message': e.message}),
      );
    }
  }
}
