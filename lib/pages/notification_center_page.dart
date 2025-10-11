// lib/pages/notification_center_page.dart
import 'dart:async';

import 'package:church_management_app/pages/pastor_ministry_approvals_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/notification_center.dart';
import 'ministries_details_page.dart';

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  bool _isPastor = false;

  // Cache to avoid repeated lookups for the same moderator uid
  final Map<String, String> _nameCache = {};

  @override
  void initState() {
    super.initState();
    _bootstrapRoles();
  }

  Future<void> _bootstrapRoles() async {
    final user = _auth.currentUser;
    if (user == null) return;
    _uid = user.uid;

    try {
      final uSnap = await _db.collection('users').doc(user.uid).get();
      final u = uSnap.data() ?? {};
      bool isPastor = (u['isPastor'] == true);
      final uRoles = (u['roles'] is List)
          ? List<String>.from((u['roles'] as List).map((e) => e.toString().toLowerCase()))
          : const <String>[];
      if (uRoles.contains('pastor')) isPastor = true;

      final memberId = (u['memberId'] ?? '').toString();
      if (!isPastor && memberId.isNotEmpty) {
        final mSnap = await _db.collection('members').doc(memberId).get();
        final m = mSnap.data() ?? {};
        if (m['isPastor'] == true) isPastor = true;
        final mRoles = (m['roles'] is List)
            ? List<String>.from((m['roles'] as List).map((e) => e.toString().toLowerCase()))
            : const <String>[];
        if (mRoles.contains('pastor')) isPastor = true;
      }

      if (!mounted) return;
      setState(() => _isPastor = isPastor);
    } catch (_) {
      // ignore: leave pastor=false if we can't resolve
    }
  }

  // ------------------- Name resolution for moderator -------------------

  Future<String?> _resolveDisplayNameForUid(String uid) async {
    if (_nameCache.containsKey(uid)) return _nameCache[uid];

    try {
      // First try users.displayName
      final uSnap = await _db.collection('users').doc(uid).get();
      final u = uSnap.data() ?? {};
      final displayName = (u['displayName'] ?? '').toString().trim();
      if (displayName.isNotEmpty) {
        _nameCache[uid] = displayName;
        return displayName;
      }

      // Else try users.memberId -> members.first/last
      final memberId = (u['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        final mSnap = await _db.collection('members').doc(memberId).get();
        final m = mSnap.data() ?? {};
        final first = (m['firstName'] ?? '').toString().trim();
        final last = (m['lastName'] ?? '').toString().trim();
        final name = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        if (name.isNotEmpty) {
          _nameCache[uid] = name;
          return name;
        }
      }
    } catch (_) {
      // swallow and return null
    }
    return null;
  }

  // ------------------- Helpers -------------------

  String _fmtWhen(DateTime? dt) {
    if (dt == null) return '—';
    return DateFormat('dd MMM, HH:mm').format(dt.toLocal());
  }

  String _titleFor(InboxEvent ev) {
    final type = (ev.type ?? '').toLowerCase();
    switch (type) {
      case 'join_request':
        return 'New join request';
      case 'join_request.approved':
      case 'join_request_result':
        {
          final r = (ev.raw['result'] ?? '').toString().toLowerCase();
          return r == 'approved'
              ? 'Your join request was approved'
              : 'Your join request was declined';
        }
      case 'join_request_cancelled':
        return 'Join request cancelled';
      case 'ministry_request_created':
        return 'New ministry creation request';
      case 'ministry_request_result':
        {
          final r = (ev.raw['result'] ?? '').toString().toLowerCase();
          return r == 'approved'
              ? 'Your ministry was approved'
              : 'Your ministry was declined';
        }
      case 'approval_action_processed':
        return 'Approval action processed';
      case 'prayer_request_created':
        return 'New prayer request';
      default:
        return ev.title ?? 'Notification';
    }
  }

  /// Builds the subtitle. For join_request_result we append "by <Name>" if known.
  Widget _subtitleWidget(InboxEvent ev) {
    final name = (ev.raw['ministryName'] ??
        ev.raw['ministryId'] ??
        ev.raw['ministry'] ??
        '')
        .toString();
    final when = _fmtWhen(ev.createdAt);

    final type = (ev.type ?? '').toLowerCase();
    final isDecision = type == 'join_request_result' || type == 'join_request.approved';

    // prefer moderatorName directly in payload if present
    final payloadModeratorName = (ev.raw['moderatorName'] ?? '').toString().trim();
    final moderatorUid = (ev.raw['moderatorUid'] ?? '').toString().trim();

    // Base subtitle: "<Ministry • When>" or just "When"
    final base = name.isEmpty ? when : '$name • $when';

    if (!isDecision) {
      return Text(
        base,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    if (payloadModeratorName.isNotEmpty) {
      // Already provided — no lookup needed
      final action = (ev.raw['result'] ?? '').toString().toLowerCase() == 'approved'
          ? 'approved'
          : 'declined';
      final line = '$base\n$action by $payloadModeratorName';
      return Text(
        line,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }

    if (moderatorUid.isEmpty) {
      // No info available; just base
      return Text(
        base,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    // Resolve name async with caching
    return FutureBuilder<String?>(
      future: _resolveDisplayNameForUid(moderatorUid),
      builder: (context, snap) {
        final resolved = (snap.data ?? '').toString().trim();
        if (resolved.isEmpty) {
          return Text(
            base,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          );
        }
        final action = (ev.raw['result'] ?? '').toString().toLowerCase() == 'approved'
            ? 'approved'
            : 'declined';
        final line = '$base\n$action by $resolved';
        return Text(
          line,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }

  Icon _iconFor(InboxEvent ev) {
    final type = (ev.type ?? '').toLowerCase();
    switch (type) {
      case 'join_request':
        return const Icon(Icons.group_add);
      case 'join_request_result':
      case 'join_request.approved':
        return const Icon(Icons.check_circle);
      case 'join_request_cancelled':
        return const Icon(Icons.undo);
      case 'ministry_request_created':
        return const Icon(Icons.pending_actions);
      case 'ministry_request_result':
        return const Icon(Icons.verified);
      case 'approval_action_processed':
        return const Icon(Icons.task_alt);
      case 'prayer_request_created':
        return const Icon(Icons.volunteer_activism);
      default:
        return const Icon(Icons.notifications);
    }
  }

  Future<void> _openFrom(InboxEvent ev) async {
    final type = (ev.type ?? '').toLowerCase();
    final ministryDocId = (ev.raw['ministryDocId'] ?? '').toString();
    final ministryName =
    (ev.raw['ministryName'] ?? ev.raw['ministryId'] ?? '').toString();

    if (type == 'ministry_request_result') {
      final result = (ev.raw['result'] ?? '').toString().toLowerCase();
      if (result == 'declined' || result == 'rejected') {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Ministry not created'),
            content: const Text(
              'This ministry request was declined.\nThe ministry does not exist.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              )
            ],
          ),
        );
        try {
          await NotificationCenter.I.markRead(ev.id);
        } catch (_) {}
        return;
      }
    }

    bool opened = false;

    if (type == 'join_request' && _isPastor) {
      opened = true;
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
        );
      }
    }

    if (!opened &&
        (type.startsWith('join_request') ||
            type == 'join_request_result' ||
            type == 'ministry_request_result')) {
      if (ministryName.isNotEmpty || ministryDocId.isNotEmpty) {
        opened = true;
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MinistryDetailsPage(
                ministryId: ministryDocId.isNotEmpty ? ministryDocId : 'unknown',
                ministryName:
                ministryName.isNotEmpty ? ministryName : '(Unknown Ministry)',
              ),
            ),
          );
        }
      }
    }

    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification opened.')),
      );
    }

    try {
      await NotificationCenter.I.markRead(ev.id);
    } catch (_) {}
  }

  Widget _tile(InboxEvent ev) {
    final icon = _iconFor(ev);
    final title = _titleFor(ev);

    return Dismissible(
      key: ValueKey('ev_${ev.id}'),
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: Colors.green,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Icon(Icons.done_all, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        try {
          if (direction == DismissDirection.endToStart) {
            await NotificationCenter.I.markRead(ev.id); // swipe left -> read
          } else {
            await NotificationCenter.I.deleteEvent(ev.id); // swipe right -> delete
          }
          return true;
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Action failed: $e')),
            );
          }
          return false;
        }
      },
      child: ListTile(
        leading: Stack(
          alignment: Alignment.topRight,
          children: [
            Padding(padding: const EdgeInsets.only(right: 6, top: 6), child: icon),
            if (!ev.read)
              const Positioned(
                right: 0,
                top: 0,
                child: CircleAvatar(radius: 4, backgroundColor: Colors.redAccent),
              ),
          ],
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: ev.read ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
        subtitle: _subtitleWidget(ev), // <-- shows "approved/declined by <Name>"
        onTap: () => _openFrom(ev),
        trailing: OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open'),
          onPressed: () => _openFrom(ev),
        ),
      ),
    );
  }

  // ------------------- Build -------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              try {
                await NotificationCenter.I.markAllRead();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All notifications marked as read')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to mark all read: $e')),
                  );
                }
              }
            },
            icon: const Icon(Icons.drafts_outlined),
            label: const Text('Mark all read'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<InboxEvent>>(
        stream: NotificationCenter.I.inboxEventsStream(limit: 200),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <InboxEvent>[];
          if (items.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _tile(items[i]),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_none_rounded, size: 48),
            const SizedBox(height: 12),
            Text(
              'You’re all caught up',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'New notifications will appear here.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
