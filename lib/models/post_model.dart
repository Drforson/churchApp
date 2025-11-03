// lib/models/post_model.dart
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
  final DateTime? updatedAt;

  // social
  final List<String> likes; // list of user uids who liked

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
    this.updatedAt,
    this.likes = const <String>[],
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

    DateTime? updated;
    final rawUpdated = data['updatedAt'];
    if (rawUpdated is Timestamp) {
      updated = rawUpdated.toDate();
    } else if (rawUpdated is DateTime) {
      updated = rawUpdated;
    } else if (rawUpdated is String) {
      updated = DateTime.tryParse(rawUpdated)?.toLocal();
    }

    List<String> likes = const <String>[];
    final rawLikes = data['likes'];
    if (rawLikes is Iterable) {
      likes = rawLikes.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList(growable: false);
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
      updatedAt: updated,
      likes: likes,
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
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'likes': likes,
    };
  }

  PostModel copyWith({
    String? id,
    String? ministryId,
    String? authorId,
    String? authorName,
    String? authorPhotoUrl,
    String? text,
    String? linkUrl,
    String? imageUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? likes,
  }) {
    return PostModel(
      id: id ?? this.id,
      ministryId: ministryId ?? this.ministryId,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      authorPhotoUrl: authorPhotoUrl ?? this.authorPhotoUrl,
      text: text ?? this.text,
      linkUrl: linkUrl ?? this.linkUrl,
      imageUrl: imageUrl ?? this.imageUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      likes: likes ?? this.likes,
    );
  }
}
