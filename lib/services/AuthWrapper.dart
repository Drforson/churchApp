import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Pages
import '../pages/home_dashboard_page.dart';
import '../pages/admin_dashboard_page.dart';
import '../pages/login_page.dart';

class AuthWrapper extends StatelessWidget {
  AuthWrapper({super.key});

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    // React to auth state
    return StreamBuilder<User?>(
      stream: _auth.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final user = authSnap.data;
        if (user == null) {
          return LoginPage();
        }

        // Signed in → listen to users/{uid}
        final docRef = _firestore.collection('users').doc(user.uid);
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: docRef.snapshots(),
          builder: (context, userDocSnap) {
            if (userDocSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            // If the user doc isn't there yet, show home while AuthService finishes first-run setup
            if (!userDocSnap.hasData || !userDocSnap.data!.exists) {
              return const HomeDashboardPage();
            }

            final data = userDocSnap.data!.data() ?? const <String, dynamic>{};

            // Prefer new single-role field; fallback to legacy roles[]
            String role = _readRole(data);

            switch (role) {
              case 'admin':
              case 'pastor':
                return const AdminDashboardPage();
              default:
                return const HomeDashboardPage();
            }
          },
        );
      },
    );
  }

  // --- helpers ---

  String _readRole(Map<String, dynamic> data) {
    final single = (data['role'] is String)
        ? (data['role'] as String).toLowerCase().trim()
        : null;
    if (single != null && single.isNotEmpty) return single;

    // Legacy fallback: roles array
    final legacy = (data['roles'] is List)
        ? List<String>.from((data['roles'] as List).map((e) => (e ?? '').toString()))
        : const <String>[];
    return _legacyHighestRole(legacy);
  }

  String _legacyHighestRole(List<String> roles) {
    final set = roles.map((e) => e.toLowerCase().trim()).toSet();
    if (set.contains('admin')) return 'admin';
    if (set.contains('pastor')) return 'pastor';
    if (set.contains('leader')) return 'leader';
    if (set.contains('usher'))  return 'usher';
    return 'member';
  }
}
