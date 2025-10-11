// lib/widgets/notificationbell_widget.dart
import 'package:flutter/material.dart';
import '../services/notification_center.dart';

/// A bell icon with a live unread counter badge.
/// Source of truth: NotificationCenter.I.unreadCountStream()
/// If not signed in, it shows a plain bell with no badge.
class NotificationBell extends StatelessWidget {
  const NotificationBell({
    super.key,
    this.onTap,
    this.iconSize = 26,
    this.iconColor,
    this.badgeColor,
    this.badgeTextColor = Colors.white,
    this.tooltip = 'Notifications',
  });

  final VoidCallback? onTap;
  final double iconSize;
  final Color? iconColor;
  final Color? badgeColor;
  final Color badgeTextColor;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: NotificationCenter.I.unreadCountStream(),
      builder: (context, snap) {
        final unread = snap.data ?? 0;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: tooltip,
              icon: Icon(
                unread > 0
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                size: iconSize,
                color: iconColor ?? Theme.of(context).iconTheme.color,
              ),
              onPressed: onTap,
            ),

            // Badge
            if (unread > 0)
              Positioned(
                right: 6,
                top: 6,
                child: _Badge(
                  count: unread,
                  background: badgeColor ?? Theme.of(context).colorScheme.error,
                  textColor: badgeTextColor,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Small rounded badge with animated count updates.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.count,
    required this.background,
    required this.textColor,
  });

  final int count;
  final Color background;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    // Cap to "99+"
    final text = count > 99 ? '99+' : '$count';

    // A subtle pop-in animation when the count changes
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1.0),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: child,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              blurRadius: 6,
              offset: Offset(0, 1),
              color: Colors.black26,
            ),
          ],
        ),
        child: Text(
          text,
          style: TextStyle(
            color: textColor,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
