import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
  FirebaseFunctions.instanceFor(region: 'europe-west2');

  User? get currentUser => _auth.currentUser;

  /// --------- PRIVATE HELPERS ---------

  /// Call backend ensureUserDoc callable.
  /// Server:
  ///  - creates users/{uid} if missing
  ///  - normalises email
  ///  - recomputes role & claims from existing data
  Future<void> _callEnsureUserDoc() async {
    final callable = _functions.httpsCallable('ensureUserDoc');
    await callable.call();
  }

  /// Server-side: compute highest role, safely link to member (if unique) + sync claims.
  Future<String?> _syncRoleFromMemberOnLogin() async {
    final callable = _functions.httpsCallable('syncUserRoleFromMemberOnLogin');
    final res = await callable.call();
    final data = res.data;
    if (data is Map && data['role'] is String) {
      return data['role'] as String;
    }
    return null;
  }

  /// Convenience: full post-auth bootstrap:
  /// 1) ensure users/{uid} exists
  /// 2) sync role + member link
  /// 3) refresh ID token so custom claims are up to date
  Future<void> _bootstrapAfterAuth(User user) async {
    // Best-effort: we don't crash the whole flow if one step fails,
    // but we *do* rethrow auth/network exceptions out of signIn/signUp.
    await _callEnsureUserDoc();
    await _syncRoleFromMemberOnLogin();
    await user.getIdToken(true);
  }

  /// --------- PUBLIC AUTH METHODS ---------

  /// Login → ensure user doc, server sync role, refresh claims.
  Future<UserCredential> signIn(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    final user = cred.user;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'Sign in failed, no user returned.',
      );
    }

    await _bootstrapAfterAuth(user);
    return cred;
  }

  /// Signup → ensure user doc, server sync role, refresh claims.
  Future<UserCredential> signUp(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    final user = cred.user;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'Sign up failed, no user returned.',
      );
    }

    await _bootstrapAfterAuth(user);
    return cred;
  }

  /// Force refresh of server role + claims later (e.g. after admin changes).
  Future<String?> refreshServerRoleAndClaims() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final role = await _syncRoleFromMemberOnLogin();
    await user.getIdToken(true);
    return role;
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  /// --------- MEMBER LINKING / PROFILE ---------

  /// Explicitly associate this auth user with a member (by email),
  /// then sync role & claims.
  ///
  /// NOTE: for security, we enforce `uid == currentUser?.uid`.
  /// Also stamps `members.userUid = uid` so future auto-link is O(1).
  Future<void> associateMemberWithUser(String uid, String email) async {
    final current = _auth.currentUser;
    if (current == null || current.uid != uid) {
      throw FirebaseAuthException(
        code: 'unauthorised-link',
        message: 'You can only link the currently signed-in user.',
      );
    }

    final emailLc = email.trim().toLowerCase();
    final now = FieldValue.serverTimestamp();

    final memberSnapshot = await _firestore
        .collection('members')
        .where('email', isEqualTo: emailLc)
        .limit(1)
        .get();

    if (memberSnapshot.docs.isNotEmpty) {
      final memberDoc = memberSnapshot.docs.first;
      final memberId = memberDoc.id;

      // Link user → member
      await _firestore.collection('users').doc(uid).set(
        {
          'email': emailLc,
          'memberId': memberId,
          'linkedAt': now,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );

      // Stamp ownership on member → user
      await _firestore.collection('members').doc(memberId).set(
        {
          'userUid': uid,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );
    } else {
      // Keep user email in sync even if no member found (UI can handle "no match")
      await _firestore.collection('users').doc(uid).set(
        {
          'email': emailLc,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );
    }

    await _syncRoleFromMemberOnLogin();
    await _auth.currentUser?.getIdToken(true);
  }

  /// Create member profile, link it to the auth user, then sync role & claims.
  ///
  /// IMPORTANT:
  /// - Uses the *currently signed-in* user as source of truth for uid/email.
  /// - Enforces email verification before creating the member profile.
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
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) {
      throw FirebaseAuthException(
        code: 'unauthorised',
        message: 'No signed-in user found or UID mismatch.',
      );
    }

    await user.reload();
    final isVerified = user.emailVerified;
    if (!isVerified) {
      throw FirebaseAuthException(
        code: 'email-not-verified',
        message: 'Please verify your email before completing registration.',
      );
    }

    final now = FieldValue.serverTimestamp();
    final emailLc = (user.email ?? email).trim().toLowerCase();

    // Create member
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
      'roles': <String>[],
      'isPastor': false,
      'userUid': uid, // 🔑 explicit ownership link
      'createdAt': now,
      'updatedAt': now,
    });

    // Link user → member
    await _firestore.collection('users').doc(uid).set(
      {
        'email': emailLc,
        'memberId': memberRef.id,
        'linkedAt': now,
        'updatedAt': now,
      },
      SetOptions(merge: true),
    );

    await _syncRoleFromMemberOnLogin();
    await _auth.currentUser?.getIdToken(true);
  }

  /// Utility: check if a phone number is already used by a member.
  Future<bool> checkPhoneNumberExists(String phoneNumber) async {
    final result = await _firestore
        .collection('members')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .limit(1)
        .get();
    return result.docs.isNotEmpty;
  }
}
