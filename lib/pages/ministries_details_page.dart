// lib/pages/ministries_details_page.dart
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as htmlp;
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // ministries/{docId}
  final String ministryName; // human-readable name used across membership arrays

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage>
    with TickerProviderStateMixin {
  late final TabController _tab;

  bool _loading = true;
  String? _uid;
  String? _memberId;
  Set<String> _roles = {};
  Set<String> _memberMinistriesByName = {};
  bool _canAccess = false;

  final _db = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this); // Members / Feed / Overview
    _bootstrap();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      setState(() => _loading = true);

      final user = FirebaseAuth.instance.currentUser;
      _uid = user?.uid;
      if (_uid == null) {
        setState(() { _loading = false; _canAccess = false; });
        return;
      }

      final userSnap = await _db.collection('users').doc(_uid).get();
      final u = userSnap.data() ?? {};
      _memberId = (u['memberId'] ?? '').toString().isNotEmpty ? (u['memberId'] as String) : null;
      final roles = (u['roles'] is List) ? List<String>.from(u['roles']) : const <String>[];
      _roles = roles.map((e) => e.toString().toLowerCase()).toSet();

      if (_memberId != null) {
        final memSnap = await _db.collection('members').doc(_memberId).get();
        final m = memSnap.data() ?? {};
        _memberMinistriesByName =
        (m['ministries'] is List) ? Set<String>.from(m['ministries']) : <String>{};
      }

      final isAdmin = _roles.contains('admin');
      final isInThisMinistry = _memberMinistriesByName.contains(widget.ministryName);
      _canAccess = isAdmin || isInThisMinistry;

      setState(() => _loading = false);
    } catch (_) {
      setState(() { _loading = false; _canAccess = false; });
    }
  }

  Future<void> _notifyRequester(
      String requesterMemberId,
      String joinRequestId,
      String result,
      ) async {
    String? requesterUid;
    final qs = await _db
        .collection('users')
        .where('memberId', isEqualTo: requesterMemberId)
        .limit(1)
        .get();
    if (qs.docs.isNotEmpty) requesterUid = qs.docs.first.id;
    if (requesterUid == null) return;

    await _db.collection('notifications').add({
      'uid': requesterUid,
      'type': 'join_request.$result',
      'joinRequestId': joinRequestId,
      'ministryName': widget.ministryName,
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
    });
  }

  Future<void> approveJoin(String requestId, String memberId) async {
    try {
      final jrRef = _db.collection('join_requests').doc(requestId);
      final memberRef = _db.collection('members').doc(memberId);

      final snap = await jrRef.get();
      if (snap.exists) {
        final status = (snap.data()?['status'] ?? '').toString().toLowerCase();
        if (status != 'pending') throw Exception('Request already processed');
      }

      await _db.runTransaction((t) async {
        final md = (await t.get(memberRef)).data();
        if (md == null) throw Exception('Member not found');

        final current = List<String>.from(md['ministries'] ?? const <String>[]);
        if (!current.contains(widget.ministryName)) current.add(widget.ministryName);

        t.update(memberRef, {
          'ministries': current,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        t.update(jrRef, {
          'status': 'approved',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      try { await _notifyRequester(memberId, requestId, 'approved'); } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request approved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error approving: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> rejectJoin(String requestId, String memberId) async {
    try {
      final jrRef = _db.collection('join_requests').doc(requestId);

      final snap = await jrRef.get();
      if (snap.exists) {
        final status = (snap.data()?['status'] ?? '').toString().toLowerCase();
        if (status != 'pending') throw Exception('Request already processed');
      }

      await jrRef.update({
        'status': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      try { await _notifyRequester(memberId, requestId, 'rejected'); } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request rejected')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error rejecting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: 'Members'), Tab(text: 'Feed'), Tab(text: 'Overview')],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(
            ministryId: widget.ministryId,
            ministryName: widget.ministryName,
            onApprove: approveJoin,
            onReject: rejectJoin,
          ),
          _FeedTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
          _OverviewTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
        ],
      ),
    );
  }
}

/* ===================== MEMBERS TAB (as you had it, minor tidy) ===================== */

class _MembersTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  final Future<void> Function(String requestId, String memberId) onApprove;
  final Future<void> Function(String requestId, String memberId) onReject;

  const _MembersTab({
    required this.ministryId,
    required this.ministryName,
    required this.onApprove,
    required this.onReject,
  });

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  bool _isLeaderOrAdmin = false;
  String? _myMemberId;

  final Set<String> _busy = <String>{};
  final Set<String> _hidden = <String>{};

  void _setBusy(String id, bool v) {
    if (!mounted) return;
    setState(() { v ? _busy.add(id) : _busy.remove(id); });
  }

  void _setHidden(String id, bool v) {
    if (!mounted) return;
    setState(() { v ? _hidden.add(id) : _hidden.remove(id); });
  }

  @override
  void initState() {
    super.initState();
    _resolveCanModerate();
  }

  Future<void> _resolveCanModerate() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final u = await _db.collection('users').doc(uid).get();
    final data = u.data() ?? {};
    _myMemberId = (data['memberId'] ?? '').toString().isNotEmpty ? (data['memberId'] as String) : null;
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : <String>[];
    final leaderMins = (data['leadershipMinistries'] is List)
        ? List<String>.from(data['leadershipMinistries'])
        : <String>[];
    final rolesLower = roles.map((e) => e.toLowerCase()).toList();
    final can = rolesLower.contains('admin') ||
        (rolesLower.contains('leader') && leaderMins.contains(widget.ministryName));
    if (mounted) setState(() => _isLeaderOrAdmin = can);
  }

  Stream<List<Map<String, dynamic>>> _membersStream() {
    return _db
        .collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .snapshots()
        .map((snap) {
      return snap.docs.map((d) {
        final data = d.data();
        final first = (data['firstName'] ?? '').toString();
        final last = (data['lastName'] ?? '').toString();
        final name = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        final email = (data['email'] ?? '').toString();
        final leadership = (data['leadershipMinistries'] is List)
            ? List<String>.from(data['leadershipMinistries'])
            : <String>[];
        final roles = (data['roles'] is List)
            ? List<String>.from(data['roles']).map((e) => e.toLowerCase()).toSet()
            : <String>{};
        final isLeaderHere = roles.contains('leader') && leadership.contains(widget.ministryName);
        return {
          'memberId': d.id,
          'name': name.isEmpty ? 'Unnamed Member' : name,
          'email': email,
          'isLeader': isLeaderHere,
          'leadershipMinistries': leadership,
          'roles': roles.toList(),
        };
      }).toList();
    });
  }

  Stream<List<Map<String, dynamic>>> _pendingRequests() {
    return _db
        .collection('join_requests')
        .where('status', isEqualTo: 'pending')
        .where('ministryId', whereIn: [widget.ministryName, widget.ministryId])
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .asyncMap((qs) async {
      final out = <Map<String, dynamic>>[];
      for (final doc in qs.docs) {
        if (_hidden.contains(doc.id)) continue;

        final r = doc.data();
        final memberId = (r['memberId'] ?? '').toString();
        final requestedAt =
        (r['requestedAt'] is Timestamp) ? (r['requestedAt'] as Timestamp).toDate() : null;

        String fullName = 'Unknown Member';
        if (memberId.isNotEmpty) {
          final m = await _db.collection('members').doc(memberId).get();
          final md = m.data() ?? {};
          final f = (md['firstName'] ?? '').toString();
          final l = (md['lastName'] ?? '').toString();
          final n = [f, l].where((s) => s.isNotEmpty).join(' ').trim();
          if (n.isNotEmpty) fullName = n;
        }

        out.add({
          'id': doc.id,
          'memberId': memberId,
          'name': fullName,
          'requestedAt': requestedAt,
        });
      }
      return out;
    });
  }

  Future<void> _callSetLeader({
    required String memberId,
    required bool makeLeader,
  }) async {
    final callable = _functions.httpsCallable('leaderSetMemberLeaderRole');
    await callable.call(<String, dynamic>{
      'memberId': memberId,
      'ministryName': widget.ministryName,
      'makeLeader': makeLeader,
    });
  }

  Future<int> _countLeadersInMinistry() async {
    final qs = await _db
        .collection('members')
        .where('leadershipMinistries', arrayContains: widget.ministryName)
        .get();
    return qs.docs.length;
  }

  Future<void> _promoteToLeader(String memberId) async {
    try {
      HapticFeedback.selectionClick();
      await _callSetLeader(memberId: memberId, makeLeader: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Promoted to leader')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error promoting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _demoteFromLeader(String memberId) async {
    try {
      final leadersCount = await _countLeadersInMinistry();
      if (leadersCount <= 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Cannot demote the last leader of this ministry'),
              backgroundColor: Colors.orange),
        );
        return;
      }

      HapticFeedback.selectionClick();
      await _callSetLeader(memberId: memberId, makeLeader: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Demoted from leader')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error demoting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _removeFromMinistry(String memberId) async {
    try {
      final mSnap = await _db.collection('members').doc(memberId).get();
      final m = mSnap.data() ?? {};
      final mLeader = (m['leadershipMinistries'] is List)
          ? List<String>.from(m['leadershipMinistries'])
          : <String>[];
      final roles = (m['roles'] is List)
          ? List<String>.from(m['roles']).map((e) => e.toLowerCase()).toSet()
          : <String>{};
      final isLeaderHere =
          roles.contains('leader') && mLeader.contains(widget.ministryName);

      if (isLeaderHere) {
        final leadersCount = await _countLeadersInMinistry();
        if (leadersCount <= 1) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Cannot remove the last leader of this ministry'),
                backgroundColor: Colors.orange),
          );
          return;
        }
        await _callSetLeader(memberId: memberId, makeLeader: false);
      }

      final memberRef = _db.doc('members/$memberId');
      await memberRef.set({
        'ministries': FieldValue.arrayRemove([widget.ministryName]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Member removed from ministry')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error removing: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        if (_isLeaderOrAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Pending Join Requests',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
        if (_isLeaderOrAdmin)
          SizedBox(
            height: 156,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _pendingRequests(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snap.hasData) {
                  return const Center(child: Text('No pending requests.'));
                }
                final reqs = snap.data!;
                if (reqs.isEmpty) {
                  return const Center(child: Text('No pending requests.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  scrollDirection: Axis.horizontal,
                  itemCount: reqs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final r = reqs[i];
                    final when = (r['requestedAt'] is DateTime)
                        ? DateFormat('dd MMM, HH:mm').format(r['requestedAt'] as DateTime)
                        : '—';
                    final id = r['id'] as String;
                    final name = (r['name'] as String?)?.trim().isNotEmpty == true
                        ? r['name'] as String
                        : 'Unknown Member';
                    final loading = _busy.contains(id);

                    return SizedBox(
                      width: 320,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                child: Text(
                                  _initials(name),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text('Requested: $when',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (loading)
                                const SizedBox(
                                  width: 28, height: 28,
                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                )
                              else
                                Row(
                                  children: [
                                    IconButton(
                                      tooltip: 'Approve',
                                      icon: const Icon(Icons.check_circle),
                                      onPressed: () async {
                                        HapticFeedback.lightImpact();
                                        _setBusy(id, true);
                                        try {
                                          await widget.onApprove(id, r['memberId'] as String);
                                          _setHidden(id, true);
                                        } catch (e) {
                                          _setBusy(id, false);
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Approve failed: $e'), backgroundColor: Colors.red),
                                          );
                                        } finally {
                                          _setBusy(id, false);
                                        }
                                      },
                                      color: Colors.green,
                                    ),
                                    IconButton(
                                      tooltip: 'Reject',
                                      icon: const Icon(Icons.cancel),
                                      onPressed: () async {
                                        HapticFeedback.lightImpact();
                                        _setBusy(id, true);
                                        try {
                                          await widget.onReject(id, r['memberId'] as String);
                                          _setHidden(id, true);
                                        } catch (e) {
                                          _setBusy(id, false);
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Reject failed: $e'), backgroundColor: Colors.red),
                                          );
                                        } finally {
                                          _setBusy(id, false);
                                        }
                                      },
                                      color: Colors.red,
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

        const SizedBox(height: 12),
        SizedBox(
          height: 520,
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final members = snap.data!;
              if (members.isEmpty) return const Center(child: Text('No members yet.'));
              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: members.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final m = members[i];
                  final memberId = m['memberId'] as String;
                  return Card(
                    child: ListTile(
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              m['name'] ?? 'Unnamed Member',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if ((m['isLeader'] ?? false) == true)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.star_rounded, size: 20, color: Colors.amberAccent),
                            ),
                        ],
                      ),
                      subtitle: Text(m['email'] ?? '', style: const TextStyle(color: Colors.black54)),
                      trailing: (_isLeaderOrAdmin && (memberId != _myMemberId))
                          ? PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'promote') {
                            await _promoteToLeader(memberId);
                          } else if (value == 'demote') {
                            await _demoteFromLeader(memberId);
                          } else if (value == 'remove') {
                            await _removeFromMinistry(memberId);
                          }
                        },
                        itemBuilder: (context) {
                          final isLeader = (m['isLeader'] ?? false) == true;
                          return <PopupMenuEntry<String>>[
                            if (!isLeader)
                              const PopupMenuItem<String>(
                                value: 'promote',
                                child: ListTile(leading: Icon(Icons.arrow_upward), title: Text('Promote to leader')),
                              ),
                            if (isLeader)
                              const PopupMenuItem<String>(
                                value: 'demote',
                                child: ListTile(leading: Icon(Icons.arrow_downward), title: Text('Demote from leader')),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem<String>(
                              value: 'remove',
                              child: ListTile(leading: Icon(Icons.person_remove), title: Text('Remove from ministry')),
                            ),
                          ];
                        },
                      )
                          : null,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts.first.characters.take(1).toString() + parts.last.characters.take(1).toString()).toUpperCase();
  }
}

/* ===================== FEED TAB (Instagram-like + Link previews) ===================== */

class _FeedTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  const _FeedTab({required this.ministryId, required this.ministryName});

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _storage = FirebaseStorage.instance;
  final _picker = ImagePicker();

  String? _uid;
  String? _displayName;
  String? _memberId;
  bool _isAdmin = false;
  bool _isLeaderHere = false;
  bool _isMemberHere = false;

  final _postCtrl = TextEditingController();
  File? _imageFile;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final user = _auth.currentUser;
    _uid = user?.uid;
    if (_uid == null) return;

    final userDoc = await _db.collection('users').doc(_uid).get();
    final ud = userDoc.data() ?? {};
    _memberId = (ud['memberId'] ?? '').toString().isNotEmpty ? ud['memberId'] as String : null;
    final roles = (ud['roles'] is List) ? List<String>.from(ud['roles']).map((e) => e.toString().toLowerCase()).toSet() : <String>{};
    final leaderMins = (ud['leadershipMinistries'] is List) ? List<String>.from(ud['leadershipMinistries']) : const <String>[];

    _isAdmin = roles.contains('admin');
    _isLeaderHere = roles.contains('leader') && leaderMins.contains(widget.ministryName);

    String? name = (ud['displayName'] ?? ud['name'])?.toString();
    if (_memberId != null) {
      final mem = await _db.collection('members').doc(_memberId).get();
      final md = mem.data() ?? {};
      final mins = (md['ministries'] is List) ? List<String>.from(md['ministries']) : const <String>[];
      _isMemberHere = mins.contains(widget.ministryName);
      name ??= (md['fullName'] ??
          ([md['firstName'], md['lastName']].where((e) => (e ?? '').toString().trim().isNotEmpty).join(' ').trim())
      ).toString();
    }
    name ??= _auth.currentUser?.displayName ?? _auth.currentUser?.email?.split('@').first ?? 'Member';
    if (mounted) setState(() => _displayName = name);
  }

  @override
  void dispose() {
    _postCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x != null) setState(() => _imageFile = File(x.path));
  }

  Future<String?> _uploadImage(String postId) async {
    if (_imageFile == null || _uid == null) return null;
    final ref = _storage.ref().child('ministry_posts/${widget.ministryId}/$postId.jpg');
    await ref.putFile(_imageFile!, SettableMetadata(contentType: 'image/jpeg'));
    return await ref.getDownloadURL();
  }

  bool get _canCreatePost => _isAdmin || _isLeaderHere || _isMemberHere;

  // --- Link utilities ---
  static final _urlRegex = RegExp(
    r'((https?:\/\/)?((www\.)?)[^\s]+\.[^\s]{2,}([^\s]*)?)',
    caseSensitive: false,
  );

  List<String> _extractLinkStrings(String? text) {
    if (text == null || text.isEmpty) return const [];
    final matches = _urlRegex.allMatches(text);
    final out = <String>[];
    for (final m in matches) {
      final raw = m.group(0)!;
      final withScheme = raw.startsWith('http') ? raw : 'https://$raw';
      try {
        final u = Uri.parse(withScheme);
        if (u.host.isNotEmpty) out.add(u.toString());
      } catch (_) {}
    }
    return out;
  }

  List<Uri> _extractUrls(String? text) =>
      _extractLinkStrings(text).map((s) => Uri.parse(s)).toList();

  bool _isYouTube(Uri u) => u.host.contains('youtube.com') || u.host.contains('youtu.be');
  String? _youtubeId(Uri u) => YoutubePlayer.convertUrlToId(u.toString());

  // Render text with clickable links (no extra packages)
  Widget _linkifiedText(String? text) {
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final spans = <TextSpan>[];
    int last = 0;
    for (final m in _urlRegex.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final urlRaw = m.group(0)!;
      final url = urlRaw.startsWith('http') ? urlRaw : 'https://$urlRaw';
      spans.add(
        TextSpan(
          text: urlRaw,
          style: const TextStyle(color: Colors.blue),
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: RichText(text: TextSpan(style: const TextStyle(color: Colors.black87, height: 1.3), children: spans)),
    );
  }

  Future<void> _createPost() async {
    if (_uid == null || !_canCreatePost) return;
    final text = _postCtrl.text.trim();
    final links = _extractLinkStrings(text);

    if (text.isEmpty && _imageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add text or an image for your post')),
      );
      return;
    }

    setState(() => _posting = true);
    try {
      final posts = _db.collection('ministries').doc(widget.ministryId).collection('posts');
      final ref = posts.doc();

      // Ensure at least one of text/links/media is present on CREATE to satisfy rules.
      final hasText = text.isNotEmpty;
      final hasLinks = links.isNotEmpty;
      final hasImage = _imageFile != null;

      await ref.set({
        'id': ref.id,
        'authorId': _uid,
        'authorName': _displayName ?? 'Member',
        'text': hasText ? text : null,
        'links': hasLinks ? links : [],
        // include media key even if empty (image-only will be updated after upload)
        'media': hasImage ? [] : (hasText || hasLinks ? [] : []),
        'imageUrl': null, // legacy convenience for your UI
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'likes': <String>[],
      });

      if (_imageFile != null) {
        final url = await _uploadImage(ref.id);
        await ref.update({
          'imageUrl': url,
          'media': url == null ? [] : [
            {
              'type': 'image',
              'url': url,
            }
          ],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      setState(() {
        _postCtrl.clear();
        _imageFile = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Post failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _posting = false);
    }
  }

  Future<void> _toggleLike(DocumentReference postRef, List<dynamic> likes) async {
    final uid = _uid;
    if (uid == null) return;
    final hasLiked = likes.contains(uid);
    // Only update 'likes' so it passes security rules
    await postRef.update({
      'likes': hasLiked ? FieldValue.arrayRemove([uid]) : FieldValue.arrayUnion([uid]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _deletePost(DocumentSnapshot postDoc) async {
    try {
      final postRef = postDoc.reference;
      final data = postDoc.data() as Map<String, dynamic>? ?? {};
      final imageUrl = data['imageUrl'] as String?;

      final comments = await postRef.collection('comments').get();
      for (final d in comments.docs) {
        await d.reference.delete();
      }
      if (imageUrl != null && imageUrl.isNotEmpty) {
        try {
          final ref = await _storage.refFromURL(imageUrl);
          await ref.delete();
        } catch (_) {}
      }
      await postRef.delete();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post deleted')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _openComments(DocumentReference postRef) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => _CommentsSheet(
        postRef: postRef,
        currentUid: _uid,
        canModerate: _isAdmin || _isLeaderHere,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final postsQ = _db
        .collection('ministries')
        .doc(widget.ministryId)
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .limit(50);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Composer
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(child: Text((_displayName ?? 'M').characters.first.toUpperCase())),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _postCtrl,
                          decoration: InputDecoration(
                            hintText: _canCreatePost
                                ? "Share something with the ministry... (links supported)"
                                : "Only members can post in this ministry",
                            border: InputBorder.none,
                          ),
                          enabled: _canCreatePost && !_posting,
                          maxLines: null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_imageFile != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(_imageFile!, height: 200, width: double.infinity, fit: BoxFit.cover),
                    ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _canCreatePost && !_posting ? _pickImage : null,
                        icon: const Icon(Icons.photo),
                        label: const Text('Photo'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _canCreatePost && !_posting ? _createPost : null,
                        icon: _posting
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: const Text('Post'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Feed
          StreamBuilder<QuerySnapshot>(
            stream: postsQ.snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: CircularProgressIndicator(),
                ));
              }
              final docs = snap.data?.docs ?? const [];
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text('No posts yet.'),
                );
              }
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final authorName = (data['authorName'] ?? 'Member').toString();
                  final authorId = (data['authorId'] ?? '').toString();
                  final text = (data['text'] ?? '').toString();
                  final imageUrl = (data['imageUrl'] ?? '').toString();
                  final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
                  final likes = (data['likes'] is List) ? List<String>.from(data['likes']) : <String>[];
                  final youLiked = _uid != null && likes.contains(_uid);
                  final canDelete = (_uid != null && authorId == _uid) || _isAdmin || _isLeaderHere;
                  final when = createdAt != null ? DateFormat('dd MMM yyyy • HH:mm').format(createdAt) : '';

                  // URLs in text
                  final urls = _extractUrls(text);

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        ListTile(
                          leading: CircleAvatar(child: Text(authorName.characters.first.toUpperCase())),
                          title: Text(authorName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(when),
                          trailing: canDelete
                              ? PopupMenuButton<String>(
                            onSelected: (v) async { if (v == 'delete') await _deletePost(d); },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(children: [Icon(Icons.delete_outline), SizedBox(width: 8), Text('Delete post')]),
                              ),
                            ],
                          )
                              : null,
                        ),

                        if (text.isNotEmpty) _linkifiedText(text),

                        if (imageUrl.isNotEmpty)
                          ClipRect(
                            child: Image.network(
                              imageUrl,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              loadingBuilder: (context, child, progress) {
                                if (progress == null) return child;
                                return SizedBox(
                                  height: 220,
                                  child: Center(
                                    child: CircularProgressIndicator(value: progress.expectedTotalBytes != null
                                        ? progress.cumulativeBytesLoaded / (progress.expectedTotalBytes ?? 1)
                                        : null),
                                  ),
                                );
                              },
                              errorBuilder: (_, __, ___) => const SizedBox(
                                height: 200, child: Center(child: Text('Image unavailable')),
                              ),
                            ),
                          ),

                        // --- Link previews ---
                        if (urls.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Column(
                              children: urls.map((u) {
                                if (_isYouTube(u) && _youtubeId(u) != null) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: YouTubePreviewCard(
                                      url: u,
                                      onPlay: () {
                                        final id = _youtubeId(u)!;
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          useSafeArea: true,
                                          builder: (_) => _YouTubePlayerSheet(videoId: id),
                                        );
                                      },
                                    ),
                                  );
                                }
                                // Generic OpenGraph preview (also covers Instagram/Twitter/links)
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: LinkPreviewCard(url: u),
                                );
                              }).toList(),
                            ),
                          ),

                        const SizedBox(height: 6),
                        // Actions
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () => _toggleLike(d.reference, likes),
                                icon: Icon(youLiked ? Icons.favorite : Icons.favorite_border),
                                color: youLiked ? Colors.redAccent : null,
                                tooltip: youLiked ? 'Unlike' : 'Like',
                              ),
                              StreamBuilder<QuerySnapshot>(
                                stream: d.reference.collection('comments').orderBy('createdAt', descending: false).snapshots(),
                                builder: (context, csnap) {
                                  final count = csnap.data?.size ?? 0;
                                  return Text('$count comments', style: const TextStyle(color: Colors.black54));
                                },
                              ),
                              const Spacer(),
                              Text('${likes.length} likes', style: const TextStyle(color: Colors.black54)),
                              IconButton(
                                tooltip: 'Comments',
                                onPressed: () => _openComments(d.reference),
                                icon: const Icon(Icons.mode_comment_outlined),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

/* ---- YouTube preview tile ---- */
class YouTubePreviewCard extends StatelessWidget {
  final Uri url;
  final VoidCallback onPlay;

  const YouTubePreviewCard({super.key, required this.url, required this.onPlay});

  String? get _id => YoutubePlayer.convertUrlToId(url.toString());
  String? get _thumb => _id != null ? 'https://img.youtube.com/vi/$_id/hqdefault.jpg' : null;

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    return InkWell(
      onTap: onPlay,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.grey.shade100,
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumb != null)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Image.network(thumb, height: 180, width: double.infinity, fit: BoxFit.cover),
                    Container(
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(40)),
                      padding: const EdgeInsets.all(8),
                      child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                url.toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ---- YouTube player sheet ---- */
class _YouTubePlayerSheet extends StatefulWidget {
  final String videoId;
  const _YouTubePlayerSheet({required this.videoId});

  @override
  State<_YouTubePlayerSheet> createState() => _YouTubePlayerSheetState();
}

class _YouTubePlayerSheetState extends State<_YouTubePlayerSheet> {
  late YoutubePlayerController _controller;
  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController(
      initialVideoId: widget.videoId,
      flags: const YoutubePlayerFlags(autoPlay: true, mute: false),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayerBuilder(
      player: YoutubePlayer(controller: _controller, showVideoProgressIndicator: true),
      builder: (context, player) {
        return Scaffold(
          appBar: AppBar(title: const Text('YouTube')),
          body: Center(child: player),
        );
      },
    );
  }
}

/* ---- Generic link preview card (OpenGraph/Twitter) ---- */
class LinkPreviewCard extends StatefulWidget {
  final Uri url;
  const LinkPreviewCard({super.key, required this.url});

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  bool _loading = true;
  String? _title;
  String? _desc;
  String? _image;
  String? _site;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    // On web, CORS often blocks direct fetches. Just skip (tile will show URL).
    if (kIsWeb) {
      setState(() => _loading = false);
      return;
    }
    try {
      final resp = await http.get(
        widget.url,
        headers: {
          // Use a browser-y UA to avoid some sites blocking previews
          'user-agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
          'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        final doc = htmlp.parse(resp.body);
        String? contentOf(String selector) => doc.querySelector(selector)?.attributes['content'];
        String? textOf(String selector) => doc.querySelector(selector)?.text;

        _title = contentOf('meta[property="og:title"]') ??
            contentOf('meta[name="twitter:title"]') ??
            textOf('title');
        _desc = contentOf('meta[property="og:description"]') ??
            contentOf('meta[name="twitter:description"]') ??
            contentOf('meta[name="description"]');

        var img = contentOf('meta[property="og:image"]') ??
            contentOf('meta[name="twitter:image"]');
        if (img != null && img.isNotEmpty) {
          // fix relative URLs
          final uri = Uri.parse(img);
          if (uri.hasScheme) {
            _image = img;
          } else {
            _image = Uri.parse(widget.url.origin).resolveUri(Uri.parse(img)).toString();
          }
        }

        _site = contentOf('meta[property="og:site_name"]') ?? widget.url.host;
      }
    } catch (_) {
      // ignore; fall back to plain link
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        if (await canLaunchUrl(widget.url)) {
          await launchUrl(widget.url, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.grey.shade100,
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_image != null && _image!.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Image.network(
                  _image!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: _loading
                  ? Row(children: [
                const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(widget.url.toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
              ])
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title ?? widget.url.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if ((_desc ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(_desc!, maxLines: 3, overflow: TextOverflow.ellipsis),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Text(
                      _site ?? widget.url.host,
                      style: const TextStyle(color: Colors.black54, fontSize: 12),
                    ),
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

/* ===================== COMMENTS (rules-compatible) ===================== */

class _CommentsSheet extends StatefulWidget {
  final DocumentReference postRef;
  final String? currentUid;
  final bool canModerate;

  const _CommentsSheet({
    required this.postRef,
    required this.currentUid,
    required this.canModerate,
  });

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _addComment() async {
    final uid = widget.currentUid;
    if (uid == null) return;
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    try {
      final ref = widget.postRef.collection('comments').doc();
      // Write only fields allowed by rules: authorId, text, createdAt (updatedAt optional)
      await ref.set({
        'authorId': uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _ctrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Comment failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteComment(DocumentSnapshot doc) async {
    try {
      await doc.reference.delete();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(999))),
            const SizedBox(height: 12),
            Text('Comments', style: Theme.of(context).textTheme.titleMedium),
            const Divider(height: 16),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: widget.postRef.collection('comments').orderBy('createdAt').snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data?.docs ?? const [];
                  if (docs.isEmpty) {
                    return const Center(child: Text('No comments yet.'));
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      final c = d.data() as Map<String, dynamic>;
                      final authorId = (c['authorId'] ?? '').toString();
                      final text = (c['text'] ?? '').toString();
                      final createdAt = (c['createdAt'] as Timestamp?)?.toDate();
                      final when = createdAt != null ? DateFormat('dd MMM, HH:mm').format(createdAt) : '';

                      return _CommentTile(
                        authorId: authorId,
                        text: text,
                        when: when,
                        canDelete: widget.canModerate || (widget.currentUid != null && widget.currentUid == authorId),
                        onDelete: () => _deleteComment(d),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        hintText: 'Add a comment…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      minLines: 1,
                      maxLines: 3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sending ? null : _addComment,
                    icon: _sending
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: const Text('Send'),
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

class _CommentTile extends StatelessWidget {
  final String authorId;
  final String text;
  final String when;
  final bool canDelete;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.authorId,
    required this.text,
    required this.when,
    required this.canDelete,
    required this.onDelete,
  });

  Future<String> _resolveName() async {
    try {
      final db = FirebaseFirestore.instance;
      final u = await db.collection('users').doc(authorId).get();
      final ud = u.data() ?? {};
      String? name = (ud['displayName'] ?? ud['name'])?.toString();
      final memberId = (ud['memberId'] ?? '').toString();
      if (name == null && memberId.isNotEmpty) {
        final m = await db.collection('members').doc(memberId).get();
        final md = m.data() ?? {};
        name = (md['fullName'] ??
            ([md['firstName'], md['lastName']].where((e) => (e ?? '').toString().trim().isNotEmpty).join(' ').trim())
        ).toString();
      }
      return name ?? 'Member';
    } catch (_) {
      return 'Member';
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _resolveName(),
      builder: (context, snap) {
        final name = snap.data ?? 'Member';
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(child: Text(name.characters.first.toUpperCase())),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('$text\n$when'),
          isThreeLine: true,
          trailing: canDelete
              ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete)
              : null,
        );
      },
    );
  }
}

/* ===================== OVERVIEW TAB ===================== */

class _OverviewTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _OverviewTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final membersQ = db.collection('members').where('ministries', arrayContains: ministryName);
    final leadersQ = db.collection('members').where('leadershipMinistries', arrayContains: ministryName);
    final postsQ = db.collection('ministries').doc(ministryId).collection('posts').orderBy('createdAt', descending: true).limit(5);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          FutureBuilder<QuerySnapshot>(
            future: membersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Members', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: leadersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Leaders', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text('Recent Posts', style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: postsQ.get(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? const [];
              if (docs.isEmpty) return const Text('No posts yet.');
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final title = (data['text'] ?? 'Untitled').toString();
                  final createdAt = (data['createdAt'] is Timestamp) ? (data['createdAt'] as Timestamp).toDate() : null;
                  final when = createdAt != null ? DateFormat('dd MMM yyyy, HH:mm').format(createdAt) : '—';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.article),
                    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(when),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Text(label, style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(value, style: theme.textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
