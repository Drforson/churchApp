// lib/widgets/notificationbell_widget.dart
import 'package:church_management_app/pages/ministries_details_page.dart';

import 'package:church_management_app/services/notification_center.dart';
import 'package:flutter/material.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NotificationState>(
      stream: NotificationCenter.instance.stream,
      builder: (context, snap) {
        final unread = snap.data?.unread ?? 0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: 'Notifications',
              onPressed: () => _openSheet(context),
              icon: const Icon(Icons.notifications_none),
            ),
            if (unread > 0)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _NotificationsSheet(),
    );
  }
}

class _NotificationsSheet extends StatelessWidget {
  const _NotificationsSheet();

  @override
  Widget build(BuildContext context) {
    // Mark all channels seen when opening
    NotificationCenter.instance.markChannelSeen(NotificationChannel.feeds);
    NotificationCenter.instance.markChannelSeen(NotificationChannel.joinreq);
    NotificationCenter.instance.markChannelSeen(NotificationChannel.leader_joinreq);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
          const Divider(height: 20),
          Expanded(
            child: StreamBuilder<NotificationState>(
              stream: NotificationCenter.instance.stream,
              builder: (context, snap) {
                final items = snap.data?.items ?? const [];
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'Nothing new yet',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final n = items[i];
                    final icon = _iconFor(n.channel);
                    final color = _colorFor(n.channel);

                    return Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withOpacity(0.12),
                          child: Icon(icon, color: color),
                        ),
                        title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => _navigateFromNotification(context, n),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(NotificationChannel c) {
    switch (c) {
      case NotificationChannel.feeds:
        return Icons.campaign;
      case NotificationChannel.joinreq:
        return Icons.how_to_reg;
      case NotificationChannel.leader_joinreq:
        return Icons.group_add;
    }
  }

  Color _colorFor(NotificationChannel c) {
    switch (c) {
      case NotificationChannel.feeds:
        return Colors.indigo;
      case NotificationChannel.joinreq:
        return Colors.teal;
      case NotificationChannel.leader_joinreq:
        return Colors.amber.shade800;
    }
  }

  void _navigateFromNotification(BuildContext context, AppNotification n) {
    if (n.channel == NotificationChannel.feeds) {
      final mid = n.ministryId;
      final mname = n.ministryName ?? 'Ministry';
      if (mid != null && mid.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MinistryDetailsPage(ministryId: mid, ministryName: mname),
          ),
        );
      } else {
        Navigator.pushNamed(context, '/view-ministry');
      }
    } else if (n.channel == NotificationChannel.joinreq) {
      Navigator.pushNamed(context, '/view-ministry'); // your "My Join Requests" tab lives there
    } else if (n.channel == NotificationChannel.leader_joinreq) {
      Navigator.pushNamed(context, '/view-ministry'); // leaders review requests there
    }
  }
}
