import 'package:cloud_functions/cloud_functions.dart';

class MemberSearchService {
  MemberSearchService._();

  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west2');

  static Future<List<Map<String, dynamic>>> searchMembers(
    String query, {
    int limit = 50,
    String? ministryName,
    String gender = 'all',
    String visitor = 'all',
  }) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final callable = _functions.httpsCallable('searchMembers');
    final res = await callable.call(<String, dynamic>{
      'query': q,
      'limit': limit,
      if (ministryName != null && ministryName.isNotEmpty) 'ministryName': ministryName,
      'gender': gender,
      'visitor': visitor,
    });
    final data = res.data;
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }
}
