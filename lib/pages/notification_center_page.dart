import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart'; // FIX: needed for Rx.combineLatest4
import 'ministries_details_page.dart';

class NotificationCenterPage extends StatefulWidget {
  final String uid;
  const NotificationCenterPage({super.key, required this.uid});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;

  // FIX: initialize with a harmless stream so it's never uninitialized
  Stream<List<Map<String, dynamic>>> _mergedStream = Stream.value(const []);

  List<String> _roles = [];
  List<String> _myRequestIds = [];

  @override
  void initState() {
    super.initState();

    // FIX: build an initial stream (roles/reqIds empty => only inbox + direct will stream)
    _mergedStream = _buildMergedStream();

    // Load roles + requestIds, then rebuild the stream to include role/requester sources
    _initializeData();

    _markInboxSeen();
  }

  Future<void> _initializeData() async {
    final roles = await _loadUserRoles();
    final reqIds = await _loadMyRecentRequestIdsForToRequester();
    setState(() {
      _roles = roles;
      _myRequestIds = reqIds;
      // FIX: rebuild merged stream now that we have filters
      _mergedStream = _buildMergedStream();
    });
  }

  Future<void> _markInboxSeen() async {
    await _db.collection('inbox').doc(widget.uid).set(
      {'lastSeenAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<List<String>> _loadUserRoles() async {
    try {
      final u = await _db.collection('users').doc(widget.uid).get();
      if (!u.exists) return [];
      final data = u.data() ?? {};
      return List<String>.from(data['roles'] ?? []);
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _loadMyRecentRequestIdsForToRequester() async {
    try {
      final snap = await _db
          .collection('ministry_creation_requests')
          .where('requestedByUid', isEqualTo: widget.uid)
          .orderBy('requestedAt', descending: true)
          .limit(10)
          .get();
      return snap.docs.map((d) => d.id).toList();
    } catch (_) {
      return [];
    }
  }

  Stream<List<Map<String, dynamic>>> _buildMergedStream() {
    final now = DateTime.now();

    // Inbox personal events
    final inboxStream = _db
        .collection('inbox')
        .doc(widget.uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
      final data = d.data();
      final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? now;
      return _normalizeDoc(
        id: d.id,
        ref: d.reference,
        source: 'inbox',
        ts: ts,
        title: data['title'],
        subtitle: data['body'],
        type: data['type'],
        route: data['route'],
        ministryId: data['ministryId'],
        ministryName: data['ministryName'],
        read: data['read'] == true,
      );
    }).toList());

    // Direct user notifications
    final directStream = _db
        .collection('notifications')
        .where('toUid', isEqualTo: widget.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
      final data = d.data();
      final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? now;
      return _normalizeDoc(
        id: d.id,
        ref: d.reference,
        source: 'notifications',
        ts: ts,
        title: data['title'],
        subtitle: data['body'],
        type: data['type'],
        route: data['route'],
        ministryId: data['ministryId'],
        ministryName: data['ministryName'],
        read: data['read'] == true,
      );
    }).toList());

    // Role-based (only if roles available)
    Stream<List<Map<String, dynamic>>> roleStream = Stream.value(const []);
    if (_roles.isNotEmpty) {
      roleStream = _db
          .collection('notifications')
          .where('toRole', whereIn: _roles.take(10).toList())
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((snap) => snap.docs.map((d) {
        final data = d.data();
        final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? now;
        return _normalizeDoc(
          id: d.id,
          ref: d.reference,
          source: 'notifications',
          ts: ts,
          title: data['title'],
          subtitle: data['body'],
          type: data['type'],
          route: data['route'],
          ministryId: data['ministryId'],
          ministryName: data['ministryName'],
          read: data['read'] == true,
        );
      }).toList());
    }

    // Requester notifications (only if recent reqIds available)
    Stream<List<Map<String, dynamic>>> requesterStream = Stream.value(const []);
    if (_myRequestIds.isNotEmpty) {
      requesterStream = _db
          .collection('notifications')
          .where('toRequester', isEqualTo: true)
          .where('requestId', whereIn: _myRequestIds.take(10).toList())
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((snap) => snap.docs.map((d) {
        final data = d.data();
        final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? now;
        return _normalizeDoc(
          id: d.id,
          ref: d.reference,
          source: 'notifications',
          ts: ts,
          title: data['title'],
          subtitle: data['body'],
          type: data['type'],
          route: data['route'],
          ministryId: data['ministryId'],
          ministryName: data['ministryName'],
          read: data['read'] == true,
        );
      }).toList());
    }

    // Merge them live
    return Rx.combineLatest4(
      inboxStream,
      directStream,
      roleStream,
      requesterStream,
          (List<Map<String, dynamic>> a, List<Map<String, dynamic>> b,
          List<Map<String, dynamic>> c, List<Map<String, dynamic>> d) {
        return _mergeAndSort([...a, ...b, ...c, ...d]);
      },
    );
  }

  Map<String, dynamic> _normalizeDoc({
    required String id,
    required DocumentReference ref,
    required String source,
    required DateTime ts,
    String? title,
    String? subtitle,
    String? type,
    String? route,
    String? ministryId,
    String? ministryName,
    bool read = false,
  }) {
    return {
      'id': id,
      'ref': ref,
      'source': source,
      'time': ts,
      'title': (title ?? 'Notification').toString(),
      'subtitle': (subtitle ?? '').toString(),
      'type': (type ?? '').toString(),
      'route': (route ?? '').toString(),
      'ministryId': ministryId,
      'ministryName': ministryName,
      'read': read,
    };
  }

  List<Map<String, dynamic>> _mergeAndSort(List<Map<String, dynamic>> all) {
    final seen = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final it in all) {
      final k = '${it['source']}::${it['id']}';
      if (seen.add(k)) merged.add(it);
    }
    merged.sort((a, b) => (b['time'] as DateTime).compareTo(a['time'] as DateTime));
    return merged;
  }

  Future<void> _markItemRead(Map<String, dynamic> item, bool read) async {
    try {
      final ref = item['ref'] as DocumentReference?;
      await ref?.set({'read': read, 'readAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    try {
      final ref = item['ref'] as DocumentReference?;
      await ref?.delete();
    } catch (_) {}
  }

  void _openItem(Map<String, dynamic> item) async {
    await _markItemRead(item, true);
    final route = item['route']?.toString() ?? '';
    final ministryId = item['ministryId']?.toString() ?? '';
    final ministryName = item['ministryName']?.toString() ?? '';
    final type = item['type']?.toString().toLowerCase() ?? '';

    if (route == '/view-ministry' && ministryId.isNotEmpty) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => MinistryDetailsPage(ministryId: ministryId, ministryName: ministryName),
      ));
      return;
    }
    if ((type.contains('ministry') || type.contains('feed')) && ministryId.isNotEmpty) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => MinistryDetailsPage(ministryId: ministryId, ministryName: ministryName),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // FIX: _mergedStream is always initialized, so we can safely use it here.
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), centerTitle: true),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _mergedStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('No notifications.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final it = items[i];
              final dt = it['time'] as DateTime;
              final when = DateFormat.yMMMd().add_jm().format(dt);
              final read = it['read'] == true;
              final type = it['type'] ?? '';
              final isFeed = type.toString().contains('feed');

              return Dismissible(
                key: ValueKey('${it['source']}::${it['id']}'),
                background: _SwipeBg(icon: Icons.mark_email_read, color: Colors.green, label: 'Read'),
                secondaryBackground: _SwipeBg(icon: Icons.delete_outline, color: Colors.red, label: 'Delete'),
                confirmDismiss: (direction) async {
                  if (direction == DismissDirection.startToEnd) {
                    await _markItemRead(it, true);
                    return false;
                  } else {
                    await _deleteItem(it);
                    return true;
                  }
                },
                child: InkWell(
                  onTap: () => _openItem(it),
                  borderRadius: BorderRadius.circular(12),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: read ? Colors.grey.shade50 : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ListTile(
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            backgroundColor: isFeed ? Colors.indigo.shade50 : Colors.orange.shade50,
                            child: Icon(isFeed ? Icons.feed : Icons.notifications,
                                color: isFeed ? Colors.indigo : Colors.orange),
                          ),
                          if (!read)
                            const Positioned(
                              right: 0,
                              top: 0,
                              child: CircleAvatar(radius: 5, backgroundColor: Colors.red),
                            ),
                        ],
                      ),
                      title: Text(
                        it['title'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: read ? Colors.grey.shade700 : Colors.black,
                        ),
                      ),
                      subtitle: Text('${it['subtitle']}\n$when', maxLines: 3, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      isThreeLine: true,
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

class _SwipeBg extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _SwipeBg({required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: color.withOpacity(0.15),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
