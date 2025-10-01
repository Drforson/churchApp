// lib/pages/ministry_feed_page.dart
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/post_model.dart';
import '../services/post_service.dart';
import '../services/link_preview_service.dart';
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
  bool _isMemberOfThis = false;

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
      _myRoles = List<String>.from(data['roles'] ?? []);
      _myLeaderMins = List<String>.from(data['leadershipMinistries'] ?? []);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Images disabled: Storage not configured')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write something, add a link, or pick an image')),
      );
      return;
    }

    setState(() => _posting = true);
    try {
      // 🔎 get linked member -> build full name
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

        // optional: if you store a photo field on members
        if ((m['photoUrl'] ?? '').toString().isNotEmpty) {
          authorPhotoUrl = (m['photoUrl'] as String).trim();
        }
      }

      // fallbacks if no member record
      authorName ??= user.displayName?.trim();
      authorName ??= (user.email ?? '').trim();
      if (authorName!.isEmpty) authorName = 'Member';

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

  @override
  Widget build(BuildContext context) {
    final isAdmin = _myRoles.contains('admin,leader');
    final isLeaderHere = _myLeaderMins.contains(widget.ministryName);

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
                    leaderMinistries: _myLeaderMins,
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

class _PostCard extends StatelessWidget {
  final PostModel post;
  final String ministryId;
  final String ministryName;
  final bool isAdmin;
  final List<String> leaderMinistries;
  final Future<void> Function(PostModel) onDelete;

  const _PostCard({
    required this.post,
    required this.ministryId,
    required this.ministryName,
    required this.isAdmin,
    required this.leaderMinistries,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final isAuthor = uid != null && uid == post.authorId;
    final isLeaderHere = leaderMinistries.contains(ministryName);
    final canDelete = isAuthor || isAdmin || isLeaderHere;

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
                    if (ok == true) {
                      await onDelete(post);
                    }
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
                child: FutureBuilder(
                  future: LinkPreviewService.instance.fetch(post.linkUrl!.trim()),
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
                    final preview = snap.data;
                    if (preview == null) {
                      // Fallback: simple clickable host chip
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: ActionChip(
                          avatar: const Icon(Icons.link),
                          label: Text(Uri.parse(post.linkUrl!).host),
                          onPressed: () => launchUrl(
                            Uri.parse(post.linkUrl!),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      );
                    }
                    return LinkPreviewCard(preview: preview);
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
          ],
        ),
      ),
    );
  }
}
