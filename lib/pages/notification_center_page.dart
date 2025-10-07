import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'pastor_ministry_approvals_page.dart'; // keep if you want the explicit fallback nav

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

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _authSub = _auth.authStateChanges().listen((u) {
      if (!mounted) return;
      setState(() => _uid = u?.uid);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _authSub = null;
    super.dispose();
  }

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
      batch.update(d.reference, {'read': true, 'readAt': FieldValue.serverTimestamp()});
    }
    await batch.commit();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All notifications marked as read')));
  }

  Future<void> _markOneRead(String eventId) async {
    final uid = _uid;
    if (uid == null) return;
    await _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .doc(eventId)
        .set({'read': true, 'readAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  void _openFromData(Map<String, dynamic> data) {
    final route = (data['route'] ?? '').toString();
    final Map<String, dynamic> routeArgs = (data['routeArgs'] is Map)
        ? Map<String, dynamic>.from(data['routeArgs'] as Map)
        : (data['payload'] is Map
        ? Map<String, dynamic>.from(data['payload'] as Map)
        : const <String, dynamic>{});

    if (route.isEmpty) return;

    // Prefer named routes if configured
    try {
      Navigator.of(context).pushNamed(route, arguments: routeArgs);
      return;
    } catch (_) {
      // Fallback for a couple known routes if you don't use pushNamed
      if (route == '/pastor-approvals') {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
        );
      }
      // Add more explicit fallbacks here if needed.
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
            return const Center(child: Text('No notifications yet'));
          }

          final docs = snap.data!.docs;
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() ?? const <String, dynamic>{};

              // Null-safe field reads
              final title = (data['title'] ?? 'Notification').toString();
              final body = (data['body'] ?? '').toString();
              final channel = (data['channel'] ?? '').toString();

              final createdAtTs = data['createdAt'];
              final createdAt = createdAtTs is Timestamp ? createdAtTs.toDate() : null;

              final read = data['read'] == true;

              final Map<String, dynamic> payload =
              (data['payload'] is Map) ? Map<String, dynamic>.from(data['payload'] as Map) : const {};
              final Map<String, dynamic> routeArgs =
              (data['routeArgs'] is Map) ? Map<String, dynamic>.from(data['routeArgs'] as Map) : const {};

              return Card(
                elevation: read ? 0 : 2,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: read ? Colors.grey.shade300 : Theme.of(context).colorScheme.primary, width: read ? 1 : 1.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  leading: Icon(read ? Icons.notifications_none : Icons.notifications_active),
                  title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (channel.isNotEmpty) Chip(label: Text(channel), visualDensity: VisualDensity.compact),
                          if (createdAt != null)
                            Chip(
                              label: Text(
                                createdAt.toLocal().toString(),
                                overflow: TextOverflow.ellipsis,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (payload.isNotEmpty) const Chip(label: Text('payload'), visualDensity: VisualDensity.compact),
                          if (routeArgs.isNotEmpty) const Chip(label: Text('args'), visualDensity: VisualDensity.compact),
                        ],
                      ),
                    ],
                  ),
                  onTap: () => _openFromData(data),
                  trailing: read
                      ? const SizedBox.shrink()
                      : IconButton(
                    tooltip: 'Mark read',
                    icon: const Icon(Icons.done),
                    onPressed: () => _markOneRead(doc.id),
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
