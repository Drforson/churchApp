// lib/pages/ministries_details_page.dart
// Members list (sorted, leader badges, email/phone) + Pending Join Requests (leaders) + simple Feed
// Drop-in page. Requires: cloud_firestore, cloud_functions, firebase_auth, intl, url_launcher.

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:async/async.dart' show StreamZip;
import 'package:url_launcher/url_launcher.dart';

import '../services/link_preview_service.dart';
import '../models/member_model.dart';

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
  bool _isLeaderHere = false;
  bool _isAdminOrPastor = false;

  // Feed compose
  final _postCtrl = TextEditingController();
  bool _posting = false;

  // Resolve a user's display name from comment.authorId (uid) → users → members.fullName
  final Map<String, String> _uidToNameCache = {};

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
    List<String> leads = (data['leadershipMinistries'] is List) ? List<String>.from(data['leadershipMinistries']) : const <String>[];

    // 🔎 Also check linked member doc for leadershipMinistries (in case user doc isn't synced)
    try {
      final memberId = (data['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        final m = await _db.collection('members').doc(memberId).get();
        final md = m.data() ?? {};
        final mLeads = (md['leadershipMinistries'] is List) ? List<String>.from(md['leadershipMinistries']) : const <String>[];
        // union
        leads = <String>{...leads, ...mLeads}.toList();
      }
    } catch (_) {}

    final isAdmin = roles.contains('admin') || roleSingle == 'admin';
    final isPastor = roles.contains('pastor') || roleSingle == 'pastor';
    final isLeaderHere = leads.contains(widget.ministryName) || isAdmin || isPastor;

    setState(() {
      _isLeaderHere = isLeaderHere;
      _isAdminOrPastor = isAdmin || isPastor;
    });
  }

  /* ================= Members Tab ================= */

  // Strongly-typed stream of members in this ministry using MemberModel
  Stream<List<MemberModel>> _membersStream() {
    return _db.collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .snapshots()
        .map((qs) {
      final list = qs.docs.map((d) => MemberModel.fromDocument(d)).toList();
      // Sort client-side by lastName, then firstName (case-insensitive)
      list.sort((a, b) {
        final la = (a.lastName).toLowerCase();
        final lb = (b.lastName).toLowerCase();
        final fa = (a.firstName).toLowerCase();
        final fb = (b.firstName).toLowerCase();
        final cmp = la.compareTo(lb);
        return cmp != 0 ? cmp : fa.compareTo(fb);
      });
      return list;
    });
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

  Widget _memberTileFromModel(MemberModel m) {
    final String fullNameRaw = ('${m.firstName} ${m.lastName}').trim();
    final String fullName = fullNameRaw.isEmpty ? 'Member' : fullNameRaw;
    final bool isLeaderOfThis = m.leadershipMinistries.contains(widget.ministryName);
    final email = m.email.trim();
    final phone = (m.phoneNumber ?? '').trim();

    Future<void> _confirmAndRun({
      required String title,
      required String message,
      required Future<void> Function() run,
      String success = 'Done',
    }) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
          ],
        ),
      );
      if (ok == true) {
        try {
          await run();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
          }
        }
      }
    }

    return ListTile(
      leading: CircleAvatar(child: Text(fullName.isNotEmpty ? fullName[0].toUpperCase() : '?')),
      title: Row(
        children: [
          if (isLeaderOfThis) ...[
            const Icon(Icons.star_rounded, size: 18),
            const SizedBox(width: 4),
          ],
          Expanded(child: Text(fullName, overflow: TextOverflow.ellipsis)),
          if (isLeaderOfThis)
            Padding(
              padding: const EdgeInsets.only(left: 6.0),
              child: Chip(
                label: const Text('Leader'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (email.isNotEmpty) Text(email),
          if (phone.isNotEmpty) Text(phone, style: const TextStyle(fontSize: 12)),
        ],
      ),
      isThreeLine: phone.isNotEmpty,
      trailing: _isLeaderHere
          ? PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'promote') {
            _confirmAndRun(
              title: 'Promote to Leader',
              message: 'Give $fullName leader permissions in ${widget.ministryName}?',
              run: () => _promoteDemote(memberId: m.id, makeLeader: true),
              success: 'Promoted to leader',
            );
          }
          if (v == 'demote') {
            _confirmAndRun(
              title: 'Demote from Leader',
              message: 'Remove $fullName leader permissions in ${widget.ministryName}?',
              run: () => _promoteDemote(memberId: m.id, makeLeader: false),
              success: 'Demoted from leader',
            );
          }
          if (v == 'remove') {
            _confirmAndRun(
              title: 'Remove from Ministry',
              message: 'Remove $fullName from ${widget.ministryName}? They will lose access to this ministry feed.',
              run: () => _removeFromMinistry(m.id),
              success: 'Removed from ministry',
            );
          }
        },
        itemBuilder: (ctx) => [
          if (!isLeaderOfThis) const PopupMenuItem(
            value: 'promote',
            child: Row(children: [Icon(Icons.upgrade, size: 18), SizedBox(width: 8), Text('Promote to Leader')]),
          ),
          if (isLeaderOfThis) const PopupMenuItem(
            value: 'demote',
            child: Row(children: [Icon(Icons.remove_moderator_outlined, size: 18), SizedBox(width: 8), Text('Demote from Leader')]),
          ),
          const PopupMenuItem(
            value: 'remove',
            child: Row(children: [Icon(Icons.person_remove_outlined, size: 18), SizedBox(width: 8), Text('Remove from Ministry')]),
          ),
        ],
      )
          : null,
    );
  }

  /* ================= Pending Join Requests (leaders only) ================= */
  // Merge multiple queries to cover different stored field styles & status casing
  Stream<List<DocumentSnapshot<Map<String, dynamic>>>> _pendingRequestsMerged() {
    final q1 = _db.collection('join_requests')
        .where('status', isEqualTo: 'pending')
        .where('ministryName', isEqualTo: widget.ministryName)
        .snapshots();
    final q1b = _db.collection('join_requests')
        .where('status', isEqualTo: 'Pending')
        .where('ministryName', isEqualTo: widget.ministryName)
        .snapshots();
    final q2 = _db.collection('join_requests')
        .where('status', isEqualTo: 'pending')
        .where('ministryId', isEqualTo: widget.ministryId)
        .snapshots();
    final q2b = _db.collection('join_requests')
        .where('status', isEqualTo: 'Pending')
        .where('ministryId', isEqualTo: widget.ministryId)
        .snapshots();
    final q3 = _db.collection('join_requests')
        .where('status', isEqualTo: 'pending')
        .where('ministryDocId', isEqualTo: widget.ministryId)
        .snapshots();
    final q3b = _db.collection('join_requests')
        .where('status', isEqualTo: 'Pending')
        .where('ministryDocId', isEqualTo: widget.ministryId)
        .snapshots();

    // combineLatest manually by listening to all and merging unique docs
    return q1.combineLatestAll([q1b, q2, q2b, q3, q3b]).map((lists) {
      final allSnaps = lists.cast<QuerySnapshot<Map<String, dynamic>>>();
      final merged = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final s in allSnaps) {
        for (final d in s.docs) {
          merged[d.id] = d;
        }
      }
      final out = merged.values.toList();
      out.sort((a, b) {
        final ta = (a.data()?['requestedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = (b.data()?['requestedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
      return out;
    });
  }

  Future<void> _moderateJoinRequest(String requestId, String decision) async {
    // decision: 'approved' | 'rejected'
    try {
      await _functions.httpsCallable('leaderModerateJoinRequest').call({
        'requestId': requestId,
        'decision': decision,
      });
    } catch (_) {
      // Fallback to direct write (should be allowed by your rules for leaders)
      await _db.collection('join_requests').doc(requestId).update({
        'status': decision,
        'updatedAt': FieldValue.serverTimestamp(),
        'moderatedByUid': _uid,
      });
    }
  }

  Widget _pendingRequestsSection() {
    if (!_isLeaderHere) return const SizedBox.shrink();
    return StreamBuilder<List<DocumentSnapshot<Map<String, dynamic>>>>(
      stream: _pendingRequestsMerged(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(12.0),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.inbox_outlined),
                title: const Text('No pending requests'),
                subtitle: Text('We look for: status=pending and {ministryName=${widget.ministryName} | ministryId/ministryDocId=${widget.ministryId}}'),
              ),
            ),
          );
        }
        return Card(
          margin: const EdgeInsets.all(12.0),
          child: ExpansionTile(
            initiallyExpanded: true,
            title: Text('Pending Join Requests • ${items.length}'),
            children: [
              for (final r in items)
                _JoinRequestTile(
                  request: r,
                  onApprove: () async {
                    await _moderateJoinRequest(r.id, 'approved');
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request approved')));
                    }
                  },
                  onReject: () async {
                    await _moderateJoinRequest(r.id, 'rejected');
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request rejected')));
                    }
                  },
                ),
            ],
          ),
        );
      },
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
    return FutureBuilder(
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
    final DateTime? createdAt = (d['createdAt'] is Timestamp) ? (d['createdAt'] as Timestamp).toDate() : null;
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
          Column(
            children: [
              if (_isLeaderHere) _pendingRequestsSection(),
              Expanded(
                child: StreamBuilder<List<MemberModel>>(
                  stream: _membersStream(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final members = snap.data ?? const <MemberModel>[];
                    if (members.isEmpty) return const Center(child: Text('No members yet.'));
                    return ListView.separated(
                      itemCount: members.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) => _memberTileFromModel(members[i]),
                    );
                  },
                ),
              ),
            ],
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

class _JoinRequestTile extends StatelessWidget {
  final DocumentSnapshot<Map<String, dynamic>> request;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;

  const _JoinRequestTile({
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  Future<Map<String, String>> _memberBasics(String memberId) async {
    final m = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
    final d = m.data() ?? {};
    final full = (d['fullName'] ?? '${d['firstName'] ?? ''} ${d['lastName'] ?? ''}').toString().trim();
    final email = (d['email'] ?? '').toString().trim();
    final phone = (d['phoneNumber'] ?? d['phone'] ?? '').toString().trim();
    return {
      'name': full.isEmpty ? 'Member' : full,
      'email': email,
      'phone': phone,
    };
  }

  void _showProfileSheet(BuildContext context, Map<String, String> info) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        final name = info['name'] ?? 'Member';
        final email = info['email'] ?? '';
        final phone = info['phone'] ?? '';
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(radius: 18, child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
                  const SizedBox(width: 12),
                  Expanded(child: Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                ],
              ),
              const SizedBox(height: 12),
              if (email.isNotEmpty)
                Row(
                  children: [
                    const Icon(Icons.email_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(email)),
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse('mailto:$email')),
                      child: const Text('Email'),
                    ),
                  ],
                ),
              if (phone.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.phone_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(phone)),
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse('tel:$phone')),
                      child: const Text('Call'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = request.data() ?? {};
    final String memberId = (d['memberId'] ?? '').toString();
    final DateTime? when = (d['requestedAt'] is Timestamp) ? (d['requestedAt'] as Timestamp).toDate() : null;
    final String whenStr = when != null ? DateFormat('dd MMM, HH:mm').format(when) : '';

    return FutureBuilder<Map<String, String>>(
      future: _memberBasics(memberId),
      builder: (context, snap) {
        final name = (snap.data?['name'] ?? 'Member');
        final email = (snap.data?['email'] ?? '');
        final phone = (snap.data?['phone'] ?? '');

        return ListTile(
          leading: CircleAvatar(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
          title: Text(name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(whenStr.isNotEmpty ? 'Requested • $whenStr' : 'Requested'),
              if (email.isNotEmpty) Text(email, style: const TextStyle(fontSize: 12)),
              if (phone.isNotEmpty) Text(phone, style: const TextStyle(fontSize: 12)),
            ],
          ),
          isThreeLine: email.isNotEmpty || phone.isNotEmpty,
          trailing: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: snap.hasData ? () => _showProfileSheet(context, snap.data!) : null,
                child: const Text('Profile'),
              ),
              OutlinedButton(
                onPressed: onReject,
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: onApprove,
                child: const Text('Accept'),
              ),
            ],
          ),
        );
      },
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

extension _CombineExt<T> on Stream<T> {
  Stream<List<T>> combineLatestAll(List<Stream<T>> others) {
    final streams = <Stream<T>>[this, ...others];
    return StreamZip<T>(streams).asBroadcastStream();
  }
}
