import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
  FirebaseFunctions.instanceFor(region: 'europe-west2');

  /// Server-side: compute highest role from member and push to users/{uid}.role + claims.
  Future<String?> _syncRoleFromMemberOnLogin() async {
    final res = await _functions.httpsCallable('syncUserRoleFromMemberOnLogin').call();
    final data = res.data;
    if (data is Map && data['role'] is String) return data['role'] as String;
    return null;
  }

  /// Ensure users/{uid} exists.
  /// CREATE: allowed to set role: 'member'
  /// UPDATE: only write fields allowed by rules: email, createdAt, updatedAt (and memberId/linkedAt elsewhere).
  Future<void> _ensureUserDoc({
    required String uid,
    required String email,
  }) async {
    final ref = _firestore.collection('users').doc(uid);
    final snap = await ref.get();
    final now = FieldValue.serverTimestamp();
    final emailLc = email.trim().toLowerCase();

    if (!snap.exists) {
      // CREATE is allowed (rules allow create when uid matches)
      await ref.set({
        'email': emailLc,
        'role': 'member',          // ✅ ok on CREATE
        'memberId': null,
        'createdAt': now,
        'updatedAt': now,
      }, SetOptions(merge: true));
    } else {
      // UPDATE: ❌ do NOT touch 'role' or 'leadershipMinistries'
      await ref.set({
        'email': emailLc,
        'updatedAt': now,
      }, SetOptions(merge: true));
    }
  }

  /// Login → ensure user doc, then server sync role, then refresh token.
  Future<UserCredential> signIn(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    await _ensureUserDoc(uid: cred.user!.uid, email: email);
    await _syncRoleFromMemberOnLogin();
    await cred.user!.getIdToken(true); // make sure claims/role are fresh
    return cred;
  }

  /// Signup → ensure user doc, then server sync role, then refresh token.
  Future<UserCredential> signUp(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    await _ensureUserDoc(uid: cred.user!.uid, email: email);
    await _syncRoleFromMemberOnLogin();
    await cred.user!.getIdToken(true);
    return cred;
  }

  /// Link to existing member by email (allowed keys only), then sync role.
  Future<void> associateMemberWithUser(String uid, String email) async {
    final emailLc = email.trim().toLowerCase();
    final now = FieldValue.serverTimestamp();

    final memberSnapshot = await _firestore
        .collection('members')
        .where('email', isEqualTo: emailLc)
        .limit(1)
        .get();

    if (memberSnapshot.docs.isNotEmpty) {
      final memberId = memberSnapshot.docs.first.id;
      await _firestore.collection('users').doc(uid).set({
        'email': emailLc,
        'memberId': memberId,      // ✅ allowed
        'linkedAt': now,           // ✅ allowed
        'updatedAt': now,
      }, SetOptions(merge: true));
    } else {
      await _firestore.collection('users').doc(uid).set({
        'email': emailLc,
        'updatedAt': now,
      }, SetOptions(merge: true));
    }

    await _syncRoleFromMemberOnLogin();
    await _auth.currentUser?.getIdToken(true);
  }

  /// Create member profile (multi-role lives on MEMBER), link, then sync role.
  Future<void> completeMemberProfile({
    required String uid,
    required String email,
    required String firstName,
    required String lastName,
    required String phoneNumber,
    required String gender,
    required DateTime dateOfBirth,
    String? address,
  }) async {
    await _auth.currentUser?.reload();
    final isVerified = _auth.currentUser?.emailVerified ?? false;
    if (!isVerified) {
      throw FirebaseAuthException(
        code: 'email-not-verified',
        message: 'Please verify your email before completing registration.',
      );
    }

    final now = FieldValue.serverTimestamp();
    final emailLc = email.trim().toLowerCase();

    final memberRef = await _firestore.collection('members').add({
      'firstName': firstName,
      'lastName': lastName,
      'fullName': '$firstName $lastName',
      'email': emailLc,
      'phoneNumber': phoneNumber,
      'gender': gender,
      'address': address ?? '',
      'dateOfBirth': Timestamp.fromDate(dateOfBirth),
      'ministries': <String>[],
      'leadershipMinistries': <String>[],
      'roles': <String>[],     // multi-role array stays on MEMBER
      'isPastor': false,
      'createdAt': now,
      'updatedAt': now,
    });

    await _firestore.collection('users').doc(uid).set({
      'memberId': memberRef.id, // ✅ allowed
      'linkedAt': now,          // ✅ allowed
      'updatedAt': now,
    }, SetOptions(merge: true));

    await _syncRoleFromMemberOnLogin();
    await _auth.currentUser?.getIdToken(true);
  }

  Future<bool> checkPhoneNumberExists(String phoneNumber) async {
    final result = await _firestore
        .collection('members')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .limit(1)
        .get();
    return result.docs.isNotEmpty;
  }
}
