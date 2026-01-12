import 'package:cloud_firestore/cloud_firestore.dart';

/// Centralised profile completion scoring for members.
/// Returns a value between 0.0 and 1.0 using weighted fields.
class ProfileCompletionService {
  final FirebaseFirestore _db;

  // ✅ non-const constructor
  ProfileCompletionService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns a number between 0.0 and 1.0.
  Future<double> calculateCompletion(String memberId) async {
    final snap = await _db.collection('members').doc(memberId).get();
    final data = snap.data();
    if (!snap.exists || data == null) return 0.0;
    return _compute(data);
  }

  /// Stream version for live dashboards / profile pages.
  Stream<double> watchCompletion(String memberId) {
    return _db
        .collection('members')
        .doc(memberId)
        .snapshots()
        .map((snap) => (snap.exists && snap.data() != null)
        ? _compute(snap.data()!)
        : 0.0);
  }

  // Backwards-compat (if other files still use old names)
  Future<double> score(String memberId) => calculateCompletion(memberId);
  Stream<double> watchScore(String memberId) => watchCompletion(memberId);

  // ---------------------------------------------------------------------------
  // Internal computation
  // ---------------------------------------------------------------------------

  double _compute(Map<String, dynamic> m) {
    const Map<String, double> weights = {
      'firstName': 0.10,
      'lastName': 0.10,
      'email': 0.20,
      'phoneNumber': 0.20,
      'gender': 0.05,
      'address': 0.05,
      'dateOfBirth': 0.20,
    };

    double score = 0.0;
    double max = 0.0;

    void check(String field, bool filled) {
      final w = weights[field] ?? 0.0;
      if (w <= 0) return;
      max += w;
      if (filled) score += w;
    }

    check('firstName', _filled(m['firstName']));
    check('lastName', _filled(m['lastName']));
    check('email', _filled(m['email']));
    check('phoneNumber', _filled(m['phoneNumber']));
    check('gender', _filled(m['gender']));
    check('address', _filled(m['address']));
    check('dateOfBirth', m['dateOfBirth'] != null);

    if (max == 0.0) return 0.0;
    return (score / max).clamp(0.0, 1.0);
  }

  bool _filled(dynamic v) {
    if (v == null) return false;
    if (v is String && v.trim().isEmpty) return false;
    return true;
  }
}
