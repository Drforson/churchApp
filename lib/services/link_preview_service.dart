// lib/services/link_preview_service.dart
// Simple OpenGraph/HTML metadata fetcher to power clickable previews in the feed.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';

class LinkPreview {
  final String? title;
  final String? description;
  final String? imageUrl;
  const LinkPreview({this.title, this.description, this.imageUrl});
}

class LinkPreviewService {
  LinkPreviewService._();
  static final instance = LinkPreviewService._();

  Future<LinkPreview> fetch(String url) async {
    try {
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; LinkPreview/1.0)',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        return const LinkPreview();
      }
      final doc = html.parse(utf8.decode(resp.bodyBytes));
      String? pick(List<Element> nodes) => nodes.isEmpty ? null : nodes.first.attributes['content'] ?? nodes.first.text;
      String? findMeta(String property) =>
          pick(doc.querySelectorAll('meta[property="$property"]')) ?? pick(doc.querySelectorAll('meta[name="$property"]'));

      final title = findMeta('og:title') ?? doc.querySelector('title')?.text;
      final description = findMeta('og:description') ?? findMeta('description');
      final image = findMeta('og:image');

      return LinkPreview(title: title?.trim(), description: description?.trim(), imageUrl: image?.trim());
    } catch (_) {
      return const LinkPreview();
    }
  }
}
