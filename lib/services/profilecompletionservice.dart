import 'package:cloud_firestore/cloud_firestore.dart';

class ProfileCompletionService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<double> calculateCompletion(String memberId) async {
    final memberDoc = await _db.collection('members').doc(memberId).get();
    if (!memberDoc.exists) {
      throw Exception('Member not found');
    }

    final data = memberDoc.data()!;
    int totalFields = 7; // Total number of fields we check

    int completedFields = 0;

    if ((data['firstName'] ?? '').toString().isNotEmpty) completedFields++;
    if ((data['lastName'] ?? '').toString().isNotEmpty) completedFields++;
    if ((data['email'] ?? '').toString().isNotEmpty) completedFields++;
    if ((data['phoneNumber'] ?? '').toString().isNotEmpty) completedFields++;
    if ((data['address'] ?? '').toString().isNotEmpty) completedFields++;
    if (data['dob'] != null) completedFields++;
    if ((data['ministries'] as List<dynamic>? ?? []).isNotEmpty) completedFields++;

    // Future: if you add profile picture, you can add more points.

    return completedFields / totalFields; // value between 0 and 1
  }
}
