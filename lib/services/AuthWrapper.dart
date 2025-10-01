import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Pages
import '../pages/home_dashboard_page.dart';
import '../pages/admin_dashboard_page.dart';
import '../pages/login_page.dart';

class AuthWrapper extends StatelessWidget {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  AuthWrapper({super.key});

  Future<Widget> _getInitialPage() async {
    final user = _auth.currentUser;

    if (user == null) {
      return LoginPage();
    }

    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists) {
        final roles = List<String>.from(doc.data()?['roles'] ?? []);
        if (roles.contains('dog')) {
          return const AdminDashboardPage();
        } else {
          return const HomeDashboardPage();
        }
      } else {
        await _auth.signOut();
        return LoginPage();
      }
    } catch (e) {
      await _auth.signOut();
      return LoginPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _getInitialPage(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        } else if (snapshot.hasError) {
          return const Scaffold(
            body: Center(child: Text('Something went wrong. Please try again.')),
          );
        } else {
          return snapshot.data!;
        }
      },
    );
  }
}
