import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart';
import 'pastor_ministry_approvals_page.dart';

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userDocSub;

  // Live roles from users/{uid}.roles (e.g. ["member","leader","pastor"])
  Set<String> _roles = const <String>{}.toSet();
  bool get _isLeader => _roles.contains('leader');
  bool get _isPastor => _roles.contains('pastor');

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;

    _authSub = _auth.authStateChanges().listen((u) {
      if (!mounted) return;
      setState(() => _uid = u?.uid);
      _wireUserDoc(u?.uid);
    });

    _wireUserDoc(_uid);
  }

  void _wireUserDoc(String? uid) {
    _userDocSub?.cancel();
    if (uid == null) return;
    _userDocSub = _db.doc('users/$uid').snapshots().listen((snap) {
      final data = snap.data();
      final roles = (data?['roles'] is List)
          ? List.from(data!['roles']).map((e) => e.toString()).toSet()
          : <String>{};
      if (!mounted) return;
      setState(() => _roles = roles);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _userDocSub?.cancel();
    super.dispose();
  }

  // ----------------- Helpers -----------------
  String _formatRelative(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds.abs() < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('EEE, d MMM • HH:mm').format(dt);
  }

  T? _firstNonNull<T>(List<T?> items) {
    for (final it in items) {
      if (it != null) return it;
    }
    return null;
  }

  Map<String, dynamic> _asMap(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v as Map);
    return const {};
  }

  String _asString(Object? v) => (v ?? '').toString();

  bool _isMinistryCreationRequest(Map<String, dynamic> data) {
    final payload = _asMap(data['payload']);
    final t = _asString(data['type']).toLowerCase();
    final tp = _asString(payload['type']).toLowerCase();
    final ch = _asString(data['channel']).toLowerCase();

    // Flexible matches your existing patterns
    const candidates = [
      'ministry_creation_request',
      'new_ministry_request',
      'new_ministry_creation',
      'ministry_request',
    ];

    return candidates.contains(t) || candidates.contains(tp) || ch == 'ministry_request';
  }

  // ----------------- Actions -----------------
  Future<void> _markAllRead() async {
    final uid = _uid;
    if (uid == null) return;
    final qs = await _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .where('read', isEqualTo: false)
        .limit(500)
        .get();

    final batch = _db.batch();
    for (final d in qs.docs) {
      batch.update(d.reference, {
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All notifications marked as read')),
    );
  }

  Future<void> _markOneRead(String eventId) async {
    final uid = _uid;
    if (uid == null) return;
    await _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .doc(eventId)
        .set(
      {'read': true, 'readAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<void> _deleteOne(String eventId) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.collection('inbox').doc(uid).collection('events').doc(eventId).delete();
  }

  Future<void> _restoreOne(String eventId, Map<String, dynamic> backup) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.collection('inbox').doc(uid).collection('events').doc(eventId).set(
      backup,
      SetOptions(merge: false),
    );
  }

  Future<void> _openFromData(String docId, Map<String, dynamic> data) async {
    await _markOneRead(docId);

    // Extract helpers
    final route = _asString(data['route']);
    final routeArgs = _asMap(_firstNonNull([data['routeArgs'], data['payload']]));
    final payload = _asMap(data['payload']);

    // Ministry-aware deep link
    final ministryId = _asString(_firstNonNull([
      routeArgs['ministryId'],
      payload['ministryId'],
      data['ministryId'],
    ])).trim();

    final ministryName = _asString(_firstNonNull([
      routeArgs['ministryName'],
      payload['ministryName'],
      data['ministryName'],
    ])).trim();

    final isCreationReq = _isMinistryCreationRequest(data);

    // Role-based routing
    if (_isPastor) {
      // Pastors go straight to approvals page
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
      );
      return;
    }

    if (_isLeader && isCreationReq && ministryId.isNotEmpty) {
      // Leaders seeing a creation request → open the ministry page directly
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MinistryDetailsPage(
            ministryId: ministryId,
            ministryName: ministryName.isEmpty ? 'Ministry' : ministryName,
          ),
        ),
      );
      return;
    }

    // Fallbacks
    if (ministryId.isNotEmpty) {
      try {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MinistryDetailsPage(
              ministryId: ministryId,
              ministryName: ministryName.isEmpty ? 'Ministry' : ministryName,
            ),
          ),
        );
        return;
      } catch (_) {}
    }

    if (route.isNotEmpty) {
      try {
        if (!mounted) return;
        await Navigator.of(context).pushNamed(route, arguments: routeArgs);
        return;
      } catch (_) {
        if (route == '/pastor-approvals' && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
          );
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: const Center(child: Text('Please sign in to see your notifications')),
      );
    }

    final eventsQuery = _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(200);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            onPressed: _markAllRead,
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: eventsQuery.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData || snap.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none, size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('No notifications yet', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            );
          }

          final docs = snap.data!.docs;
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data();

              final title = _asString(data['title']).isEmpty ? 'Notification' : _asString(data['title']);
              final body = _asString(data['body']);
              final channel = _asString(data['channel']);

              final createdAtTs = data['createdAt'];
              final createdAt = createdAtTs is Timestamp ? createdAtTs.toDate() : null;

              final read = data['read'] == true;

              // Keep a backup for undo on delete
              final backup = Map<String, dynamic>.from(data);

              // Dynamic hues: different vibe for unread vs read
              final baseColor = read
                  ? Theme.of(context).colorScheme.surface
                  : Theme.of(context).colorScheme.primaryContainer;

              final gradientStart = read
                  ? Theme.of(context).colorScheme.surface
                  : Theme.of(context).colorScheme.primaryContainer.withOpacity(0.85);

              final gradientEnd = read
                  ? Theme.of(context).colorScheme.surfaceVariant
                  : Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.65);

              return Dismissible(
                key: ValueKey(doc.id),
                direction: DismissDirection.startToEnd, // swipe right to delete
                background: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Theme.of(context).colorScheme.errorContainer,
                        Theme.of(context).colorScheme.errorContainer.withOpacity(0.7),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onErrorContainer, size: 28),
                ),
                onDismissed: (_) async {
                  await _deleteOne(doc.id);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Notification deleted'),
                      action: SnackBarAction(label: 'UNDO', onPressed: () => _restoreOne(doc.id, backup)),
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [gradientStart, gradientEnd],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      if (!read)
                        BoxShadow(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                    ],
                    border: Border.all(
                      color: read
                          ? Theme.of(context).colorScheme.outlineVariant
                          : Theme.of(context).colorScheme.primary.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _openFromData(doc.id, data),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Leading avatar with icon + unread glow
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: !read
                                    ? [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
                                    blurRadius: 12,
                                    spreadRadius: 1,
                                  ),
                                ]
                                    : [],
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary.withOpacity(read ? 0.15 : 0.9),
                                    Theme.of(context).colorScheme.secondary.withOpacity(read ? 0.12 : 0.6),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: Icon(
                                read ? Icons.notifications_none : Icons.notifications_active,
                                size: 24,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Main content
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Title row with timestamp + NEW pill
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            fontWeight: read ? FontWeight.w500 : FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (!read)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
                                            borderRadius: BorderRadius.circular(999),
                                            border: Border.all(
                                              color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
                                            ),
                                          ),
                                          child: Text(
                                            'NEW',
                                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.4,
                                            ),
                                          ),
                                        ),
                                      const SizedBox(width: 6),
                                      if (createdAt != null)
                                        Text(
                                          _formatRelative(createdAt.toLocal()),
                                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                            color: Theme.of(context).colorScheme.outline,
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (body.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      body,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  // Meta chips
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: [
                                      if (channel.isNotEmpty)
                                        Chip(
                                          label: Text(channel),
                                          visualDensity: VisualDensity.compact,
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          padding: EdgeInsets.zero,
                                        ),
                                      if (data['payload'] != null) const _MetaPill('payload'),
                                      if (data['routeArgs'] != null) const _MetaPill('args'),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            // Quick action: mark read
                            if (!read)
                              IconButton(
                                tooltip: 'Mark read',
                                icon: const Icon(Icons.done),
                                onPressed: () => _markOneRead(doc.id),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final String text;
  const _MetaPill(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
