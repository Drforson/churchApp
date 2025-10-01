import 'package:cloud_firestore/cloud_firestore.dart';

class PostModel {
  final String id;
  final String ministryId;

  // author
  final String authorId;
  final String? authorName;
  final String? authorPhotoUrl;

  // content
  final String? text;       // optional text
  final String? linkUrl;    // optional external url
  final String? imageUrl;   // optional uploaded image url

  // time
  final DateTime createdAt;

  const PostModel({
    required this.id,
    required this.ministryId,
    required this.authorId,
    this.authorName,
    this.authorPhotoUrl,
    this.text,
    this.linkUrl,
    this.imageUrl,
    required this.createdAt,
  });

  factory PostModel.fromDoc(String ministryId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};

    DateTime created;
    final rawCreated = data['createdAt'];
    if (rawCreated is Timestamp) {
      created = rawCreated.toDate();
    } else if (rawCreated is DateTime) {
      created = rawCreated;
    } else if (rawCreated is String) {
      // best-effort parse
      created = DateTime.tryParse(rawCreated)?.toLocal() ?? DateTime.now();
    } else {
      created = DateTime.now();
    }

    return PostModel(
      id: doc.id,
      ministryId: ministryId,
      authorId: (data['authorId'] ?? '') as String,
      authorName: data['authorName'] as String?,
      authorPhotoUrl: data['authorPhotoUrl'] as String?,
      text: (data['text'] as String?)?.trim(),
      linkUrl: (data['linkUrl'] as String?)?.trim(),
      imageUrl: data['imageUrl'] as String?,
      createdAt: created,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'authorId': authorId,
      'authorName': authorName,
      'authorPhotoUrl': authorPhotoUrl,
      'text': text,
      'linkUrl': linkUrl,
      'imageUrl': imageUrl,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
