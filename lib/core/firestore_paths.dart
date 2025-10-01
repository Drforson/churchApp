class FP {
  static const String users = 'users';
  static const String members = 'members';
  static const String ministries = 'ministries';
  static const String events = 'events';
  static const String joinRequests = 'join_requests';

  static String user(String uid) => '$users/$uid';
  static String member(String id) => '$members/$id';
  static String ministry(String id) => '$ministries/$id';
  static String event(String id) => '$events/$id';

  // Posts live under a ministry subcollection
 // static String ministry(String id) => 'ministries/$id';
  static String ministryPostsCol(String id) => 'ministries/$id/posts';
  static String ministryPost(String id, String postId) => 'ministries/$id/posts/$postId';
  static String ministryPostDoc(String ministryId, String postId) => 'ministries/$ministryId/posts/$postId';
}