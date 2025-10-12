import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/link_preview.dart';

/// Fetches Open Graph / Twitter Card metadata for URLs and memoizes results.
class LinkPreviewService {
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  /// In-flight + cached requests to dedupe work for identical URLs.
  final Map<String, Future<LinkPreview?>> _memo = {};

  /// Fetch preview for [url]. Returns null if site blocks scraping or on errors.
  Future<LinkPreview?> fetch(
      String url, {
        Duration timeout = const Duration(seconds: 7),
      }) {
    final normalized = _normalizeUrl(url);
    return _memo.putIfAbsent(normalized, () => _fetchImpl(normalized, timeout: timeout));
  }

  String _normalizeUrl(String url) {
    try {
      final u = Uri.parse(url.trim());
      if (!u.hasScheme) return 'https://$url';
      return u.toString();
    } catch (_) {
      return url.trim();
    }
  }

  static String _resolveUrl(String base, String? maybe) {
    if (maybe == null || maybe.trim().isEmpty) return '';
    final uri = Uri.tryParse(maybe.trim());
    if (uri != null && uri.hasScheme) return uri.toString();
    // Resolve relative against base
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return maybe.trim();
    return baseUri.resolve(maybe.trim()).toString();
  }

  Future<LinkPreview?> _fetchImpl(
      String url, {
        required Duration timeout,
      }) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {
          // Many sites use UA sniffing; this makes us look like a regular browser.
          'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(timeout);

      if (res.statusCode < 200 || res.statusCode >= 300) return null;

      // Attempt UTF-8 decode, allow malformed sequences
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final doc = html_parser.parse(body);

      String? firstNonEmptyAttr(Iterable<Element> els) {
        for (final e in els) {
          final v = (e.attributes['content'] ?? e.attributes['href'] ?? '').trim();
          if (v.isNotEmpty) return v;
        }
        return null;
      }

      // Open Graph
      final ogTitle = firstNonEmptyAttr(doc.querySelectorAll(
          'meta[property="og:title"], meta[name="og:title"]'));
      final ogDesc = firstNonEmptyAttr(doc.querySelectorAll(
          'meta[property="og:description"], meta[name="og:description"]'));
      final ogImage = firstNonEmptyAttr(doc.querySelectorAll(
          'meta[property="og:image"], meta[name="og:image"]'));

      // Twitter card
      final twTitle = firstNonEmptyAttr(doc.querySelectorAll('meta[name="twitter:title"]'));
      final twDesc = firstNonEmptyAttr(doc.querySelectorAll('meta[name="twitter:description"]'));
      final twImage = firstNonEmptyAttr(
          doc.querySelectorAll('meta[name="twitter:image"], meta[name="twitter:image:src"]'));

      // HTML title/description fallback
      final htmlTitle = doc.querySelector('title')?.text.trim();
      final metaDesc = firstNonEmptyAttr(doc.querySelectorAll('meta[name="description"]'));

      // Favicon candidates
      String? favicon = firstNonEmptyAttr(doc.querySelectorAll(
          'link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]'));
      favicon = _resolveUrl(url, favicon ?? '/favicon.ico');

      // Choose image (prefer OG/Twitter)
      final selectedImage = _resolveUrl(url, ogImage ?? twImage);
      final imageUrl = selectedImage.isEmpty ? null : selectedImage;

      return LinkPreview(
        url: url,
        title: ogTitle ?? twTitle ?? htmlTitle,
        description: ogDesc ?? twDesc ?? metaDesc,
        imageUrl: imageUrl,
        faviconUrl: (favicon.isNotEmpty) ? favicon : null,
      );
    } catch (_) {
      // CORS or site blocks scraping (esp. on Flutter web) → return null gracefully
      return null;
    }
  }
}
// TODO Implement this library.