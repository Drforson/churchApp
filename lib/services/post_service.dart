// lib/services/post_service.dart
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as p;

import '../models/post_model.dart';

class PostService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  FirebaseStorage? _storage;

  /// True if a Storage bucket is present in Firebase options (image uploads enabled)
  bool get hasStorage => _storage != null;

  PostService() {
    try {
      final bucket = Firebase.app().options.storageBucket;
      if (bucket != null && bucket.isNotEmpty) {
        _storage = FirebaseStorage.instanceFor(bucket: 'gs://$bucket');
      } else {
        _storage = null; // disable images if no bucket
      }
    } catch (_) {
      _storage = null;
    }
  }

  /// -------- Paths (local helpers) --------
  String _ministryDoc(String ministryId) => 'ministries/$ministryId';
  String _postsCol(String ministryId) => 'ministries/$ministryId/posts';
  String _postDoc(String ministryId, String postId) => 'ministries/$ministryId/posts/$postId';

  /// -------- Public API --------

  Stream<List<PostModel>> watchMinistryPosts(String ministryId, {int limit = 50}) {
    return _db
        .collection(_postsCol(ministryId))
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => PostModel.fromDoc(ministryId, d)).toList());
  }

  /// Creates a post. Provide at least one of [text], [linkUrl], or [imageFile].
  /// Uses server timestamps and initializes likes to [] to satisfy security rules.
  Future<void> createPost({
    required String ministryId,
    required String authorId,
    String? authorName,
    String? authorPhotoUrl,
    String? text,
    String? linkUrl,
    File? imageFile,
  }) async {
    final sanitizedText = text?.trim();
    final sanitizedLink = linkUrl?.trim();

    if ((sanitizedText == null || sanitizedText.isEmpty) &&
        (sanitizedLink == null || sanitizedLink.isEmpty) &&
        imageFile == null) {
      throw ArgumentError('Provide at least text, linkUrl, or image');
    }

    final posts = _db.collection(_postsCol(ministryId));
    final postRef = posts.doc();

    String? imageUrl;
    if (imageFile != null) {
      if (!hasStorage) {
        throw StateError('Image uploads are disabled: Firebase Storage is not configured.');
      }
      imageUrl = await _uploadImage(ministryId, postRef.id, imageFile);
    }

    // Write minimal schema aligned with rules (createdAt required; likes exists as list)
    await postRef.set({
      'authorId': authorId,
      if (authorName != null) 'authorName': authorName,
      if (authorPhotoUrl != null) 'authorPhotoUrl': authorPhotoUrl,
      if (sanitizedText != null && sanitizedText.isNotEmpty) 'text': sanitizedText,
      if (sanitizedLink != null && sanitizedLink.isNotEmpty) 'linkUrl': sanitizedLink,
      if (imageUrl != null && imageUrl.isNotEmpty) 'imageUrl': imageUrl,
      'likes': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deletePost({
    required String ministryId,
    required String postId,
    String? imageUrl,
  }) async {
    // Best-effort delete the image
    if (_storage != null && imageUrl != null && imageUrl.isNotEmpty) {
      try {
        final ref = _storage!.refFromURL(imageUrl);
        await ref.delete();
      } catch (_) {
        // ignore failures (external url or already deleted)
      }
    }
    await _db.doc(_postDoc(ministryId, postId)).delete();
  }

  /// Optional helpers used by some UIs (not strictly required by your current page):

  Future<void> toggleLike({
    required String ministryId,
    required String postId,
    required String uid,
    required bool currentlyLiked,
  }) async {
    final ref = _db.doc(_postDoc(ministryId, postId));
    await ref.update({
      'likes': currentlyLiked
          ? FieldValue.arrayRemove([uid])
          : FieldValue.arrayUnion([uid]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> addReaction({
    required String ministryId,
    required String postId,
    required String uid,
    required String emoji,
  }) async {
    final reacts = _db.collection(_postDoc(ministryId, postId)).doc().parent.parent!
        .collection('posts').doc(postId).collection('reactions');
    // toggle this exact emoji for this user
    final qs = await reacts
        .where('authorUid', isEqualTo: uid)
        .where('emoji', isEqualTo: emoji)
        .limit(1)
        .get();
    if (qs.docs.isNotEmpty) {
      await qs.docs.first.reference.delete();
    } else {
      await reacts.add({
        'authorUid': uid,
        'emoji': emoji,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> addComment({
    required String ministryId,
    required String postId,
    required String uid,
    required String text,
  }) async {
    final comments = _db
        .collection(_postsCol(ministryId))
        .doc(postId)
        .collection('comments');
    await comments.add({
      'authorId': uid,
      'text': text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteComment({
    required String ministryId,
    required String postId,
    required String commentId,
  }) async {
    final doc = _db
        .collection(_postsCol(ministryId))
        .doc(postId)
        .collection('comments')
        .doc(commentId);
    await doc.delete();
  }

  /// -------- Internals --------

  Future<String> _uploadImage(String ministryId, String postId, File file) async {
    final ext = p.extension(file.path).toLowerCase();
    final contentType = _contentTypeForExt(ext);
    final ref = _storage!
        .ref()
        .child('ministry_posts/$ministryId/$postId$ext');

    await ref.putFile(file, SettableMetadata(contentType: contentType));
    return ref.getDownloadURL();
  }

  String _contentTypeForExt(String ext) {
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }
}
