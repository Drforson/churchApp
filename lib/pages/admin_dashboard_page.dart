import 'dart:async';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  bool _isAdmin = false;
  bool _isLeader = false;
  bool _isPastor = false; // NEW: gate for “My Follow-Up”
  Set<String> _leadershipMinistries = {};
  String? _uid;
  String? _displayName; // NEW: show real user name

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _primeRole();
  }

  /// Pull roles + best-effort name from users + members
  Future<void> _primeRole() async {
    final uid = _uid;
    if (uid == null) return;

    final u = await _db.collection('users').doc(uid).get();
    final data = u.data() ?? {};
    final roles = List<String>.from(data['roles'] ?? const []);
    final memberId = data['memberId'] as String?;
    final fromUsers = List<String>.from(data['leadershipMinistries'] ?? const []);

    // Try to get name from users first
    String? name = (data['displayName'] ?? data['name'])?.toString();
    bool isPastor = roles.contains('pastor');

    var isAdmin = roles.contains('admin');
    var isLeader = roles.contains('leader');
    final mins = <String>{...fromUsers};

    Map<String, dynamic> md = {};
    if (memberId != null) {
      final m = await _db.collection('members').doc(memberId).get();
      md = m.data() ?? {};
      final fromMembers = List<String>.from(md['leadershipMinistries'] ?? const []);
      mins.addAll(fromMembers);
      if (!isAdmin && fromMembers.isNotEmpty) isLeader = true;

      // If users doc had no name, fallback to members fields
      name ??= (md['fullName'] ??
          ([md['firstName'], md['lastName']]
              .where((e) => (e ?? '').toString().trim().isNotEmpty)
              .join(' ')
              .trim()))
          .toString();

      // Check pastoral role on members too
      final memberRoles = List<String>.from(md['roles'] ?? const []);
      isPastor = isPastor || memberRoles.contains('pastor') || (md['isPastor'] == true);
    }

    // Final safe fallback to auth displayName/email local-part if still null
    name ??= _auth.currentUser?.displayName ??
        _auth.currentUser?.email?.split('@').first ??
        'Member';

    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _isLeader = isLeader;
      _isPastor = isPastor;
      _leadershipMinistries = mins;
      _displayName = name;
    });
  }

  Future<void> _logout(BuildContext context) async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _isAdmin || _isLeader;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_isAdmin ? 'Admin Dashboard' : _isLeader ? 'Leader Dashboard' : 'Dashboard'),
        backgroundColor: Colors.teal.shade600, // ⬅️ a touch darker than the bg
        foregroundColor: const Color(0xFF111827), // dark text/icons for contrast
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark, // dark status-bar icons
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _primeRole,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
          NotificationBell(),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF7F8FA), Color(0xFFEEF1F5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => _primeRole(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _HeaderCard(
                  isAdmin: _isAdmin,
                  isLeader: _isLeader,
                  ministries: _leadershipMinistries,
                  displayName: _displayName ?? 'Member', // NEW
                ),
                const SizedBox(height: 14),
                const _StatsGrid(),
                const SizedBox(height: 18),
                _NoticeBoardCarousel(),
                const SizedBox(height: 18),
                const _SectionTitle('Quick Actions'),
                const SizedBox(height: 8),
                _ActionsGrid(
                  canManage: canManage,
                  isPastor: _isPastor, // NEW: to show “My Follow-Up”
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* -------------------- Header -------------------- */

class _HeaderCard extends StatelessWidget {
  final bool isAdmin;
  final bool isLeader;
  final Set<String> ministries;
  final String displayName; // NEW

  const _HeaderCard({
    required this.isAdmin,
    required this.isLeader,
    required this.ministries,
    required this.displayName,
  });

  @override
  Widget build(BuildContext context) {
    final roleLabel = isAdmin ? 'Admin' : isLeader ? 'Leader' : 'Member';

    // Keep your existing ministry/role context (unchanged logic),
    // but now the main title is the user's name.
    final subtitle = isAdmin
        ? 'Role: Admin • Manage church-wide content and settings'
        : isLeader
        ? (ministries.isEmpty
        ? 'Role: Leader'
        : 'Role: Leader • Leader of: ${ministries.take(3).join(", ")}${ministries.length > 3 ? " +" : ""}')
        : 'Role: Member • Welcome back';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFE8ECF3),
            child: Icon(isAdmin ? Icons.admin_panel_settings : Icons.verified, color: Colors.indigo, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // NEW: Welcome with actual name instead of role
                Text(
                  'Welcome, $displayName',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF4B5563)),
                ),
              ],
            ),
          ),
          // Optional: small role chip on the right
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8ECF3),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              roleLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2937),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* -------------------- Stats (RESPONSIVE, OVERFLOW-SAFE) -------------------- */

class _StatsGrid extends StatelessWidget {
  const _StatsGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 720
            ? 4
            : constraints.maxWidth >= 520
            ? 3
            : 3;

        // Taller tiles to avoid vertical overflow
        final ratio = crossAxisCount >= 4 ? 1.0 : 0.65;

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: ratio,
          children: const [
            _StatTile(label: 'Members', icon: Icons.groups, query: _StatQuery.members),
            _StatTile(label: 'Ministries', icon: Icons.church, query: _StatQuery.ministries),
            _StatTile(label: 'Upcoming', icon: Icons.event_available, query: _StatQuery.upcomingEvents),
          ],
        );
      },
    );
  }
}

enum _StatQuery { members, ministries, upcomingEvents }

class _StatTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final _StatQuery query;

  const _StatTile({required this.label, required this.icon, required this.query});

  Stream<int> _stream() {
    final db = FirebaseFirestore.instance;
    switch (query) {
      case _StatQuery.members:
        return db.collection('members').limit(1000).snapshots().map((s) => s.size);
      case _StatQuery.ministries:
        return db.collection('ministries').limit(500).snapshots().map((s) => s.size);
      case _StatQuery.upcomingEvents:
        return db
            .collection('events')
            .where('startDate', isGreaterThanOrEqualTo: Timestamp.now())
            .limit(500)
            .snapshots()
            .map((s) => s.size);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _stream(),
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 5))],
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            children: [
              // Top icon
              SizedBox(
                height: 36,
                child: Center(
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFFE8ECF3),
                    child: Icon(icon, color: Colors.indigo),
                  ),
                ),
              ),
              // Count (expands to fill, auto-fits)
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$count',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: const Color(0xFF1F2937),
                      ),
                    ),
                  ),
                ),
              ),
              // Label (single line, ellipsis)
              SizedBox(
                height: 22,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF4B5563),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/* -------------------- Noticeboard Carousel -------------------- */

class _NoticeBoardCarousel extends StatefulWidget {
  @override
  State<_NoticeBoardCarousel> createState() => _NoticeBoardCarouselState();
}

class _NoticeBoardCarouselState extends State<_NoticeBoardCarousel> {
  final _controller = PageController(viewportFraction: 0.92);
  int _page = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_controller.hasClients) return;
      _page = (_page + 1);
      _controller.animateToPage(
        _page,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final now = Timestamp.now();

    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection('events')
          .where('startDate', isGreaterThanOrEqualTo: now)
          .orderBy('startDate')
          .limit(5)
          .snapshots(),
      builder: (context, eventsSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: db.collection('announcements').orderBy('createdAt', descending: true).limit(5).snapshots(),
          builder: (context, annSnap) {
            final events = eventsSnap.data?.docs ?? const [];
            final anns = annSnap.data?.docs ?? const [];
            final combined = [...events, ...anns];

            if (combined.isEmpty) return _EmptyNotice();

            return Container(
              height: 172,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white70),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 6))],
              ),
              child: PageView.builder(
                controller: _controller,
                itemCount: combined.length,
                itemBuilder: (context, i) {
                  final doc = combined[i];
                  final data = doc.data() as Map<String, dynamic>;
                  final isEvent = data.containsKey('startDate');
                  return _NoticeCard(isEvent: isEvent, data: data);
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white70),
      ),
      child: Text(
        'No upcoming events or announcements',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF4B5563)),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final bool isEvent;
  final Map<String, dynamic> data;

  const _NoticeCard({required this.isEvent, required this.data});

  @override
  Widget build(BuildContext context) {
    final title = (data['title'] ?? 'Untitled').toString();

    String subtitle;
    if (isEvent) {
      final dt = (data['startDate'] as Timestamp?)?.toDate();
      if (dt == null) {
        subtitle = 'Unknown date';
      } else {
        final date = DateFormat.yMMMd().format(dt);
        final time = TimeOfDay.fromDateTime(dt).format(context);
        subtitle = '$date • $time';
      }
    } else {
      subtitle = (data['body'] ?? 'No content').toString();
    }

    final icon = isEvent ? Icons.event : Icons.campaign;
    final color = isEvent ? Colors.indigo : Colors.orange;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/* -------------------- Actions -------------------- */

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _ActionsGrid extends StatelessWidget {
  final bool canManage;
  final bool isPastor; // NEW
  const _ActionsGrid({required this.canManage, required this.isPastor});

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      _ActionItem('Profile', Icons.person, '/profile'), // NEW
      _ActionItem('Upload Sermons & Events', Icons.upload, '/admin-upload'),
      _ActionItem('Register Member/Visitor', Icons.how_to_reg, '/register-member'),
      _ActionItem('View Members', Icons.group, '/view-members'),
      _ActionItem('Manage Ministries', Icons.group_work, '/view-ministry'),
      _ActionItem('Post Announcements', Icons.campaign, '/post-announcements'),
      _ActionItem('Events', Icons.event, '/events'),
      _ActionItem('Upload Database', Icons.table_view, '/uploadExcel'),
      _ActionItem('Attendance Check-In', Icons.check_circle_outline, '/attendance'),
      _ActionItem('My Requests', Icons.volunteer_activism_rounded, '/forms'),
      _ActionItem('Sunday Follow-Up', Icons.person_off, '/follow-up'),
      // NEW: Only for pastors
      if (isPastor) _ActionItem('My Follow-Up', Icons.assignment_ind, '/my-follow-up'),
      _ActionItem('Admin/Leader Tools', Icons.admin_panel_settings, '/testadmin', requireManage: true),
    ].where((i) => !i.requireManage || canManage).toList();

    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 720 ? 4 : 2;
        // Taller cards + flexible content
        final aspect = columns == 4 ? 1.25 : 0.88;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: aspect,
          ),
          itemBuilder: (context, i) => _ActionCard(item: items[i]),
        );
      },
    );
  }
}

class _ActionItem {
  final String label;
  final IconData icon;
  final String route;
  final bool requireManage;

  _ActionItem(this.label, this.icon, this.route, {this.requireManage = false});
}

class _ActionCard extends StatelessWidget {
  final _ActionItem item;
  const _ActionCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, item.route),
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 6))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              SizedBox(
                height: 42,
                child: Center(
                  child: CircleAvatar(
                    radius: 21,
                    backgroundColor: const Color(0xFFE8ECF3),
                    child: Icon(item.icon, color: Colors.indigo),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      item.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1F2937),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
