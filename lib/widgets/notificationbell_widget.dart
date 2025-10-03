import 'package:church_management_app/pages/notification_center_page.dart';
import 'package:church_management_app/services/notification_center.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Small, self-contained bell button that listens to NotificationCenter.stream
/// and shows an unread badge. Tapping opens NotificationCenterPage.
/// Long-press → mark all channels as read.
class NotificationBell extends StatelessWidget {
  final double iconSize;
  final EdgeInsets padding;

  const NotificationBell({
    super.key,
    this.iconSize = 24,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NotificationState>(
      stream: NotificationCenter.instance.stream,
      builder: (context, snap) {
        final unread = snap.data?.unread ?? 0;

        return Padding(
          padding: padding,
          child: GestureDetector(
            onLongPress: () async {
              // Mark all channels seen
              await NotificationCenter.instance
                  .markChannelSeen(NotificationChannel.feeds);
              await NotificationCenter.instance
                  .markChannelSeen(NotificationChannel.joinreq);
              await NotificationCenter.instance
                  .markChannelSeen(NotificationChannel.leader_joinreq);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All notifications marked as read')),
                );
              }
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  tooltip: 'Notifications',
                  icon: const Icon(Icons.notifications_outlined),
                  iconSize: iconSize,
                  onPressed: () {
                    final uid = FirebaseAuth.instance.currentUser?.uid;
                    if (uid == null) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => NotificationCenterPage(uid: uid),
                      ),
                    );
                  },
                ),
                if (unread > 0)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: _Badge(count: unread),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;
  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    // Compact "99+" style label
    final text = count > 99 ? '99+' : '$count';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}
