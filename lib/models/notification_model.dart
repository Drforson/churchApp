enum AppNotificationType { ministryPost, joinRequest }

class AppNotification {
  final String id;              // stable id per source item
  final AppNotificationType type;
  final String title;
  final String subtitle;
  final DateTime time;
  final String? ministryId;     // for posts deep-link
  final String? ministryName;   // display/help
  final String? joinRequestId;  // for join-request deep-link

  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.time,
    this.ministryId,
    this.ministryName,
    this.joinRequestId,
  });
}
