class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;   // og:image / twitter:image
  final String? faviconUrl; // <link rel="icon"> or derived

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.faviconUrl,
  });

  bool get hasImage => (imageUrl != null && imageUrl!.isNotEmpty);

  Map<String, dynamic> toMap() => {
    'url': url,
    'title': title,
    'description': description,
    'imageUrl': imageUrl,
    'faviconUrl': faviconUrl,
  };

  factory LinkPreview.fromMap(Map<String, dynamic> m) => LinkPreview(
    url: m['url'] as String,
    title: m['title'] as String?,
    description: m['description'] as String?,
    imageUrl: m['imageUrl'] as String?,
    faviconUrl: m['faviconUrl'] as String?,
  );
}
