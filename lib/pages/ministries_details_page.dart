// lib/pages/ministries_details_page.dart
// Drop-in page that shows: members list (with leader moderation actions) and a ministry feed
// Requires: cloud_firestore, cloud_functions, firebase_auth, url_launcher, intl, http, html parser packages.

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/link_preview_service.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // ministries/{docId}
  final String ministryName; // human-readable name used in members[].ministries

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage> with SingleTickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  TabController? _tabs;
  String? _uid;
  Map<String, dynamic>? _userDoc;
  bool _isLeaderHere = false;
  bool _isAdminOrPastor = false;

  // Feed compose
  final _postCtrl = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _bootstrap();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    _postCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final u = _auth.currentUser;
    setState(() { _uid = u?.uid; });
    if (u == null) return;

    final userSnap = await _db.collection('users').doc(u.uid).get();
    final data = userSnap.data() ?? {};
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : const <String>[];
    final roleSingle = (data['role'] ?? '').toString().toLowerCase();
    final leads = (data['leadershipMinistries'] is List) ? List<String>.from(data['leadershipMinistries']) : const <String>[];

    final isAdmin = roles.contains('admin') || roleSingle == 'admin';
    final isPastor = roles.contains('pastor') || roleSingle == 'pastor';
    final isLeaderHere = leads.contains(widget.ministryName) || isAdmin || isPastor;

    setState(() {
      _userDoc = data;
      _isLeaderHere = isLeaderHere;
      _isAdminOrPastor = isAdmin || isPastor;
    });
  }

  /* ================= Members Tab ================= */

  Stream<QuerySnapshot<Map<String, dynamic>>> _membersQuery() {
    // Members who belong to this ministry (by NAME)
    return _db.collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .orderBy('fullName', descending: false)
        .snapshots();
  }

  Future<void> _promoteDemote({required String memberId, required bool makeLeader}) async {
    try {
      await _functions.httpsCallable('setMinistryLeadership').call({
        'memberId': memberId,
        'ministryName': widget.ministryName,
        'makeLeader': makeLeader,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(makeLeader ? 'Promoted to leader' : 'Demoted from leader'))
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Action failed: $e'))
        );
      }
    }
  }

  Future<void> _removeFromMinistry(String memberId) async {
    try {
      await _functions.httpsCallable('removeMemberFromMinistry').call({
        'memberId': memberId,
        'ministryName': widget.ministryName,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed from ministry'))
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Remove failed: $e'))
        );
      }
    }
  }

  Widget _memberTile(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final String fullName = (d['fullName'] ?? '${d['firstName'] ?? ''} ${d['lastName'] ?? ''}').toString().trim();
    final String email = (d['email'] ?? '').toString();
    final List leads = (d['leadershipMinistries'] is List) ? d['leadershipMinistries'] : const [];
    final bool isLeaderOfThis = leads.contains(widget.ministryName);

    return ListTile(
      leading: CircleAvatar(child: Text(fullName.isNotEmpty ? fullName[0].toUpperCase() : '?')),
      title: Text(fullName.isEmpty ? 'Member' : fullName),
      subtitle: Text([
        if (isLeaderOfThis) 'Leader',
        if (email.isNotEmpty) email,
      ].join(' • ')),
      trailing: _isLeaderHere
          ? PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'promote') _promoteDemote(memberId: doc.id, makeLeader: true);
          if (v == 'demote') _promoteDemote(memberId: doc.id, makeLeader: false);
          if (v == 'remove') _removeFromMinistry(doc.id);
        },
        itemBuilder: (ctx) => [
          if (!isLeaderOfThis) const PopupMenuItem(value: 'promote', child: Text('Promote to Leader')),
          if (isLeaderOfThis) const PopupMenuItem(value: 'demote', child: Text('Demote from Leader')),
          const PopupMenuItem(value: 'remove', child: Text('Remove from Ministry')),
        ],
      )
          : null,
    );
  }

  /* ================= Feed Tab ================= */

  CollectionReference<Map<String, dynamic>> get _postsCol =>
      _db.collection('ministries').doc(widget.ministryId).collection('posts');

  Future<void> _createPost() async {
    final text = _postCtrl.text.trim();
    if (text.isEmpty || _uid == null) return;
    setState(() => _posting = true);
    try {
      await _postsCol.add({
        'authorId': _uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'likes': <String>[],
      });
      _postCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Post failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _toggleLike(DocumentSnapshot<Map<String, dynamic>> post) async {
    final likes = List<String>.from(post.data()?['likes'] ?? []);
    if (_uid == null) return;
    final liked = likes.contains(_uid);
    try {
      await post.reference.update({
        'likes': liked
            ? FieldValue.arrayRemove([_uid])
            : FieldValue.arrayUnion([_uid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // ignore
    }
  }

  Future<void> _deletePost(DocumentSnapshot<Map<String, dynamic>> post) async {
    try {
      await post.reference.delete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _commentsStream(DocumentReference<Map<String, dynamic>> postRef) {
    return postRef.collection('comments').orderBy('createdAt', descending: false).snapshots();
  }

  Future<void> _addComment(DocumentReference<Map<String, dynamic>> postRef, String text) async {
    if (text.trim().isEmpty || _uid == null) return;
    await postRef.collection('comments').add({
      'authorId': _uid,
      'text': text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Resolve a user's display name from comment.authorId (uid) → users → members.fullName
  final Map<String, String> _uidToNameCache = {};
  Future<String> _displayNameForUid(String uid) async {
    if (_uidToNameCache.containsKey(uid)) return _uidToNameCache[uid]!;
    try {
      final u = await _db.collection('users').doc(uid).get();
      final memberId = u.data()?['memberId'];
      if (memberId != null) {
        final m = await _db.collection('members').doc(memberId).get();
        final fullName = (m.data()?['fullName'] ?? '${m.data()?['firstName'] ?? ''} ${m.data()?['lastName'] ?? ''}').toString().trim();
        if (fullName.isNotEmpty) {
          _uidToNameCache[uid] = fullName;
          return fullName;
        }
      }
    } catch (_) {}
    return 'Member';
  }

  // Extract first URL from text
  String? _firstUrl(String s) {
    final urlRegex = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    final match = urlRegex.firstMatch(s);
    return match?.group(0);
  }

  Widget _linkPreview(String url) {
    return FutureBuilder<LinkPreview>(
      future: LinkPreviewService.instance.fetch(url),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final data = snap.data;
        if (data == null) return const SizedBox.shrink();
        return InkWell(
          onTap: () async {
            final uri = Uri.tryParse(url);
            if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          child: Card(
            margin: const EdgeInsets.only(top: 8),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.imageUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Image.network(data.imageUrl!, width: 72, height: 72, fit: BoxFit.cover),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (data.title != null) Text(data.title!, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (data.description != null) Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(data.description!, maxLines: 3, overflow: TextOverflow.ellipsis),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Text(url, style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
                        ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _postCard(DocumentSnapshot<Map<String, dynamic>> post) {
    final d = post.data() ?? {};
    final String text = (d['text'] ?? '').toString();
    final String authorId = (d['authorId'] ?? '').toString();
    final List<String> likes = List<String>.from(d['likes'] ?? const <String>[]);
    final int likeCount = likes.length;
    final bool iLiked = _uid != null && likes.contains(_uid);
    final bool canDelete = _uid == authorId || _isLeaderHere || _isAdminOrPastor;
    final createdAt = (d['createdAt'] as Timestamp?)?.toDate();
    final url = _firstUrl(text);

    final postRef = post.reference;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<String>(
              future: _displayNameForUid(authorId),
              builder: (context, snap) {
                final name = snap.data ?? 'Member';
                return Row(
                  children: [
                    CircleAvatar(radius: 14, child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
                    const SizedBox(width: 8),
                    Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (createdAt != null)
                      Text(DateFormat('dd MMM, HH:mm').format(createdAt), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    if (canDelete)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deletePost(post),
                        tooltip: 'Delete post',
                      )
                  ],
                );
              },
            ),
            if (text.isNotEmpty) Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(text),
            ),
            if (url != null) _linkPreview(url),
            Row(
              children: [
                IconButton(
                  icon: Icon(iLiked ? Icons.favorite : Icons.favorite_border),
                  onPressed: () => _toggleLike(post),
                ),
                Text(likeCount.toString()),
              ],
            ),
            const Divider(),
            // Comments
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _commentsStream(postRef),
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                final docs = snap.data!.docs;
                return Column(
                  children: [
                    for (final c in docs)
                      FutureBuilder<String>(
                        future: _displayNameForUid((c['authorId'] ?? '').toString()),
                        builder: (context, s) {
                          final name = s.data ?? 'Member';
                          final txt = (c['text'] ?? '').toString();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(radius: 12, child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
                                const SizedBox(width: 8),
                                Expanded(child: RichText(
                                  text: TextSpan(
                                    style: DefaultTextStyle.of(context).style,
                                    children: [
                                      TextSpan(text: '$name ', style: const TextStyle(fontWeight: FontWeight.w600)),
                                      TextSpan(text: txt),
                                    ],
                                  ),
                                )),
                              ],
                            ),
                          );
                        },
                      ),
                    _CommentComposer(onSend: (t) => _addComment(postRef, t)),
                  ],
                );
              },
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.people_alt_outlined), text: 'Members'),
            Tab(icon: Icon(Icons.forum_outlined), text: 'Feed'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          // MEMBERS
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _membersQuery(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) return const Center(child: Text('No members yet.'));
              return ListView.separated(
                itemCount: docs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _memberTile(docs[i]),
              );
            },
          ),

          // FEED
          Column(
            children: [
              // Composer
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _postCtrl,
                        maxLines: 3,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'Share something with the ministry...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _posting ? null : _createPost,
                      icon: const Icon(Icons.send),
                      label: const Text('Post'),
                    )
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _postsCol.orderBy('createdAt', descending: true).snapshots(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) {
                      return const Center(child: Text('No posts yet. Be the first!'));
                    }
                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, i) => _postCard(docs[i]),
                    );
                  },
                ),
              )
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentComposer extends StatefulWidget {
  final FutureOr<void> Function(String text) onSend;
  const _CommentComposer({required this.onSend});

  @override
  State<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<_CommentComposer> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(t);
      _ctrl.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
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
            onPressed: _sending ? null : _submit,
          )
        ],
      ),
    );
  }
}
