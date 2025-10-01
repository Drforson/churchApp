import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// 🔥 Login user with email and password
  Future<UserCredential> signIn(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  /// 🔥 Sign up user
  Future<UserCredential> signUp(String email, String password) async {
    return await _auth.createUserWithEmailAndPassword(email: email, password: password);
  }

  /// Associate user with member if email exists
  Future<void> associateMemberWithUser(String uid, String email) async {
    final memberSnapshot = await _firestore
        .collection('members')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();

    if (memberSnapshot.docs.isNotEmpty) {
      final memberId = memberSnapshot.docs.first.id;

      await _firestore.collection('users').doc(uid).set({
        'email': email,
        'roles': ['member'],
        'memberId': memberId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      await _firestore.collection('users').doc(uid).set({
        'email': email,
        'roles': ['member'],
        'memberId': null,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// ✅ Complete member profile (with email verification enforced)
  Future<void> completeMemberProfile({
    required String uid,
    required String email,
    required String firstName,
    required String lastName,
    required String phoneNumber,
    required String gender,
    required DateTime dateOfBirth,
  }) async {
    // 🔐 Ensure email is verified before proceeding
    await _auth.currentUser?.reload();
    final isVerified = _auth.currentUser?.emailVerified ?? false;

    if (!isVerified) {
      throw FirebaseAuthException(
        code: 'email-not-verified',
        message: 'Please verify your email before completing registration.',
      );
    }

    final memberRef = await _firestore.collection('members').add({
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'phoneNumber': phoneNumber,
      'gender': gender,
      'dateOfBirth': Timestamp.fromDate(dateOfBirth),
      'ministries': [],
      'leadershipMinistries': [],
      'userRole': 'member',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _firestore.collection('users').doc(uid).update({
      'memberId': memberRef.id,
    });
  }

  /// Check if phone number already exists
  Future<bool> checkPhoneNumberExists(String phoneNumber) async {
    final result = await _firestore
        .collection('members')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .limit(1)
        .get();
    return result.docs.isNotEmpty;
  }
}
