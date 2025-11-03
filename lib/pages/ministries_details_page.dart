// lib/pages/ministries_details_page.dart
// Drop-in page: Members (with leader star + moderation) + Feed (emoji reactions, comments)
// and resilient link previews (YouTube thumbnail + social host card fallbacks).

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

// Your existing project deps
import '../models/post_model.dart';
import '../services/post_service.dart';
import '../services/link_preview_service.dart';
import '../widgets/link_preview_card.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // "ministries/{docId}"
  final String ministryName; // e.g., "Ushering" (must match members.ministries[] value)

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Members', icon: Icon(Icons.group_outlined)),
            Tab(text: 'Feed', icon: Icon(Icons.dynamic_feed_outlined)),
            Tab(text: 'Overview', icon: Icon(Icons.info_outline)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
          _FeedTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
          const _OverviewPlaceholder(),
        ],
      ),
    );
  }
}

// ===================================================================
// Members Tab (leader star + moderation)
// ===================================================================
class _MembersTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  const _MembersTab({required this.ministryId, required this.ministryName});

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _searchCtrl = TextEditingController();

  bool _isLeaderHere = false;
  String? _myUid;
  String? _myMemberId;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    _myUid = uid;
    final userSnap = await _db.collection('users').doc(uid).get();
    final data = userSnap.data() ?? {};
    _myMemberId = data['memberId'] as String?;
    final mins = (data['leadershipMinistries'] is List)
        ? List<String>.from(data['leadershipMinistries'])
        : <String>[];
    setState(() {
      _isLeaderHere = mins.map((e) => e.toLowerCase()).contains(widget.ministryName.toLowerCase());
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _membersStream() {
    return _db
        .collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .limit(500)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _joinRequestsStream() {
    if (!_isLeaderHere) {
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }
    return _db
        .collection('join_requests')
        .where('ministryName', isEqualTo: widget.ministryName)
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .limit(50)
        .snapshots();
  }

  Future<void> _approveJoin(String requestId) async {
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'approved',
      'updatedAt': FieldValue.serverTimestamp(),
      'moderatedByUid': _myUid,
    });
    final jr = await _db.collection('join_requests').doc(requestId).get();
    final memberId = jr.data()?['memberId'];
    if (memberId is String && memberId.isNotEmpty) {
      await _db.collection('members').doc(memberId).update({
        'ministries': FieldValue.arrayUnion([widget.ministryName])
      });
    }
  }

  Future<void> _rejectJoin(String requestId) async {
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'rejected',
      'updatedAt': FieldValue.serverTimestamp(),
      'moderatedByUid': _myUid,
    });
  }

  Future<void> _promoteToLeader(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
      'roles': FieldValue.arrayUnion(['leader']),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _demoteLeader(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _removeFromMinistry(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'ministries': FieldValue.arrayRemove([widget.ministryName]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isLeaderHere)
          _JoinRequestsCard(
            stream: _joinRequestsStream(),
            onApprove: _approveJoin,
            onReject: _rejectJoin,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search members (name, email, phone)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (snap.hasError) {
                final err = snap.error.toString();
                final isDenied = err.toLowerCase().contains('permission');
                return _ErrorState(
                  title: isDenied ? 'Access restricted' : 'Something went wrong',
                  message: isDenied
                      ? 'You can only view members in ministries you belong to.'
                      : err,
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snap.data!.docs;
              final members = docs.map((d) => _Member.fromMap(d.id, d.data())).toList();
              members.sort((a, b) => (a.fullName ?? '').toLowerCase()
                  .compareTo((b.fullName ?? '').toLowerCase()));

              final q = _searchCtrl.text.trim().toLowerCase();
              final filtered = q.isEmpty
                  ? members
                  : members.where((m) {
                final f = [
                  m.fullName,
                  m.firstName,
                  m.lastName,
                  m.email,
                  m.phoneNumber,
                ].whereType<String>().map((s) => s.toLowerCase()).join(' ');
                return f.contains(q);
              }).toList();

              if (filtered.isEmpty) {
                return const _EmptyState(
                  title: 'No members found',
                  message: 'Try a different search.',
                );
              }

              return RefreshIndicator(
                onRefresh: () async {
                  await _db
                      .collection('members')
                      .where('ministries', arrayContains: widget.ministryName)
                      .limit(1)
                      .get();
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = filtered[i];
                    final isLeaderHere = m.isLeaderOf(widget.ministryName);
                    final isPastor = m.hasRole('pastor') || (m.isPastor ?? false);
                    final isAdmin = m.hasRole('admin');

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      leading: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _Avatar(initials: m.initials, photoUrl: m.photoUrl),
                          if (isLeaderHere)
                            const Positioned(
                              right: -2,
                              bottom: -2,
                              child: Icon(Icons.star, size: 16, color: Colors.amber),
                            ),
                        ],
                      ),
                      title: Text(
                        m.fullName ?? 'Unknown',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (m.email != null && m.email!.isNotEmpty) Text(m.email!),
                          if (m.phoneNumber != null && m.phoneNumber!.isNotEmpty)
                            Text(m.phoneNumber!),
                          Wrap(
                            spacing: 8,
                            runSpacing: -6,
                            children: [
                              if (isLeaderHere) const _Chip('Leader'),
                              if (isPastor) const _Chip('Pastor'),
                              if (isAdmin) const _Chip('Admin'),
                            ],
                          )
                        ],
                      ),
                      trailing: _isLeaderHere
                          ? PopupMenuButton<String>(
                        onSelected: (value) async {
                          try {
                            if (value == 'promote') {
                              await _promoteToLeader(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Promoted to leader.')),
                              );
                            } else if (value == 'demote') {
                              await _demoteLeader(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Demoted from leader.')),
                              );
                            } else if (value == 'remove') {
                              await _removeFromMinistry(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Removed from ministry.')),
                              );
                            }
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Action failed: $e')),
                            );
                          }
                        },
                        itemBuilder: (context) => [
                          if (!isLeaderHere)
                            const PopupMenuItem(
                                value: 'promote', child: Text('Promote to leader')),
                          if (isLeaderHere)
                            const PopupMenuItem(
                                value: 'demote', child: Text('Demote leader')),
                          const PopupMenuItem(
                              value: 'remove', child: Text('Remove from ministry')),
                        ],
                        icon: const Icon(Icons.more_vert),
                      )
                          : null,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// Join Requests card (leaders only)
class _JoinRequestsCard extends StatelessWidget {
  final Stream<QuerySnapshot<Map<String, dynamic>>> stream;
  final Future<void> Function(String requestId) onApprove;
  final Future<void> Function(String requestId) onReject;

  const _JoinRequestsCard({
    required this.stream,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox.shrink();
        }
        final pending = snap.data!.docs;
        if (pending.isEmpty) return const SizedBox.shrink();

        return Card(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.inbox_outlined),
                    const SizedBox(width: 8),
                    Text('Pending Join Requests (${pending.length})',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 8),
                ...pending.map((d) {
                  final data = d.data();
                  final requesterName =
                  (data['memberName'] ?? data['requesterName'] ?? 'Member').toString();
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_add_alt_1_outlined),
                    title: Text(requesterName),
                    subtitle: Text('Request ID: ${d.id}'),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => onReject(d.id),
                          child: const Text('Reject'),
                        ),
                        ElevatedButton(
                          onPressed: () => onApprove(d.id),
                          child: const Text('Approve'),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ===================================================================
// Feed Tab (emoji reactions + comments + resilient link preview)
// ===================================================================
class _FeedTab extends StatefulWidget {
  final String ministryId;   // ministries/{id}
  final String ministryName; // human-readable name (your memberships use names)

  const _FeedTab({
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
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
      String? authorName;
      String? authorPhotoUrl;

      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final memberId = userDoc.data()?['memberId'] as String?;

      if (memberId != null && memberId.isNotEmpty) {
        final memberDoc =
        await FirebaseFirestore.instance.collection('members').doc(memberId).get();
        final m = memberDoc.data() ?? {};
        final first = (m['firstName'] ?? '').toString().trim();
        final last = (m['lastName'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        authorName = full.isEmpty ? null : full;

        if ((m['photoUrl'] ?? '').toString().isNotEmpty) {
          authorPhotoUrl = (m['photoUrl'] as String).trim();
        }
      }

      authorName ??= user.displayName?.trim();
      authorName ??= (user.email ?? '').trim();
      if (authorName.isEmpty) authorName = 'Member';

      // Normalize link to ensure scheme so previews don't fail
      final normalizedLink = hasLink ? _ensureScheme(_linkCtrl.text.trim()) : null;

      await _svc.createPost(
        ministryId: widget.ministryId,
        authorId: user.uid,
        authorName: authorName,
        authorPhotoUrl: authorPhotoUrl,
        text: hasText ? _textCtrl.text.trim() : null,
        linkUrl: normalizedLink,
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
    final lowerRoles = _myRoles.map((e) => e.toLowerCase()).toList();
    final isAdmin = lowerRoles.contains('admin');
    final isLeaderHere = _myLeaderMins.contains(widget.ministryName);

    return Column(
      children: [
        if (_isMemberOfThis)
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
    );
  }
}

// Composer
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

// ======================= Post Card =======================
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
                backgroundImage: (post.authorPhotoUrl != null && post.authorPhotoUrl!.isNotEmpty)
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

            // Resilient Link Preview
            if ((post.linkUrl ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: _LinkPreviewArea(url: post.linkUrl!.trim()),
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

            // Reactions + Comments
            _EmojiReactions(ministryId: ministryId, postId: post.id),
            _CommentBar(ministryId: ministryId, postId: post.id),
          ],
        ),
      ),
    );
  }
}

// ========= Emoji Reactions =========
// Stored as: ministries/{ministryId}/posts/{postId}/reactions/{uid_emoji}
// { authorUid, emoji, createdAt, updatedAt }
class _EmojiReactions extends StatelessWidget {
  static const List<String> emojis = ['👍', '❤️', '😂', '🙏', '🔥'];

  final String ministryId;
  final String postId;
  const _EmojiReactions({required this.ministryId, required this.postId});

  String _docId(String uid, String emoji) => '${uid}_${emoji.codeUnits.join("-")}';

  Future<void> _toggle(String emoji) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final postRef =
    FirebaseFirestore.instance.collection('ministries').doc(ministryId).collection('posts').doc(postId);
    final docId = _docId(uid, emoji);
    final reactRef = postRef.collection('reactions').doc(docId);

    final snap = await reactRef.get();
    if (snap.exists) {
      await reactRef.delete();
      if (emoji == '❤️') {
        await postRef.update({'likes': FieldValue.arrayRemove([uid])});
      }
    } else {
      await reactRef.set({
        'authorUid': uid,
        'emoji': emoji,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (emoji == '❤️') {
        await postRef.update({'likes': FieldValue.arrayUnion([uid])});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final postRef =
    FirebaseFirestore.instance.collection('ministries').doc(ministryId).collection('posts').doc(postId);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: postRef.collection('reactions').snapshots(),
      builder: (context, snap) {
        final counts = <String, int>{for (final e in emojis) e: 0};
        final mine = <String, bool>{for (final e in emojis) e: false};
        if (snap.hasData) {
          for (final d in snap.data!.docs) {
            final data = d.data();
            final e = (data['emoji'] ?? '').toString();
            if (emojis.contains(e)) {
              counts[e] = (counts[e] ?? 0) + 1;
              if (data['authorUid'] == uid) {
                mine[e] = true;
              }
            }
          }
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Wrap(
            spacing: 6,
            children: emojis.map((e) {
              final active = mine[e] == true;
              final c = counts[e] ?? 0;
              return OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: active ? Colors.blue : Theme.of(context).dividerColor),
                  backgroundColor: active ? Colors.blue.withOpacity(0.08) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: const Size(0, 0),
                ),
                onPressed: uid == null ? null : () => _toggle(e),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e, style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 6),
                    Text(c.toString(), style: const TextStyle(fontSize: 13)),
                  ],
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ========= Comment Bar (opens sheet) =========
class _CommentBar extends StatelessWidget {
  final String ministryId;
  final String postId;
  const _CommentBar({required this.ministryId, required this.postId});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => _CommentsSheet(ministryId: ministryId, postId: postId),
          );
        },
        icon: const Icon(Icons.mode_comment_outlined),
        label: const Text('Comments'),
      ),
    );
  }
}

// ========= Comments Bottom Sheet =========
class _CommentsSheet extends StatefulWidget {
  final String ministryId;
  final String postId;
  const _CommentsSheet({required this.ministryId, required this.postId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _textCtrl = TextEditingController();
  bool _sending = false;

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    final uid = _auth.currentUser?.uid;
    if (text.isEmpty || uid == null) return;
    setState(() => _sending = true);
    try {
      await _db
          .collection('ministries')
          .doc(widget.ministryId)
          .collection('posts')
          .doc(widget.postId)
          .collection('comments')
          .add({
        'authorId': uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _textCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final commentsRef = _db
        .collection('ministries')
        .doc(widget.ministryId)
        .collection('posts')
        .doc(widget.postId)
        .collection('comments')
        .orderBy('createdAt', descending: true);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(height: 8),
            Text('Comments', style: Theme.of(context).textTheme.titleMedium),
            const Divider(height: 16),
            Flexible(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: commentsRef.snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No comments yet. Start the conversation!'),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    reverse: true,
                    itemBuilder: (_, i) {
                      final c = docs[i].data();
                      final text = (c['text'] ?? '').toString();
                      final ts = c['createdAt'];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                        title: Text(text),
                        subtitle: Text(ts is Timestamp ? ts.toDate().toLocal().toString() : ''),
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemCount: docs.length,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Write a comment...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                    label: Text(_sending ? 'Sending...' : 'Send'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ========= YouTube thumbnail fallback widget =========
class _YouTubeThumb extends StatelessWidget {
  final String url;
  final String videoId;
  const _YouTubeThumb({required this.url, required this.videoId});

  @override
  Widget build(BuildContext context) {
    final thumb = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
    return InkWell(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.network(
              thumb,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.ondemand_video_outlined),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(12),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
          )
        ],
      ),
    );
  }
}

// --- Link helpers & resilient preview ---
String _ensureScheme(String u) {
  final t = u.trim();
  if (t.isEmpty) return t;
  if (t.startsWith('http://') || t.startsWith('https://')) return t;
  return 'https://$t';
}

bool _isYouTubeHost(String h) => h.contains('youtube.com') || h.contains('youtu.be');
bool _isInstagramHost(String h) => h.contains('instagram.com');
bool _isXHost(String h) => h == 'x.com' || h.contains('twitter.com');
bool _isTikTokHost(String h) => h.contains('tiktok.com');
bool _isFacebookHost(String h) => h.contains('facebook.com');

Future<dynamic> _safeFetchPreview(String url) async {
  try {
    return await LinkPreviewService.instance.fetch(url);
  } catch (_) {
    return null;
  }
}

class _LinkPreviewArea extends StatelessWidget {
  final String url;
  const _LinkPreviewArea({required this.url});

  @override
  Widget build(BuildContext context) {
    final normalized = _ensureScheme(url);
    Uri? uri;
    try {
      uri = Uri.parse(normalized);
    } catch (_) {}

    // If YouTube, reliably show thumbnail even if preview fetch fails
    if (uri != null && _isYouTubeHost(uri.host)) {
      final ytId = _youtubeId(normalized);
      if (ytId != null) return _YouTubeThumb(url: normalized, videoId: ytId);
    }

    return FutureBuilder(
      future: _safeFetchPreview(normalized),
      builder: (context, snap) {
        // 1) Your service returned rich preview
        if (snap.hasData && snap.data != null) {
          return LinkPreviewCard(preview: snap.data);
        }

        // 2) Social fallbacks for hosts that usually block OG scraping (esp. on Web)
        if (uri != null) {
          final host = uri.host;
          final path = '/${uri.pathSegments.join('/')}';
          if (_isInstagramHost(host) || _isXHost(host) || _isTikTokHost(host) || _isFacebookHost(host)) {
            return _SocialHostCard(
              host: host,
              path: path.isEmpty ? '/' : path,
              onOpen: () => launchUrl(uri!, mode: LaunchMode.externalApplication),
            );
          }
        }

        // 3) Generic fallback
        final hostLabel = (uri?.host ?? 'Open link');
        return Align(
          alignment: Alignment.centerLeft,
          child: ActionChip(
            avatar: const Icon(Icons.link),
            label: Text(hostLabel),
            onPressed: () => launchUrl(Uri.parse(normalized), mode: LaunchMode.externalApplication),
          ),
        );
      },
    );
  }
}

class _SocialHostCard extends StatelessWidget {
  final String host;
  final String path;
  final VoidCallback onOpen;

  const _SocialHostCard({
    required this.host,
    required this.path,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.public)),
        title: Text(host, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        trailing: FilledButton(
          onPressed: onOpen,
          child: const Text('Open'),
        ),
      ),
    );
  }
}

// ========= Helpers =========
String? _youtubeId(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }
    if (uri.host.contains('youtube.com')) {
      if (uri.pathSegments.contains('watch')) {
        return uri.queryParameters['v'];
      }
      if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'shorts') {
        return uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ===================================================================
// Overview Placeholder
// ===================================================================
class _OverviewPlaceholder extends StatelessWidget {
  const _OverviewPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 48),
            const SizedBox(height: 12),
            Text('Overview', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('Replace this with ministry details/description.'),
          ],
        ),
      ),
    );
  }
}

// ===================================================================
// Models & UI helpers for Members tab
// ===================================================================
class _Member {
  final String id;
  final String? firstName;
  final String? lastName;
  final String? fullName;
  final String? email;
  final String? phoneNumber;
  final String? photoUrl;
  final List<dynamic> roles;
  final List<dynamic> leadershipMinistries;
  final List<dynamic> ministries;
  final bool? isPastor;

  _Member({
    required this.id,
    this.firstName,
    this.lastName,
    this.fullName,
    this.email,
    this.phoneNumber,
    this.photoUrl,
    this.roles = const [],
    this.leadershipMinistries = const [],
    this.ministries = const [],
    this.isPastor,
  });

  factory _Member.fromMap(String id, Map<String, dynamic> data) {
    return _Member(
      id: id,
      firstName: data['firstName'] as String?,
      lastName: data['lastName'] as String?,
      fullName: data['fullName'] as String? ?? _composeName(data),
      email: data['email'] as String?,
      phoneNumber: data['phoneNumber'] as String?,
      photoUrl: data['photoUrl'] as String? ?? data['imageUrl'] as String?,
      roles: (data['roles'] is List) ? List.from(data['roles']) : const [],
      leadershipMinistries: (data['leadershipMinistries'] is List)
          ? List.from(data['leadershipMinistries'])
          : const [],
      ministries: (data['ministries'] is List) ? List.from(data['ministries']) : const [],
      isPastor: data['isPastor'] as bool?,
    );
  }

  static String _composeName(Map<String, dynamic> d) {
    final f = (d['firstName'] ?? '').toString().trim();
    final l = (d['lastName'] ?? '').toString().trim();
    final both = ('$f $l').trim();
    return both.isEmpty ? 'Member' : both;
  }

  String get initials {
    final n = (fullName ?? _composeName({
      'firstName': firstName ?? '',
      'lastName': lastName ?? '',
    })).trim();
    if (n.isEmpty) return '?';
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  bool hasRole(String role) {
    final r = role.toLowerCase();
    return roles.map((e) => e.toString().toLowerCase()).contains(r);
  }

  bool isLeaderOf(String ministryName) {
    final m = ministryName.toLowerCase();
    final inLeaderMins =
    leadershipMinistries.map((e) => e.toString().toLowerCase()).contains(m);
    final hasLeaderRole = hasRole('leader');
    final inThisMinistry =
    ministries.map((e) => e.toString().toLowerCase()).contains(m);
    return inLeaderMins || (hasLeaderRole && inThisMinistry);
  }
}

class _Avatar extends StatelessWidget {
  final String initials;
  final String? photoUrl;
  const _Avatar({required this.initials, this.photoUrl});

  @override
  Widget build(BuildContext context) {
    const radius = 22.0;
    if (photoUrl != null && photoUrl!.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(photoUrl!));
    }
    return const CircleAvatar(radius: radius, child: Icon(Icons.person_outline));
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String message;
  const _EmptyState({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_outlined, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String title;
  final String message;
  const _ErrorState({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
