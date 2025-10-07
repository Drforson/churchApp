import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/notification_center.dart';
import '../core/firestore_paths.dart';
import 'ministries_details_page.dart';
import 'pastor_ministry_approvals_page.dart';


class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _center = NotificationCenter.I;
  final _auth = FirebaseAuth.instance;

  List<String> _myRoles = const <String>[];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection(FP.users).doc(uid).get();
    final data = snap.data() ?? {};
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : const <String>[];
    setState(() => _myRoles = roles);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // ---------------- Routing ----------------
  void _openRoute(BuildContext context, String? route, Map<String, dynamic>? routeArgs) {
    switch (route) {
      case '/pastor-approvals':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()));
        break;
      case '/leader-join-requests':
      // You can route to a page that lists leader-facing join requests
      // For now, we bounce to Ministr(ies) page or show a snackbar.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open your ministry page → Join Requests')),
        );
        break;
      case '/my-join-requests':
      // Similarly, route user to the page where they see their pending requests.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open Ministres → My Join Requests')),
        );
        break;
      case '/view-ministry':
      // Expecting routeArgs: { "ministryId": "...", "ministryName": "..." }
        final ministryId = (routeArgs?['ministryId'] ?? '').toString();
        final ministryName = (routeArgs?['ministryName'] ?? '').toString();
        if (ministryId.isNotEmpty && ministryName.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MinistryDetailsPage(ministryId: ministryId, ministryName: ministryName),
            ),
          );
        }
        break;
      default:
      // Unknown route; ignore quietly or show info
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(route == null ? 'No route attached' : 'Unknown route: $route')),
        );
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Inbox'),
            Tab(text: 'Notifications'),
          ],
        ),
        actions: [
          if (_tab.index == 0)
            IconButton(
              tooltip: 'Mark all inbox read',
              onPressed: () async {
                await _center.markAllInboxRead();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All inbox items marked as read')),
                  );
                }
              },
              icon: const Icon(Icons.done_all),
            ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _InboxTab(onOpen: _openRoute),
          _LegacyNotificationsTab(myRoles: _myRoles, onOpen: _openRoute),
        ],
      ),
    );
  }
}

// =========================
// Inbox Tab
// =========================

class _InboxTab extends StatelessWidget {
  final void Function(BuildContext, String?, Map<String, dynamic>?) onOpen;
  const _InboxTab({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: NotificationCenter.I.inboxEventsStream(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data!;
        if (docs.isEmpty) {
          return const Center(child: Text('Your inbox is empty.'));
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final d = docs[i];
            final data = d.data();

            final title = (data['title'] ?? 'Notification').toString();
            final body = (data['body'] ?? '').toString();
            final route = (data['route'] ?? '').toString();
            final routeArgs = (data['routeArgs'] ?? {}) is Map
                ? Map<String, dynamic>.from(data['routeArgs'])
                : <String, dynamic>{};

            final read = data['read'] == true;
            DateTime? createdAt;
            final ts = data['createdAt'];
            if (ts is Timestamp) createdAt = ts.toDate();

            return Dismissible(
              key: ValueKey('inbox_${d.id}'),
              background: Container(
                color: Colors.red,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              direction: DismissDirection.endToStart,
              onDismissed: (_) => NotificationCenter.I.deleteInboxEvent(d.id),
              child: Card(
                child: ListTile(
                  onTap: () => onOpen(context, route.isEmpty ? null : route, routeArgs),
                  title: Row(
                    children: [
                      if (!read) const Icon(Icons.fiber_manual_record, size: 10),
                      if (!read) const SizedBox(width: 6),
                      Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (body.isNotEmpty) Text(body),
                      const SizedBox(height: 4),
                      Text(
                        createdAt != null ? createdAt.toLocal().toString() : '—',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: read ? 'Read' : 'Mark as read',
                    onPressed: read ? null : () => NotificationCenter.I.markInboxEventRead(d.id),
                    icon: Icon(read ? Icons.check_circle : Icons.mark_email_read),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// =========================
// Legacy Notifications Tab
// =========================

class _LegacyNotificationsTab extends StatelessWidget {
  final List<String> myRoles;
  final void Function(BuildContext, String?, Map<String, dynamic>?) onOpen;

  const _LegacyNotificationsTab({required this.myRoles, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final toUid$ = NotificationCenter.I.toUidNotifications();
    final toRole$ = myRoles.isEmpty
        ? const Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>.empty()
        : NotificationCenter.I.toRoleNotifications(roles: myRoles);
    final toRequester$ = NotificationCenter.I.requesterNotifications();

    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: toUid$,
      builder: (context, s1) {
        return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          stream: toRole$,
          builder: (context, s2) {
            return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
              stream: toRequester$,
              builder: (context, s3) {
                if (!(s1.hasData || s2.hasData || s3.hasData)) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                all.addAll(s1.data ?? const []);
                all.addAll(s2.data ?? const []);
                all.addAll(s3.data ?? const []);

                // De-duplicate by doc id (in case same doc matches multiple views)
                final map = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
                for (final d in all) {
                  map[d.id] = d;
                }
                final docs = map.values.toList()
                  ..sort((a, b) {
                    final at = (a.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
                    final bt = (b.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
                    return bt.compareTo(at);
                  });

                if (docs.isEmpty) {
                  return const Center(child: Text('No notifications.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final data = d.data();

                    final title = (data['title'] ?? 'Notification').toString();
                    final body = (data['body'] ?? '').toString();
                    final route = (data['route'] ?? '').toString();
                    final routeArgs = (data['routeArgs'] ?? {}) is Map
                        ? Map<String, dynamic>.from(data['routeArgs'])
                        : <String, dynamic>{};

                    final read = data['read'] == true;
                    DateTime? createdAt;
                    final ts = data['createdAt'];
                    if (ts is Timestamp) createdAt = ts.toDate();

                    return Dismissible(
                      key: ValueKey('notif_${d.id}'),
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => NotificationCenter.I.deleteNotification(d.id),
                      child: Card(
                        child: ListTile(
                          onTap: () => onOpen(context, route.isEmpty ? null : route, routeArgs),
                          title: Row(
                            children: [
                              if (!read) const Icon(Icons.fiber_manual_record, size: 10),
                              if (!read) const SizedBox(width: 6),
                              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (body.isNotEmpty) Text(body),
                              const SizedBox(height: 4),
                              Text(
                                createdAt != null ? createdAt.toLocal().toString() : '—',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            tooltip: read ? 'Read' : 'Mark as read',
                            onPressed: read ? null : () => NotificationCenter.I.markNotificationRead(d.id),
                            icon: Icon(read ? Icons.check_circle : Icons.mark_email_read),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
