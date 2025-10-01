// notification_center_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart'; // for deep-link to a ministry
// import any JoinRequest management page if you have one; otherwise route to ministries list.

class NotificationCenterPage extends StatefulWidget {
  final String uid;
  final String? memberId;
  final List<String> myMinistryNames;

  const NotificationCenterPage({
    super.key,
    required this.uid,
    required this.memberId,
    required this.myMinistryNames,
  });

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    // Mark as "seen" immediately on open (badge resets)
    _db.collection('inbox').doc(widget.uid).set(
      {'lastSeenAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<List<Map<String, dynamic>>> _loadItems() async {
    final List<Map<String, dynamic>> items = [];
    final now = DateTime.now();
    final recentSince = now.subtract(const Duration(days: 30));

    // Ministries -> ids
    if (widget.myMinistryNames.isNotEmpty) {
      final mins = await _db
          .collection('ministries')
          .where('name', whereIn: widget.myMinistryNames.take(10).toList())
          .get();

      for (final m in mins.docs) {
        final posts = await _db
            .collection('ministries')
            .doc(m.id)
            .collection('posts')
            .orderBy('createdAt', descending: true)
            .where('createdAt', isGreaterThan: Timestamp.fromDate(recentSince))
            .limit(20)
            .get();

        for (final p in posts.docs) {
          final d = p.data();
          final ts = (d['createdAt'] as Timestamp?)?.toDate() ?? now;
          items.add({
            'type': 'post',
            'id': p.id,
            'title': (d['title'] ?? 'New post').toString(),
            'subtitle': (d['content'] ?? '').toString(),
            'time': ts,
            'ministryId': m.id,
            'ministryName': (m.data()['name'] ?? '').toString(),
          });
        }
      }
    }

    // Join-requests for me (status changed)
    if (widget.memberId != null) {
      final jr = await _db
          .collection('join_requests')
          .where('memberId', isEqualTo: widget.memberId)
          .orderBy('updatedAt', descending: true)
          .limit(20)
          .get();

      for (final j in jr.docs) {
        final d = j.data();
        final status = (d['status'] ?? 'pending').toString();
        final ts = (d['updatedAt'] as Timestamp?)?.toDate() ??
            (d['requestedAt'] as Timestamp?)?.toDate() ??
            now;

        // Only show non-pending updates as notifications
        if (status != 'pending') {
          items.add({
            'type': 'join',
            'id': j.id,
            'title': 'Join request $status',
            'subtitle': 'Ministry: ${d['ministryId'] ?? 'Unknown'}',
            'time': ts,
            'joinRequestId': j.id,
            'ministryName': (d['ministryId'] ?? '').toString(),
          });
        }
      }
    }

    // Sort newest first
    items.sort((a, b) => (b['time'] as DateTime).compareTo(a['time'] as DateTime));
    return items;
  }

  void _openItem(Map<String, dynamic> item) {
    if (item['type'] == 'post') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MinistryDetailsPage(
          ministryId: item['ministryId'],
          ministryName: item['ministryName'],
        ),
      ));
    } else {
      // Join request → take them to Ministries (or a JoinRequestsPage if you have it)
      Navigator.pushNamed(context, '/view-ministry');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        centerTitle: true,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadItems(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('No notifications.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final it = items[i];
              final isPost = it['type'] == 'post';
              final dt = it['time'] as DateTime;
              final when = DateFormat.yMMMd().add_jm().format(dt);

              return InkWell(
                onTap: () => _openItem(it),
                borderRadius: BorderRadius.circular(12),
                child: Ink(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 4))],
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isPost ? Colors.indigo.shade50 : Colors.orange.shade50,
                      child: Icon(isPost ? Icons.feed : Icons.how_to_reg, color: isPost ? Colors.indigo : Colors.orange),
                    ),
                    title: Text(
                      it['title'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${it['subtitle']}\n$when',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
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
