import 'dart:async';

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

  static const Set<String> _userClientAllowedKeys = {
    'email',
    'linkedAt',
    'createdAt',
    'updatedAt',
  };

  User? get currentUser => _auth.currentUser;

  /// --------- PRIVATE HELPERS ---------

  /// Call backend ensureUserDoc callable.
  /// Server:
  ///  - creates users/{uid} if missing
  ///  - normalises email
  ///  - recomputes role & claims from existing data
  Future<void> _callEnsureUserDoc() async {
    final callable = _functions.httpsCallable('ensureUserDoc');
    await callable.call().timeout(const Duration(seconds: 8));
  }

  /// Server-side: compute highest role, safely link to member (if unique) + sync claims.
  Future<String?> _syncRoleFromMemberOnLogin() async {
    final callable = _functions.httpsCallable('syncUserRoleFromMemberOnLogin');
    final res = await callable.call().timeout(const Duration(seconds: 8));
    final data = res.data;
    if (data is Map && data['role'] is String) {
      return data['role'] as String;
    }
    return null;
  }

  Future<T?> _safeStep<T>(String name, Future<T> Function() step) async {
    try {
      return await step();
    } on TimeoutException {
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Convenience: full post-auth bootstrap:
  /// 1) ensure users/{uid} exists
  /// 2) sync role + member link
  /// 3) refresh ID token so custom claims are up to date
  Future<void> _bootstrapAfterAuth(User user) async {
    // Best-effort: we don't crash the whole flow if one step fails,
    // but we *do* rethrow auth/network exceptions out of signIn/signUp.
    await _safeStep('ensureUserDoc', _callEnsureUserDoc);
    await _safeStep('syncRoleFromMemberOnLogin', _syncRoleFromMemberOnLogin);
    await _safeStep('refreshIdToken', () => user.getIdToken(true));
  }

  void _guardUserWriteKeys(Map<String, dynamic> data) {
    for (final key in data.keys) {
      if (!_userClientAllowedKeys.contains(key)) {
        throw FirebaseAuthException(
          code: 'unsafe-user-write',
          message: 'Client write blocked for restricted field: $key',
        );
      }
    }
  }

  /// --------- PUBLIC AUTH METHODS ---------

  /// Login → ensure user doc, server sync role, refresh claims.
  Future<UserCredential> signIn(String email, String password) async {
    late final UserCredential cred;
    try {
      cred = await _auth
          .signInWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw FirebaseAuthException(
        code: 'timeout',
        message: 'Login timed out. Check your network and try again.',
      );
    }

    final user = cred.user;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'Sign in failed, no user returned.',
      );
    }

    unawaited(_bootstrapAfterAuth(user));
    return cred;
  }

  /// Signup → ensure user doc, server sync role, refresh claims.
  Future<UserCredential> signUp(String email, String password) async {
    late final UserCredential cred;
    try {
      cred = await _auth
          .createUserWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw FirebaseAuthException(
        code: 'timeout',
        message: 'Sign up timed out. Check your network and try again.',
      );
    }

    final user = cred.user;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'Sign up failed, no user returned.',
      );
    }

    unawaited(_bootstrapAfterAuth(user));
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

    // Keep user email in sync; link is resolved server-side (unique email or userUid)
    final payload = <String, dynamic>{
      'email': emailLc,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    _guardUserWriteKeys(payload);
    await _firestore.collection('users').doc(uid).set(payload, SetOptions(merge: true));

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
    String? addressPlaceId,
    double? addressLat,
    double? addressLng,
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

    final members = _firestore.collection('members');
    DocumentReference<Map<String, dynamic>>? targetRef;
    bool exists = false;

    // Prefer existing member by userUid.
    final byUid = await members.where('userUid', isEqualTo: uid).limit(1).get();
    if (byUid.docs.isNotEmpty) {
      targetRef = byUid.docs.first.reference;
      exists = true;
    }

    // Fallback: unique email match (avoid duplicates).
    if (targetRef == null) {
      final byEmail = await members.where('email', isEqualTo: emailLc).limit(2).get();
      if (byEmail.docs.length == 1) {
        targetRef = byEmail.docs.first.reference;
        exists = true;
      } else if (byEmail.docs.length > 1) {
        throw FirebaseAuthException(
          code: 'duplicate-member',
          message: 'Multiple member records exist for this email. Please contact admin.',
        );
      }
    }

    // If still nothing, create a deterministic doc by uid (idempotent for retries).
    if (targetRef == null) {
      targetRef = members.doc(uid);
      final snap = await targetRef.get();
      exists = snap.exists;
    }

    final payload = <String, dynamic>{
      'firstName': firstName,
      'lastName': lastName,
      'fullName': '$firstName $lastName'.trim(),
      'email': emailLc,
      'phoneNumber': phoneNumber,
      'gender': gender,
      'address': address ?? '',
      if (addressPlaceId != null) 'addressPlaceId': addressPlaceId,
      if (addressLat != null) 'addressLat': addressLat,
      if (addressLng != null) 'addressLng': addressLng,
      'dateOfBirth': Timestamp.fromDate(dateOfBirth),
      'updatedAt': now,
    };

    if (exists) {
      // Update only safe fields (rules allow self update on these)
      await targetRef.update(payload);
    } else {
      await targetRef.set({
        ...payload,
        'ministries': <String>[],
        'leadershipMinistries': <String>[],
        'roles': <String>[],
        'isPastor': false,
        'userUid': uid, // explicit ownership link (allowed on create)
        'createdAt': now,
      });
    }

    await _syncRoleFromMemberOnLogin();
    await _auth.currentUser?.getIdToken(true);
  }

  /// Utility: check if a phone number is already used by a member.
  Future<bool> checkPhoneNumberExists(String phoneNumber, {String? excludeMemberId}) async {
    final callable = _functions.httpsCallable('checkPhoneNumberExists');
    final res = await callable.call(<String, dynamic>{
      'phoneNumber': phoneNumber,
      if (excludeMemberId != null && excludeMemberId.trim().isNotEmpty)
        'excludeMemberId': excludeMemberId.trim(),
    });
    final data = res.data;
    if (data is Map && data['exists'] == true) return true;
    return false;
  }
}
