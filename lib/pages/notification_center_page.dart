// lib/pages/notification_center_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart'; // deep link
// If you have a "JoinRequestsPage", add its route and navigate accordingly.

class NotificationCenterPage extends StatefulWidget {
  final String uid;

  const NotificationCenterPage({
    super.key,
    required this.uid,
  });

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;

  Future<List<Map<String, dynamic>>> _loadItems() async {
    final items = <Map<String, dynamic>>[];
    final now = DateTime.now();

    // -------- 1) Inbox events (Cloud Functions + local feed posts)
    try {
      final inboxSnap = await _db
          .collection('inbox')
          .doc(widget.uid)
          .collection('events')
          .orderBy('createdAt', descending: true)
          .limit(50)
          .get();

      for (final e in inboxSnap.docs) {
        final d = e.data();
        final ts = (d['createdAt'] as Timestamp?)?.toDate() ?? now;
        final type = (d['type'] ?? '').toString();
        final channel = (d['channel'] ?? '').toString();
        final payload = Map<String, dynamic>.from(d['payload'] ?? {});

        String title = (d['title'] ?? '').toString();
        String subtitle = (d['body'] ?? '').toString();

        // friendly subtitle fallbacks
        if (type == 'join_request_created') {
          final name = (d['ministryName'] ?? payload['ministryName'] ?? '').toString();
          subtitle = name.isNotEmpty ? 'Ministry: $name' : subtitle;
        } else if (type == 'join_request_status') {
          final status = (d['status'] ?? '').toString();
          final name = (d['ministryName'] ?? payload['ministryName'] ?? '').toString();
          subtitle = [
            if (status.isNotEmpty) 'Status: $status',
            if (name.isNotEmpty) name,
          ].join(' • ');
        }

        items.add({
          'type': channel.isNotEmpty ? channel : type, // 'feeds' | 'joinreq' | 'leader_joinreq'
          'id': e.id,
          'title': title.isEmpty ? 'Notification' : title,
          'subtitle': subtitle,
          'time': ts,
          'ministryId': d['ministryId'] ?? payload['ministryId'],
          'ministryName': d['ministryName'] ?? payload['ministryName'],
          'route': (d['route'] ?? '').toString(),
        });
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[NotificationCenterPage] inbox load error: $e\n$st');
    }

    // Sort newest first
    items.sort((a, b) => (b['time'] as DateTime).compareTo(a['time'] as DateTime));
    return items;
  }

  void _openItem(Map<String, dynamic> item) {
    final route = (item['route'] ?? '').toString();
    final type = (item['type'] ?? '').toString();
    if (route.isNotEmpty) {
      // If your routes are registered, you can use pushNamed with arguments
      if (route == '/view-ministry' && item['ministryId'] != null) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MinistryDetailsPage(
            ministryId: item['ministryId'].toString(),
            ministryName: (item['ministryName'] ?? '').toString(),
          ),
        ));
        return;
      }
      Navigator.pushNamed(context, route);
      return;
    }

    // Fallbacks based on type/channel
    if (type == 'feeds' && item['ministryId'] != null) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MinistryDetailsPage(
          ministryId: item['ministryId'].toString(),
          ministryName: (item['ministryName'] ?? '').toString(),
        ),
      ));
    } else {
      Navigator.pushNamed(context, '/view-ministry');
    }
  }

  @override
  void initState() {
    super.initState();
    // Mark as seen at top-level (optional)
    _db.collection('inbox').doc(widget.uid).set(
      {'lastSeenAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
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
              final type = (it['type'] ?? '').toString();
              final isPost = type == 'feeds' || type == 'ministry_post';
              final dt = it['time'] as DateTime;
              final when = DateFormat.yMMMd().add_jm().format(dt);

              return InkWell(
                onTap: () => _openItem(it),
                borderRadius: BorderRadius.circular(12),
                child: Ink(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                      isPost ? Colors.indigo.shade50 : Colors.orange.shade50,
                      child: Icon(
                        isPost ? Icons.feed : Icons.how_to_reg,
                        color: isPost ? Colors.indigo : Colors.orange,
                      ),
                    ),
                    title: Text(
                      (it['title'] as String?) ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${(it['subtitle'] ?? '').toString()}\n$when',
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
