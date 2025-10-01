import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

class DebugAdminSetterPage extends StatefulWidget {
  const DebugAdminSetterPage({super.key});

  @override
  State<DebugAdminSetterPage> createState() => _DebugAdminSetterPageState();
}

class _DebugAdminSetterPageState extends State<DebugAdminSetterPage> {
  String? _userId;
  String? _linkedMemberId;
  String? _linkedMemberName;
  bool _isLeader = false;
  List<String> _rolesFromUsers = [];
  List<String> _rolesFromMembers = [];
  List<String> _leadershipMinistriesFromUsers = [];
  List<String> _leadershipMinistriesFromMembers = [];
  bool _loading = false;

  bool get _isAdminNow =>
      _rolesFromUsers.contains('admin') || _rolesFromMembers.contains('admin');

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  Future<void> _fetchUserData() async {
    setState(() => _loading = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('[DEBUG] No user is logged in.');
      setState(() => _loading = false);
      return;
    }

    final userId = user.uid;
    debugPrint('[DEBUG] Fetching user data for UID: $userId');

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final userData = userDoc.data();

    if (userData != null) {
      debugPrint('[DEBUG] User document data: $userData');

      final memberId = userData['memberId'];
      final rolesFromUsers = List<String>.from(userData['roles'] ?? []);
      final leadershipMinistriesFromUsers = List<String>.from(userData['leadershipMinistries'] ?? []);

      debugPrint('[DEBUG] Roles from User Document: $rolesFromUsers');
      debugPrint('[DEBUG] Leadership Ministries from User Document: $leadershipMinistriesFromUsers');

      List<String> rolesFromMembers = [];
      List<String> leadershipMinistriesFromMembers = [];
      String? fullName;
      bool isLeader = false;

      bool updated = false;

      if (memberId != null) {
        debugPrint('[DEBUG] Linked Member ID: $memberId');

        final memberDoc = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
        if (memberDoc.exists) {
          final memberData = memberDoc.data();
          debugPrint('[DEBUG] Member document data: $memberData');

          rolesFromMembers = List<String>.from(memberData?['roles'] ?? []);
          leadershipMinistriesFromMembers = List<String>.from(memberData?['leadershipMinistries'] ?? []);
          fullName = "${memberData?['firstName'] ?? ''} ${memberData?['lastName'] ?? ''}".trim();
          isLeader = leadershipMinistriesFromMembers.isNotEmpty;

          debugPrint('[DEBUG] Roles from Member Document: $rolesFromMembers');
          debugPrint('[DEBUG] Leadership Ministries from Member Document: $leadershipMinistriesFromMembers');

          // Merge roles and leadershipMinistries (users doc stays the truth source we can write)
          final mergedRoles = {...rolesFromUsers, ...rolesFromMembers}.toList();
          final mergedLeadershipMinistries = {...leadershipMinistriesFromUsers, ...leadershipMinistriesFromMembers}.toList();

          debugPrint('[DEBUG] Merged Roles: $mergedRoles');
          debugPrint('[DEBUG] Merged Leadership Ministries: $mergedLeadershipMinistries');

          if (mergedRoles.length != rolesFromUsers.length ||
              mergedLeadershipMinistries.length != leadershipMinistriesFromUsers.length) {
            debugPrint('[DEBUG] Changes detected, updating user document.');
            await FirebaseFirestore.instance.collection('users').doc(userId).set({
              'roles': mergedRoles,
              'leadershipMinistries': mergedLeadershipMinistries,
            }, SetOptions(merge: true));

            updated = true;
          } else {
            debugPrint('[DEBUG] No changes detected, skipping Firestore update.');
          }
        } else {
          debugPrint('[DEBUG] Member document does not exist.');
        }
      } else {
        debugPrint('[DEBUG] No member linked to user.');
      }

      setState(() {
        _userId = userId;
        _linkedMemberId = memberId;
        _rolesFromUsers = rolesFromUsers;
        _rolesFromMembers = rolesFromMembers;
        _leadershipMinistriesFromUsers = leadershipMinistriesFromUsers;
        _leadershipMinistriesFromMembers = leadershipMinistriesFromMembers;
        _linkedMemberName = (fullName == null || fullName.isEmpty) ? null : fullName;
        _isLeader = isLeader || leadershipMinistriesFromUsers.isNotEmpty;
        _loading = false;
      });

      if (updated && mounted) {
        debugPrint('[DEBUG] Showing Snackbar: Roles and Leadership Ministries updated.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Roles and Leadership Ministries updated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // ⬅️ NEW: After we load everything, auto-sync leader role/status into users doc
      // (and optionally members doc via a Cloud Function).
      await _syncLeaderRole(); // ⬅️ NEW
    } else {
      debugPrint('[DEBUG] User document does not exist for UID: $userId');
      setState(() => _loading = false);
    }
  }

  // ⬅️ NEW: Discover leadership ministries from ministries/* where leaderIds contains the current uid
  Future<Set<String>> _discoverLeadershipFromMinistriesCollection(String uid) async {
    final qs = await FirebaseFirestore.instance
        .collection('ministries')
        .where('leaderIds', arrayContains: uid)
        .get();

    final names = <String>{};
    for (final d in qs.docs) {
      final data = d.data();
      final name = (data['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  // ⬅️ NEW: Ensure users/{uid} reflects true leader status; optionally mirror to members/{id} via CF
  Future<void> _syncLeaderRole() async {
    if (_userId == null) return;

    try {
      // Gather from all sources we have
      final userMin = _leadershipMinistriesFromUsers.toSet();
      final memberMin = _leadershipMinistriesFromMembers.toSet();
      final discovered = await _discoverLeadershipFromMinistriesCollection(_userId!);

      final unified = <String>{...userMin, ...memberMin, ...discovered};

      debugPrint('[SYNC] Unified leadership ministries for user $_userId: $unified');

      if (unified.isEmpty) {
        // If user doesn’t lead anything, you may optionally remove 'leader' from users.roles.
        // Leaving as-is to avoid accidental demotion noise.
        return;
      }

      // 1) Ensure users/{uid}.roles contains 'leader' and leadershipMinistries is up-to-date
      await FirebaseFirestore.instance.collection('users').doc(_userId).set({
        'roles': FieldValue.arrayUnion(['leader']),
        'leadershipMinistries': unified.toList(),
      }, SetOptions(merge: true));

      // Update local view
      setState(() {
        if (!_rolesFromUsers.contains('leader')) _rolesFromUsers = [..._rolesFromUsers, 'leader'];
        _leadershipMinistriesFromUsers = unified.toList();
        _isLeader = true;
      });

      // 2) (Optional) Mirror 'leader' into members/{memberId}.roles via a callable with admin privileges
      //    This is necessary because client rules do NOT allow users to update members.roles directly.
      if (_linkedMemberId != null) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'ensureMemberLeaderRole', // ⬅️ implement this CF (see below)
            options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
          );
          await callable.call(<String, dynamic>{
            'memberId': _linkedMemberId,
          });
          debugPrint('[SYNC] ensureMemberLeaderRole called for memberId=$_linkedMemberId');
        } on FirebaseFunctionsException catch (e) {
          debugPrint('[SYNC] ensureMemberLeaderRole failed: ${e.code} ${e.message}');
        } catch (e) {
          debugPrint('[SYNC] ensureMemberLeaderRole error: $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Leader role synced')),
        );
      }
    } catch (e) {
      debugPrint('[SYNC] Error during sync: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Leader sync failed: $e')),
        );
      }
    }
  }

  Future<void> _setAdminRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first.')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'promoteMeToAdmin',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
      );
      await callable.call(<String, dynamic>{});

      await _fetchUserData(); // refresh local view

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Promoted to Admin')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Promote failed: ${e.code} ${e.message ?? ''}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Promote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeAdminRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final memberId = userDoc.data()?['memberId'];

    await FirebaseFirestore.instance.collection('users').doc(userId).update({
      'roles': FieldValue.arrayRemove(['admin']),
    });

    if (memberId != null) {
      await FirebaseFirestore.instance.collection('members').doc(memberId).update({
        'roles': FieldValue.arrayRemove(['admin']),
      });
    }

    await _fetchUserData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("✅ Admin role removed")),
    );
  }

  Future<void> _linkUserToMember() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userEmail = user.email;
    if (userEmail == null) return;

    final memberQuery = await FirebaseFirestore.instance
        .collection('members')
        .where('email', isEqualTo: userEmail)
        .limit(1)
        .get();

    if (memberQuery.docs.isNotEmpty) {
      final memberDoc = memberQuery.docs.first;
      final memberId = memberDoc.id;
      final memberData = memberDoc.data();
      final fullName = "${memberData['firstName'] ?? ''} ${memberData['lastName'] ?? ''}".trim();
      final leadershipMinistries = List<String>.from(memberData['leadershipMinistries'] ?? []);
      final isLeader = leadershipMinistries.isNotEmpty;

      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'memberId': memberId,
      });

      setState(() {
        _linkedMemberId = memberId;
        _linkedMemberName = fullName.isEmpty ? 'Unnamed Member' : fullName;
        _isLeader = isLeader;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("✅ User linked to member: $_linkedMemberName")),
      );

      await _fetchUserData();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ No member found with this email")),
      );
    }
  }

  Widget _buildQuickLinkButton(BuildContext context, IconData icon, String label, String route) {
    return Column(
      children: [
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, route),
          child: CircleAvatar(
            radius: 26,
            backgroundColor: Colors.deepPurple,
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Admin Setter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchUserData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text("🛠️ Debug Info", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
            const SizedBox(height: 20),
            Text("👤 User ID: ${_userId ?? 'Not logged in'}"),
            Text("🆔 Linked Member ID: ${_linkedMemberId ?? 'Not linked'}"),
            if (_linkedMemberName != null) ...[
              const SizedBox(height: 8),
              Text("📛 Member Name: $_linkedMemberName"),
              Text(_isLeader ? "⭐ Leader" : "👤 Regular Member"),
            ],
            const Divider(height: 30),

            const Text("🔐 User Roles", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_rolesFromUsers.isEmpty ? 'No roles' : _rolesFromUsers.join(', ')),

            const SizedBox(height: 10),
            const Text("🏆 User Leadership Ministries", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_leadershipMinistriesFromUsers.isEmpty ? 'None' : _leadershipMinistriesFromUsers.join(', ')),

            const Divider(height: 30),

            const Text("🔐 Member Roles", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_rolesFromMembers.isEmpty ? 'No roles' : _rolesFromMembers.join(', ')),

            const SizedBox(height: 10),
            const Text("🏆 Member Leadership Ministries", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_leadershipMinistriesFromMembers.isEmpty ? 'None' : _leadershipMinistriesFromMembers.join(', ')),

            const SizedBox(height: 20),

            // ⬅️ NEW manual sync button
            ElevatedButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text("Sync Leader Role"),
              onPressed: _syncLeaderRole,
            ),

            const SizedBox(height: 30),
            ElevatedButton.icon(
              icon: const Icon(Icons.security),
              label: const Text("Promote Me to Admin"),
              onPressed: _setAdminRole,
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text("Remove Admin Role"),
              onPressed: _removeAdminRole,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.link),
              label: const Text("Link Me to Member by Email"),
              onPressed: _linkUserToMember,
            ),
            const SizedBox(height: 20),

            const Divider(),
            _buildQuickLinkButton(context, Icons.group, "Ministries", "/view-ministry"),
          ],
        ),
      ),
    );
  }
}
