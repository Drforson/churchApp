// lib/pages/ministry_feed_page.dart
// Extended: likes ❤️, reactions (emoji), comments with member display names.
// Works with Firestore rules you provided (likes array, comments & reactions subcollections).

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/post_model.dart';
import '../models/link_preview.dart' as lp;
import '../services/post_service.dart';
import '../services/link_preview_service.dart' as lps;
import '../widgets/link_preview_card.dart';

class MinistryFeedPage extends StatefulWidget {
  final String ministryId;   // ministries/{id}
  final String ministryName; // human-readable name (your memberships use names)

  const MinistryFeedPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryFeedPage> createState() => _MinistryFeedPageState();
}

class _MinistryFeedPageState extends State<MinistryFeedPage> {
  late final PostService _svc;

  final _textCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();
  File? _imageFile;
  bool _posting = false;

  // auth/meta
  List<String> _myRoles = const [];
  List<String> _myLeaderMins = const [];
  String? _singleRole;
  bool _isMemberOfThis = false;

  // cache for uid -> display name
  final Map<String, String> _uidNameCache = {};

  @override
  void initState() {
    super.initState();
    _svc = PostService();
    _loadMyRoleMeta();
    _loadMembership();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMyRoleMeta() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = snap.data() ?? {};
    setState(() {
      _myRoles = List<String>.from((data['roles'] ?? const []) as List);
      _myLeaderMins = List<String>.from((data['leadershipMinistries'] ?? const []) as List);
      _singleRole = (data['role'] ?? '').toString().toLowerCase().trim();
    });
  }

  Future<void> _loadMembership() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final user = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final memberId = user.data()?['memberId'] as String?;
    if (memberId == null || memberId.isEmpty) {
      setState(() => _isMemberOfThis = false);
      return;
    }
    final member = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
    final mins = List<String>.from((member.data() ?? const {})['ministries'] ?? const []);
    setState(() => _isMemberOfThis = mins.contains(widget.ministryName));
  }

  Future<void> _pickImage() async {
    if (!_svc.hasStorage) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Images disabled: Storage not configured')),
        );
      }
      return;
    }
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) {
      setState(() => _imageFile = File(picked.path));
    }
  }

  Future<void> _submit() async {
    if (_posting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // require at least something
    final hasText = _textCtrl.text.trim().isNotEmpty;
    final hasLink = _linkCtrl.text.trim().isNotEmpty;
    final hasImage = _imageFile != null;
    if (!hasText && !hasLink && !hasImage) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Write something, add a link, or pick an image')),
        );
      }
      return;
    }

    setState(() => _posting = true);
    try {
      // 🔎 build author display name/photo from linked member if present
      String? authorName;
      String? authorPhotoUrl;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final memberId = userDoc.data()?['memberId'] as String?;

      if (memberId != null && memberId.isNotEmpty) {
        final memberDoc = await FirebaseFirestore.instance
            .collection('members')
            .doc(memberId)
            .get();
        final m = memberDoc.data() ?? {};
        final first = (m['firstName'] ?? '').toString().trim();
        final last  = (m['lastName']  ?? '').toString().trim();
        final full  = ('$first $last').trim();
        authorName = full.isEmpty ? null : full;

        final photo = (m['photoUrl'] ?? '').toString().trim();
        if (photo.isNotEmpty) authorPhotoUrl = photo;
      }

      authorName ??= user.displayName?.trim();
      authorName ??= (user.email ?? '').trim();
      if (authorName == null || authorName.isEmpty) authorName = 'Member';

      await _svc.createPost(
        ministryId: widget.ministryId,
        authorId: user.uid,
        authorName: authorName,
        authorPhotoUrl: authorPhotoUrl,
        text: hasText ? _textCtrl.text.trim() : null,
        linkUrl: hasLink ? _linkCtrl.text.trim() : null,
        imageFile: hasImage ? _imageFile : null,
      );

      _textCtrl.clear();
      _linkCtrl.clear();
      setState(() => _imageFile = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post created')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<String> _nameForUid(String uid) async {
    if (_uidNameCache.containsKey(uid)) return _uidNameCache[uid]!;
    try {
      final u = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final mid = (u.data() ?? const {})['memberId'] as String?;
      if (mid != null && mid.isNotEmpty) {
        final m = await FirebaseFirestore.instance.collection('members').doc(mid).get();
        final md = m.data() ?? {};
        final full = (md['fullName'] ?? '${(md['firstName'] ?? '').toString().trim()} ${(md['lastName'] ?? '').toString().trim()}').toString().trim();
        if (full.isNotEmpty) {
          _uidNameCache[uid] = full;
          return full;
        }
      }
    } catch (_) {}
    _uidNameCache[uid] = 'Member';
    return 'Member';
  }

  @override
  Widget build(BuildContext context) {
    final bool isAdmin = _myRoles.contains('admin') || _singleRole == 'admin';
    return Scaffold(
      appBar: AppBar(title: Text('${widget.ministryName} Feed')),
      body: Column(
        children: [
          if (_isMemberOfThis) // composer visible only to members
            _Composer(
              textCtrl: _textCtrl,
              linkCtrl: _linkCtrl,
              imageFile: _imageFile,
              onPickImage: _svc.hasStorage ? _pickImage : null,
              storageEnabled: _svc.hasStorage,
              onSubmit: _submit,
              posting: _posting,
            )
          else
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Only members of ${widget.ministryName} can post.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 0),
          Expanded(
            child: StreamBuilder<List<PostModel>>(
              stream: _svc.watchMinistryPosts(widget.ministryId),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final posts = snap.data ?? const [];
                if (posts.isEmpty) {
                  return const Center(child: Text('No posts yet. Be the first to share!'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemBuilder: (_, i) => _PostCard(
                    post: posts[i],
                    ministryId: widget.ministryId,
                    ministryName: widget.ministryName,
                    isAdmin: isAdmin,
                    isMemberOfThis: _isMemberOfThis,
                    onToggleLike: (p) async {
                      final uid = FirebaseAuth.instance.currentUser?.uid;
                      if (uid == null) return;
                      final ref = FirebaseFirestore.instance
                          .collection('ministries').doc(widget.ministryId)
                          .collection('posts').doc(p.id);
                      final liked = (p.likes ?? const <String>[]).contains(uid);
                      await ref.update({
                        'likes': liked
                            ? FieldValue.arrayRemove([uid])
                            : FieldValue.arrayUnion([uid]),
                        'updatedAt': FieldValue.serverTimestamp(),
                      });
                    },
                    onReact: (p, emoji) async {
                      final uid = FirebaseAuth.instance.currentUser?.uid;
                      if (uid == null) return;
                      final reacts = FirebaseFirestore.instance
                          .collection('ministries').doc(widget.ministryId)
                          .collection('posts').doc(p.id)
                          .collection('reactions');

                      // toggle same emoji by same user: delete if exists else create
                      final qs = await reacts
                          .where('authorUid', isEqualTo: uid)
                          .where('emoji', isEqualTo: emoji)
                          .limit(1).get();
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
                    },
                    onDelete: (p) async {
                      try {
                        await _svc.deletePost(
                          ministryId: widget.ministryId,
                          postId: p.id,
                          imageUrl: p.imageUrl,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Post deleted')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to delete: $e')),
                          );
                        }
                      }
                    },
                    commentBuilder: (postId) => _CommentsBlock(
                      ministryId: widget.ministryId,
                      postId: postId,
                      canComment: _isMemberOfThis,
                      nameForUid: _nameForUid,
                    ),
                  ),
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemCount: posts.length,
                );
              },
            ),
          )
        ],
      ),
    );
  }
}

// ================= Composer =================

class _Composer extends StatelessWidget {
  final TextEditingController textCtrl;
  final TextEditingController linkCtrl;
  final File? imageFile;
  final VoidCallback? onPickImage;
  final VoidCallback onSubmit;
  final bool posting;
  final bool storageEnabled;

  const _Composer({
    required this.textCtrl,
    required this.linkCtrl,
    required this.imageFile,
    required this.onPickImage,
    required this.onSubmit,
    required this.posting,
    required this.storageEnabled,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: textCtrl,
            maxLines: null,
            decoration: const InputDecoration(
              hintText: "What's on your mind?",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: linkCtrl,
            decoration: const InputDecoration(
              hintText: 'Optional link (https://...)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (storageEnabled)
                OutlinedButton.icon(
                  onPressed: onPickImage,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Add image'),
                )
              else
                const Text(
                  'Images disabled (Storage not configured)',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              const SizedBox(width: 8),
              if (imageFile != null)
                Expanded(
                  child: Text(
                    imageFile!.path.split('/').last,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: posting ? null : onSubmit,
                icon: const Icon(Icons.send),
                label: Text(posting ? 'Posting...' : 'Post'),
              ),
            ],
          )
        ],
      ),
    );
  }
}

// ================= Post Card =================

typedef ReactFn = Future<void> Function(PostModel post, String emoji);
typedef ToggleLikeFn = Future<void> Function(PostModel post);
typedef DeletePostFn = Future<void> Function(PostModel post);
typedef CommentBuilder = Widget Function(String postId);

class _PostCard extends StatelessWidget {
  final PostModel post;
  final String ministryId;
  final String ministryName;
  final bool isAdmin;
  final bool isMemberOfThis;
  final ToggleLikeFn onToggleLike;
  final ReactFn onReact;
  final DeletePostFn onDelete;
  final CommentBuilder commentBuilder;

  const _PostCard({
    required this.post,
    required this.ministryId,
    required this.ministryName,
    required this.isAdmin,
    required this.isMemberOfThis,
    required this.onToggleLike,
    required this.onReact,
    required this.onDelete,
    required this.commentBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final isAuthor = uid != null && uid == post.authorId;

    final canDelete = isAuthor || isAdmin;

    final likes = post.likes ?? const <String>[];
    final iLiked = uid != null && likes.contains(uid);
    final likeCount = likes.length;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            ListTile(
              leading: CircleAvatar(
                backgroundImage:
                (post.authorPhotoUrl != null && post.authorPhotoUrl!.isNotEmpty)
                    ? NetworkImage(post.authorPhotoUrl!)
                    : null,
                child: (post.authorPhotoUrl == null || post.authorPhotoUrl!.isEmpty)
                    ? const Icon(Icons.person)
                    : null,
              ),
              title: Text(post.authorName ?? 'Member',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                post.createdAt.toLocal().toString(),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: canDelete
                  ? PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'delete') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Delete post?'),
                        content: const Text('This action cannot be undone.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await onDelete(post);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline),
                        SizedBox(width: 8),
                        Text('Delete'),
                      ],
                    ),
                  ),
                ],
              )
                  : null,
            ),

            // Text
            if ((post.text ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
                child: Text(post.text!.trim()),
              ),

            // Link preview
            if ((post.linkUrl ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: FutureBuilder<lps.LinkPreview>(
                  future: lps.LinkPreviewService.instance.fetch(post.linkUrl!.trim()),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          children: const [
                            SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Fetching preview...'),
                          ],
                        ),
                      );
                    }
                    final servicePreview = snap.data;
                    if (servicePreview == null) {
                      Uri? uri;
                      try { uri = Uri.parse(post.linkUrl!.trim()); } catch (_) {}
                      final host = uri?.host.isNotEmpty == true ? uri!.host : post.linkUrl!.trim();
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: ActionChip(
                          avatar: const Icon(Icons.link),
                          label: Text(host),
                          onPressed: () => launchUrl(
                            Uri.parse(post.linkUrl!.trim()),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      );
                    }
                    final cardPreview = lp.LinkPreview(
                      title: servicePreview.title,
                      description: servicePreview.description,
                      imageUrl: servicePreview.imageUrl, url: '',
                    );
                    return LinkPreviewCard(preview: cardPreview);
                  },
                ),
              ),

            // Image
            if ((post.imageUrl ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  post.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
                ),
              ),
            ],

            // Reactions row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: iLiked ? 'Unlike' : 'Like',
                    icon: Icon(iLiked ? Icons.favorite : Icons.favorite_border),
                    onPressed: isMemberOfThis ? () => onToggleLike(post) : null,
                  ),
                  Text(likeCount.toString()),
                  const Spacer(),
                  // Simple set of emojis to toggle
                  for (final e in const ['👍','❤️','😂','🙏','🔥'])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: TextButton(
                        onPressed: isMemberOfThis ? () => onReact(post, e) : null,
                        child: Text(e, style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                ],
              ),
            ),

            const Divider(height: 12),
            // Comments
            commentBuilder(post.id),
          ],
        ),
      ),
    );
  }
}

// ================ Comments Block =================

class _CommentsBlock extends StatefulWidget {
  final String ministryId;
  final String postId;
  final bool canComment;
  final Future<String> Function(String uid) nameForUid;

  const _CommentsBlock({
    required this.ministryId,
    required this.postId,
    required this.canComment,
    required this.nameForUid,
  });

  @override
  State<_CommentsBlock> createState() => _CommentsBlockState();
}

class _CommentsBlockState extends State<_CommentsBlock> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance
          .collection('ministries').doc(widget.ministryId)
          .collection('posts').doc(widget.postId)
          .collection('comments');

  Future<void> _send() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final text = _ctrl.text.trim();
    if (uid == null || text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _col.add({
        'authorId': uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _ctrl.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _col.orderBy('createdAt', descending: false).snapshots(),
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox.shrink();
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              children: [
                for (final c in docs)
                  FutureBuilder<String>(
                    future: widget.nameForUid((c.data()['authorId'] ?? '').toString()),
                    builder: (context, nameSnap) {
                      final name = nameSnap.data ?? 'Member';
                      final text = (c.data()['text'] ?? '').toString();
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(radius: 12, child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
                            const SizedBox(width: 8),
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  style: DefaultTextStyle.of(context).style,
                                  children: [
                                    TextSpan(text: '$name ', style: const TextStyle(fontWeight: FontWeight.w600)),
                                    TextSpan(text: text),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
        if (widget.canComment)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Write a comment...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sending ? null : _send,
                )
              ],
            ),
          ),
      ],
    );
  }
}
