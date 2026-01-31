
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class DebugAdminSetterPage extends StatefulWidget {
  const DebugAdminSetterPage({super.key});

  @override
  State<DebugAdminSetterPage> createState() => _DebugAdminSetterPageState();
}

class _DebugAdminSetterPageState extends State<DebugAdminSetterPage>
    with SingleTickerProviderStateMixin {
  // Cloud Functions (correct region)
  final FirebaseFunctions _functions =
  FirebaseFunctions.instanceFor(region: 'europe-west2');

  // Roles we expose in the Grant tab (server will validate anyway)
  // ✅ Includes 'admin' so a pastor can grant admin
  static const Set<String> _allowedRoles = {'pastor', 'usher', 'media', 'admin'};

  // ======= Identity / state =======
  String? _userId;
  String? _linkedMemberId;
  String? _linkedMemberName;

  // Single-role (preferred) + legacy fallbacks for display only
  String? _userSingleRole; // users.role
  List<String> _rolesFromUsers = []; // legacy display only
  List<String> _rolesFromMembers = []; // source-of-truth for multi-role
  List<String> _leadershipMinistriesFromUsers = []; // display only
  List<String> _leadershipMinistriesFromMembers = []; // display only
  bool _isLeader = false;

  bool _loading = false;

  bool _hasRoleLocal(String role) {
    final r = role.toLowerCase();
    final single = (_userSingleRole ?? '').toLowerCase() == r;
    final fromUsers = _rolesFromUsers.map((e) => e.toLowerCase()).contains(r);
    final fromMembers =
    _rolesFromMembers.map((e) => e.toLowerCase()).contains(r);
    return single || fromUsers || fromMembers;
  }

  // Admin & Pastor checks
  bool get _isAdminNow => _hasRoleLocal('admin');
  bool get _isPastorNow => _hasRoleLocal('pastor');

  // 🔑 New unified gate for role management
  bool get _canManageRoles => _isAdminNow || _isPastorNow;

  // ======= Tabs =======
  late final TabController _tabController;

  // Pastor/Admin search
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String _searchError = '';
  List<_MemberResult> _searchResults = [];

  // ======= Grant Permissions tab =======
  final TextEditingController _grantSearchCtrl = TextEditingController();
  String _grantQuery = '';
  final Set<String> _selectedMemberIds = <String>{};
  final Set<String> _rolesToGrant = <String>{}; // {pastor, usher, media, admin}
  final Set<String> _rolesToRemove = <String>{};

  bool get _canGrant =>
      _selectedMemberIds.isNotEmpty && _rolesToGrant.isNotEmpty && _canManageRoles;

  // NOTE: we dynamically enable “Remove” if either remove-chips are chosen OR
  // roles exist on selected members (computed at build time).
  bool get _canRemove =>
      _selectedMemberIds.isNotEmpty && _canManageRoles && _rolesToRemove.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchUserData();

    // Debounce for pastor/admin search
    _searchCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        _runSearch(_searchCtrl.text.trim());
      });
    });

    // Grant search text
    _grantSearchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _grantQuery = _grantSearchCtrl.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _grantSearchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ======= Data load (READ-ONLY; no writes here) =======
  Future<void> _fetchUserData() async {
    setState(() => _loading = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final userId = user.uid;
      final userSnap =
      await FirebaseFirestore.instance.collection('users').doc(userId).get();
      final u = userSnap.data() ?? {};

      final memberId = (u['memberId'] as String?)?.trim();
      final singleRole = (u['role'] is String) ? (u['role'] as String) : null;

      final rolesFromUsers = (u['roles'] is List)
          ? List<String>.from((u['roles'] as List).map((e) => e.toString()))
          : <String>[];

      final lmFromUsers = (u['leadershipMinistries'] is List)
          ? List<String>.from(
          (u['leadershipMinistries'] as List).map((e) => e.toString()))
          : <String>[];

      List<String> rolesFromMembers = [];
      List<String> lmFromMembers = [];
      String? fullName;
      bool isLeader = false;

      if (memberId != null && memberId.isNotEmpty) {
        final mSnap = await FirebaseFirestore.instance
            .collection('members')
            .doc(memberId)
            .get();
        if (mSnap.exists) {
          final m = mSnap.data() ?? {};
          rolesFromMembers = (m['roles'] is List)
              ? List<String>.from(
              (m['roles'] as List).map((e) => e.toString()))
              : <String>[];
          lmFromMembers = (m['leadershipMinistries'] is List)
              ? List<String>.from((m['leadershipMinistries'] as List)
              .map((e) => e.toString()))
              : <String>[];
          final first = (m['firstName'] ?? '').toString();
          final last = (m['lastName'] ?? '').toString();
          fullName = (('$first $last').trim().isEmpty
              ? (m['fullName'] ?? '').toString()
              : ('$first $last').trim())
              .trim();
          isLeader = lmFromMembers.isNotEmpty;
        }
      }

      if (!mounted) return;
      setState(() {
        _userId = userId;
        _linkedMemberId = (memberId == null || memberId.isEmpty) ? null : memberId;
        _linkedMemberName =
        (fullName == null || fullName.isEmpty) ? null : fullName;

        _userSingleRole = (singleRole ?? '').trim();
        _rolesFromUsers = rolesFromUsers.map((e) => e.toLowerCase()).toSet().toList();
        _rolesFromMembers =
            rolesFromMembers.map((e) => e.toLowerCase()).toSet().toList();
        _leadershipMinistriesFromUsers = lmFromUsers;
        _leadershipMinistriesFromMembers = lmFromMembers;
        _isLeader = isLeader || lmFromUsers.isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // READ-ONLY helper
  Future<Set<String>> _discoverLeadershipFromMinistriesCollection(
      String uid) async {
    final qs = await FirebaseFirestore.instance
        .collection('ministries')
        .where('leaderIds', arrayContains: uid) // legacy/alt field
        .get();

    final names = <String>{};
    for (final d in qs.docs) {
      final data = d.data();
      final name = (data['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) names.add(name);
    }
    return names;
  }

  // Server-driven: ensures member (and linked user via Functions) becomes a leader.
  Future<void> _syncLeaderRole() async {
    if (_linkedMemberId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link your user to a member first.')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      // Optional discovery for display
      if (_userId != null) {
        await _discoverLeadershipFromMinistriesCollection(_userId!);
      }

      final callable = _functions.httpsCallable(
        'ensureMemberLeaderRole',
        options:  HttpsCallableOptions(timeout: Duration(seconds: 20)),
      );
      await callable.call(<String, dynamic>{'memberId': _linkedMemberId});

      // Refresh ID token so claims (if any) are up-to-date
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      await _fetchUserData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Leader role ensured on member.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Leader sync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
      final callable = _functions.httpsCallable(
        'promoteMeToAdmin',
        options:  HttpsCallableOptions(timeout: Duration(seconds: 20)),
      );
      await callable.call(<String, dynamic>{});
      await user.getIdToken(true);
      await _fetchUserData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Promoted to Admin')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Promote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeAdminRole() async {
    if (_linkedMemberId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link your user to a member first.')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final callable = _functions.httpsCallable(
        'setMemberRoles',
        options:  HttpsCallableOptions(timeout: Duration(seconds: 20)),
      );
      await callable.call(<String, dynamic>{
        'memberIds': [_linkedMemberId],
        'rolesAdd': <String>[],
        'rolesRemove': ['admin'],
      });

      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      await _fetchUserData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Admin role removed")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Remove failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _linkUserToMember() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userEmail = user.email?.trim().toLowerCase();
    if (userEmail == null || userEmail.isEmpty) return;

    final memberQuery = await FirebaseFirestore.instance
        .collection('members')
        .where('email', isEqualTo: userEmail)
        .limit(1)
        .get();

    if (memberQuery.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ No member found with this email")),
      );
      return;
    }

    final memberDoc = memberQuery.docs.first;
    final memberId = memberDoc.id;
    final memberData = memberDoc.data();
    final fullName =
    "${memberData['firstName'] ?? ''} ${memberData['lastName'] ?? ''}".trim();

    // Link allowed keys only
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
      {
        'memberId': memberId,
        'linkedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    if (!mounted) return;
    setState(() {
      _linkedMemberId = memberId;
      _linkedMemberName = fullName.isEmpty ? 'Unnamed Member' : fullName;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("✅ User linked to member: $_linkedMemberName")),
    );

    await _fetchUserData();
  }

  // ===== Pastor/Admin search =====
  Future<void> _runSearch(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _searchError = '';
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchError = '';
      _searchResults = [];
    });

    try {
      final col = FirebaseFirestore.instance.collection('members');
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];

      if (query.contains('@')) {
        final qs = await col.where('email', isEqualTo: query.toLowerCase()).limit(10).get();
        docs = qs.docs;
      } else {
        final qLower = query.toLowerCase();
        try {
          final qs = await col
              .orderBy('fullNameLower')
              .startAt([qLower])
              .endAt(['$qLower\uf8ff'])
              .limit(20)
              .get();
          docs = qs.docs;
        } catch (_) {
          final qs = await col.limit(50).get();
          docs = qs.docs.where((d) {
            final data = d.data();
            final first = (data['firstName'] ?? '').toString().toLowerCase();
            final last = (data['lastName'] ?? '').toString().toLowerCase();
            final full = ('$first $last').trim();
            return first.contains(qLower) ||
                last.contains(qLower) ||
                full.contains(qLower);
          }).toList();
        }
      }

      final results = docs.map((d) {
        final data = d.data();
        final roles = (data['roles'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().toLowerCase())
            .toSet()
            .toList();
        final first = (data['firstName'] ?? '').toString();
        final last = (data['lastName'] ?? '').toString();
        final full = (('$first $last').trim().isEmpty
            ? (data['fullName'] ?? '').toString()
            : ('$first $last').trim())
            .trim();
        final email = (data['email'] ?? '').toString();
        final id = d.id;
        return _MemberResult(
          id: id,
          name: full.isNotEmpty ? full : 'Unnamed Member',
          email: email,
          roles: roles,
        );
      }).toList();

      setState(() {
        _searchResults = results;
      });
    } catch (e) {
      setState(() => _searchError = 'Search failed: $e');
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _setPastorRoleOnMember(
      _MemberResult m, {
        required bool makePastor,
      }) async {
    if (!_canManageRoles) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins or pastors can modify roles.')),
      );
      return;
    }

    try {
      // Prefer Cloud Function that syncs user+member & claims
      final callable = _functions.httpsCallable(
        'setMemberPastorRole',
        options: HttpsCallableOptions(timeout: Duration(seconds: 20)),
      );
      await callable.call(<String, dynamic>{
        'memberId': m.id,
        'makePastor': makePastor,
      });

      // Optimistic UI
      setState(() {
        final idx = _searchResults.indexWhere((r) => r.id == m.id);
        if (idx != -1) {
          final cur = _searchResults[idx];
          final next = cur.roles.map((e) => e.toLowerCase()).toSet();
          makePastor ? next.add('pastor') : next.remove('pastor');
          _searchResults[idx] = cur.copyWith(roles: next.toList());
        }
      });

      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(makePastor
                ? '✅ Pastor role granted'
                : '✅ Pastor role removed'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Cloud Function failed: ${e.code} ${e.message ?? ''}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Update failed: $e')),
        );
      }
    }
  }

  /// ✅ Admin OR Pastor grant/removal on a specific member
  Future<void> _setAdminRoleOnMember(
      _MemberResult m, {
        required bool makeAdmin,
      }) async {
    if (!_canManageRoles) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins or pastors can modify roles.')),
      );
      return;
    }

    try {
      final callable = _functions.httpsCallable(
        'setMemberRoles',
        options: HttpsCallableOptions(timeout: Duration(seconds: 20)),
      );
      await callable.call(<String, dynamic>{
        'memberIds': [m.id],
        'rolesAdd': makeAdmin ? ['admin'] : <String>[],
        'rolesRemove': makeAdmin ? <String>[] : ['admin'],
      });

      // Optimistic UI
      setState(() {
        final idx = _searchResults.indexWhere((r) => r.id == m.id);
        if (idx != -1) {
          final cur = _searchResults[idx];
          final next = cur.roles.map((e) => e.toLowerCase()).toSet();
          makeAdmin ? next.add('admin') : next.remove('admin');
          _searchResults[idx] = cur.copyWith(roles: next.toList());
        }
      });

      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(makeAdmin
                ? '✅ Admin role granted'
                : '✅ Admin role removed'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Cloud Function failed: ${e.code} ${e.message ?? ''}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Update failed: $e')),
        );
      }
    }
  }

  // ===== NEW: GRANT PERMISSIONS (bulk) =====
  Future<void> _bulkApplyRoles({
    required Iterable<String> memberIds,
    required Iterable<String> add,
    required Iterable<String> remove,
  }) async {
    if (!_canManageRoles) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins or pastors can modify roles.')),
      );
      return;
    }
    if (memberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one member.')),
      );
      return;
    }

    // Sanitize & avoid self-contradiction
    final addSet =
    add.map((e) => e.toLowerCase()).where(_allowedRoles.contains).toSet();
    final removeSet =
    remove.map((e) => e.toLowerCase()).where(_allowedRoles.contains).toSet();
    final both = {...addSet}..retainAll(removeSet);
    addSet.removeAll(both);
    removeSet.removeAll(both);

    try {
      final callable = _functions.httpsCallable(
        'setMemberRoles',
        options: HttpsCallableOptions(timeout: Duration(seconds: 30)),
      );
      await callable.call(<String, dynamic>{
        'memberIds': memberIds.toList(),
        'rolesAdd': addSet.toList(),
        'rolesRemove': removeSet.toList(),
      });

      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      // Optimistic badge update in visible list
      setState(() {
        for (final id in memberIds) {
          final i = _searchResults.indexWhere((r) => r.id == id);
          if (i != -1) {
            final cur = _searchResults[i];
            final next = cur.roles.map((e) => e.toLowerCase()).toSet();
            next.addAll(addSet);
            for (final r in removeSet) {
              next.remove(r);
            }
            _searchResults[i] = cur.copyWith(roles: next.toList());
          }
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '✅ Updated ${memberIds.length} member(s): +[${addSet.join(', ')}] -[${removeSet.join(', ')}]'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('❌ Cloud Function failed: ${e.code} ${e.message ?? ''}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Update failed: $e')),
      );
    }
  }

  void _toggleRoleToGrant(String role) {
    setState(() {
      final r = role.toLowerCase();
      if (_rolesToGrant.contains(r)) {
        _rolesToGrant.remove(r);
      } else {
        _rolesToGrant.add(r);
        _rolesToRemove.remove(r); // mutually exclusive
      }
    });
  }

  void _toggleRoleToRemove(String role) {
    setState(() {
      final r = role.toLowerCase();
      if (_rolesToRemove.contains(r)) {
        _rolesToRemove.remove(r);
      } else {
        _rolesToRemove.add(r);
        _rolesToGrant.remove(r); // mutually exclusive
      }
    });
  }

  // Compact action buttons row
  Widget _grantRemoveButtons({
    required bool canRemoveNow,
    required Set<String> inferredRolesToRemove,
  }) {
    final smallPad = const EdgeInsets.symmetric(horizontal: 10, vertical: 8);
    final smallMin = const Size(0, 32);

    final rolesToRemoveFinal =
    _rolesToRemove.isNotEmpty ? _rolesToRemove : inferredRolesToRemove;

    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ElevatedButton.icon(
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Grant selected'),
          onPressed: _canGrant
              ? () => _bulkApplyRoles(
            memberIds: _selectedMemberIds,
            add: _rolesToGrant,
            remove: const [],
          )
              : null,
          style: ElevatedButton.styleFrom(
            padding: smallPad,
            minimumSize: smallMin,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.remove_circle_outline, size: 18),
          label: const Text('Remove selected'),
          onPressed: canRemoveNow
              ? () => _bulkApplyRoles(
            memberIds: _selectedMemberIds,
            add: const [],
            remove: rolesToRemoveFinal,
          )
              : null,
          style: OutlinedButton.styleFrom(
            padding: smallPad,
            minimumSize: smallMin,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        Text(
          '${_selectedMemberIds.length} selected',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  // Build a chip toggle row for roles
  Widget _roleChips() {
    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Color? color,
    }) {
      return FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        label: Text(label),
        selectedColor: (color ?? Colors.indigo).withOpacity(0.2),
        checkmarkColor: Colors.indigo,
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        Text('Grant:', style: Theme.of(context).textTheme.labelLarge),
        chip(
          label: 'Pastor',
          selected: _rolesToGrant.contains('pastor'),
          onTap: () => _toggleRoleToGrant('pastor'),
        ),
        chip(
          label: 'Usher',
          selected: _rolesToGrant.contains('usher'),
          onTap: () => _toggleRoleToGrant('usher'),
        ),
        chip(
          label: 'Media',
          selected: _rolesToGrant.contains('media'),
          onTap: () => _toggleRoleToGrant('media'),
        ),
        chip(
          label: 'Admin',
          selected: _rolesToGrant.contains('admin'),
          onTap: () => _toggleRoleToGrant('admin'),
          color: Colors.redAccent,
        ),
      ],
    );
  }

  // ===== Grant Permissions Tab =====
  Widget _buildGrantPermissionsTab() {
    return FutureBuilder<QuerySnapshot>(
      future: FirebaseFirestore.instance.collection('members').get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting || _loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final members = snapshot.data?.docs
            .map((e) => {
          ...((e.data() as Map<String, dynamic>?) ?? const {}),
          '_id': e.id,
        })
            .toList() ??
            [];

        // Filter by search text (first+last or fullName)
        List<Map<String, dynamic>> filtered = members.where((m) {
          final first = (m['firstName'] ?? '').toString();
          final last = (m['lastName'] ?? '').toString();
          final fullName = (m['fullName'] ?? '').toString();
          final name =
          (('$first $last').trim().isEmpty ? fullName : '$first $last')
              .toLowerCase();
          if (_grantQuery.isEmpty) return true;
          return name.contains(_grantQuery);
        }).toList();

        // Derive ministries from members
        final Set<String> allMinistries = {};
        for (var m in filtered) {
          final mins = m['ministries'];
          if (mins is List) {
            allMinistries.addAll(mins.map((e) => e.toString()));
          }
        }
        final sortedMinistries = allMinistries.toList()..sort();

        // Members with no ministry
        final List<Map<String, dynamic>> noMinistry = filtered.where((m) {
          final mins = m['ministries'];
          return mins is! List || mins.isEmpty;
        }).toList();

        // Roles present on selected members (only the allowed ones)
        final Set<String> rolesPresentOnSelection = <String>{};
        for (final m in filtered) {
          final id = (m['_id'] ?? '').toString();
          if (!_selectedMemberIds.contains(id)) continue;
          final rolesList =
          (m['roles'] is List) ? (m['roles'] as List) : const [];
          for (final r in rolesList) {
            final rl = r.toString().toLowerCase();
            if (_allowedRoles.contains(rl)) rolesPresentOnSelection.add(rl);
          }
        }

        final bool canRemoveNow = _selectedMemberIds.isNotEmpty &&
            (_rolesToRemove.isNotEmpty || rolesPresentOnSelection.isNotEmpty) &&
            _canManageRoles;

        // Pretty colors
        final colors = [
          Colors.teal.shade200,
          Colors.orange.shade200,
          Colors.indigo.shade200,
          Colors.brown.shade200,
          Colors.green.shade200,
          Colors.blueGrey.shade200,
          Colors.pink.shade200,
        ];

        int colorIndex = 0;

        return Column(
          children: [
            // Controls row (search + chips + buttons)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Search
                  TextField(
                    controller: _grantSearchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search members by name...',
                      border: const OutlineInputBorder(),
                      suffixIcon: _grantQuery.isNotEmpty
                          ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _grantSearchCtrl.clear(),
                      )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _roleChips(),
                  const SizedBox(height: 10),
                  _grantRemoveButtons(
                    canRemoveNow: canRemoveNow,
                    inferredRolesToRemove: rolesPresentOnSelection,
                  ),
                  if (!_canManageRoles) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'You are not an Admin or Pastor. Role changes are disabled.',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ]
                ],
              ),
            ),

            const Divider(height: 0),

            // List
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // No-ministry group
                  if (noMinistry.isNotEmpty)
                    _ministryCard(
                      title: 'No Ministry',
                      color: colors[colorIndex++ % colors.length],
                      members: noMinistry,
                    ),

                  // Each ministry group
                  ...sortedMinistries.map((ministryName) {
                    final groupMembers = filtered.where((m) {
                      final mins = m['ministries'];
                      return mins is List &&
                          mins
                              .map((e) => e.toString())
                              .contains(ministryName);
                    }).toList();

                    if (groupMembers.isEmpty) {
                      return const SizedBox.shrink();
                    }

                    final color = colors[colorIndex++ % colors.length];
                    return _ministryCard(
                      title: ministryName,
                      color: color,
                      members: groupMembers,
                    );
                  }),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // A grouped card with checkboxes
  Widget _ministryCard({
    required String title,
    required Color color,
    required List<Map<String, dynamic>> members,
  }) {
    final allIds = members.map((m) => m['_id'] as String).toSet();
    final allSelected =
        allIds.isNotEmpty && allIds.difference(_selectedMemberIds).isEmpty;

    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: false,
        title: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title  •  ${members.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              // Group select toggle
              Checkbox(
                value: allSelected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedMemberIds.addAll(allIds);
                    } else {
                      _selectedMemberIds.removeAll(allIds);
                    }
                  });
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        children: members.map((m) {
          final id = (m['_id'] ?? '').toString();
          final first = (m['firstName'] ?? '').toString();
          final last = (m['lastName'] ?? '').toString();
          final fullName = (m['fullName'] ?? '').toString();
          final name =
          (('$first $last').trim().isEmpty ? fullName : '$first $last')
              .trim();
          final rolesList =
          (m['roles'] is List) ? (m['roles'] as List) : const [];
          final rset = rolesList.map((e) => e.toString().toLowerCase()).toSet();
          final hasPastor = rset.contains('pastor');
          final hasUsher = rset.contains('usher');
          final hasMedia = rset.contains('media');
          final hasAdmin = rset.contains('admin');

          return ListTile(
            leading: Checkbox(
              value: _selectedMemberIds.contains(id),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedMemberIds.add(id);
                  } else {
                    _selectedMemberIds.remove(id);
                  }
                });
              },
            ),
            title: Text(name.isEmpty ? 'Unnamed member' : name),
            subtitle: Wrap(
              spacing: 6,
              children: [
                if (hasPastor) const Chip(label: Text('Pastor')),
                if (hasUsher) const Chip(label: Text('Usher')),
                if (hasMedia) const Chip(label: Text('Media')),
                if (hasAdmin)
                  const Chip(
                    label: Text('Admin'),
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final singleRoleDisplay =
    (_userSingleRole ?? '').isEmpty ? 'none' : _userSingleRole;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Admin Setter'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.settings), text: 'Debug & Roles'),
            Tab(icon: Icon(Icons.verified_user), text: 'Grant Permissions'),
          ],
        ),
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
          : TabBarView(
        controller: _tabController,
        children: [
          // ======== Tab 1: Debug & single-role aware controls ========
          Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(
              children: [
                const Text("🛠️ Debug Info",
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 20)),
                const SizedBox(height: 20),
                Text("👤 User ID: ${_userId ?? 'Not logged in'}"),
                Text("🆔 Linked Member ID: ${_linkedMemberId ?? 'Not linked'}"),
                if (_linkedMemberName != null) ...[
                  const SizedBox(height: 8),
                  Text("📛 Member Name: $_linkedMemberName"),
                  Text(_isLeader ? "⭐ Leader" : "👤 Regular Member"),
                ],
                const Divider(height: 30),

                const Text("🔐 Single Role (users.role)",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(singleRoleDisplay!.toLowerCase()),

                const SizedBox(height: 12),
                const Text("🔐 User Roles (legacy, display-only)",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_rolesFromUsers.isEmpty
                    ? 'No roles'
                    : _rolesFromUsers.join(', ')),

                const SizedBox(height: 10),
                const Text("🏆 User Leadership Ministries (display-only)",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_leadershipMinistriesFromUsers.isEmpty
                    ? 'None'
                    : _leadershipMinistriesFromUsers.join(', ')),

                const Divider(height: 30),

                const Text("🔐 Member Roles (source of truth)",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_rolesFromMembers.isEmpty
                    ? 'No roles'
                    : _rolesFromMembers.join(', ')),

                const SizedBox(height: 10),
                const Text("🏆 Member Leadership Ministries",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_leadershipMinistriesFromMembers.isEmpty
                    ? 'None'
                    : _leadershipMinistriesFromMembers.join(', ')),

                const SizedBox(height: 20),

                ElevatedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text("Ensure Leader Role (server)"),
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
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text("Link Me to Member by Email"),
                  onPressed: _linkUserToMember,
                ),

                const SizedBox(height: 30),
                const Divider(height: 30),
                const Text(
                  "👤 Role Manager (Admin/Pastor)",
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search by member name or email...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching
                        ? const Padding(
                      padding: EdgeInsets.all(10.0),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2),
                      ),
                    )
                        : (_searchCtrl.text.isNotEmpty
                        ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchResults = []);
                      },
                    )
                        : null),
                    border: const OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _runSearch(v.trim()),
                ),
                if (_searchError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_searchError,
                      style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 12),
                if (_searchResults.isEmpty &&
                    _searchCtrl.text.isNotEmpty &&
                    !_searching)
                  const Text('No members found.'),
                ..._searchResults.map((m) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        (m.name.isNotEmpty ? m.name[0] : '?')
                            .toUpperCase(),
                      ),
                    ),
                    title: Text(m.name),
                    subtitle:
                    Text(m.email.isEmpty ? 'No email' : m.email),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        if (m.roles
                            .map((e) => e.toLowerCase())
                            .contains('pastor'))
                          OutlinedButton.icon(
                            icon: const Icon(Icons.remove),
                            label: const Text('Remove Pastor'),
                            onPressed: _canManageRoles
                                ? () => _setPastorRoleOnMember(
                              m,
                              makePastor: false,
                            )
                                : null,
                          )
                        else
                          ElevatedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Grant Pastor'),
                            onPressed: _canManageRoles
                                ? () => _setPastorRoleOnMember(
                              m,
                              makePastor: true,
                            )
                                : null,
                          ),
                        // ✅ Admin controls per member (Admin OR Pastor)
                        if (m.roles
                            .map((e) => e.toLowerCase())
                            .contains('admin'))
                          OutlinedButton.icon(
                            icon: const Icon(Icons.shield),
                            label: const Text('Remove Admin'),
                            onPressed: _canManageRoles
                                ? () => _setAdminRoleOnMember(
                              m,
                              makeAdmin: false,
                            )
                                : null,
                          )
                        else
                          ElevatedButton.icon(
                            icon: const Icon(Icons.shield),
                            label: const Text('Grant Admin'),
                            onPressed: _canManageRoles
                                ? () => _setAdminRoleOnMember(
                              m,
                              makeAdmin: true,
                            )
                                : null,
                          ),
                      ],
                    ),
                  ),
                )),
              ],
            ),
          ),

          // ======== Tab 2: Grant Permissions ========
          _buildGrantPermissionsTab(),
        ],
      ),
    );
  }
}

// Helper model for role search
class _MemberResult {
  final String id;
  final String name;
  final String email;
  final List<String> roles;

  _MemberResult({
    required this.id,
    required this.name,
    required this.email,
    required this.roles,
  });

  _MemberResult copyWith({
    String? id,
    String? name,
    String? email,
    List<String>? roles,
  }) {
    return _MemberResult(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      roles: roles ?? this.roles,
    );
  }
}
