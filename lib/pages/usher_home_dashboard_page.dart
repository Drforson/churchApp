import 'dart:async';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

class UsherHomeDashboardPage extends StatefulWidget {
  const UsherHomeDashboardPage({super.key});

  @override
  State<UsherHomeDashboardPage> createState() => _UsherHomeDashboardPageState();
}

class _UsherHomeDashboardPageState extends State<UsherHomeDashboardPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  String? _uid;
  String _displayName = 'Usher';

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _primeName();
  }

  Future<void> _primeName() async {
    final uid = _uid;
    if (uid == null) return;

    // Best-effort display of member’s real name
    String? name;
    final u = await _db.collection('users').doc(uid).get();
    final data = u.data() ?? {};
    name = (data['displayName'] ?? data['name'])?.toString();

    final memberId = data['memberId'] as String?;
    if ((name == null || name.trim().isEmpty) && memberId != null) {
      final m = await _db.collection('members').doc(memberId).get();
      final md = m.data() ?? {};
      name = (md['fullName'] ??
          [md['firstName'], md['lastName']]
              .where((e) => (e ?? '').toString().trim().isNotEmpty)
              .join(' '))
          .toString()
          .trim();
    }
    name ??= _auth.currentUser?.displayName ??
        _auth.currentUser?.email?.split('@').first ??
        'Usher';

    if (!mounted) return;
    setState(() => _displayName = name!);
  }

  Future<void> _logout() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Usher Dashboard'),
        backgroundColor: Colors.teal.shade600,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: _logout,
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
            onRefresh: () async => _primeName(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _UHeaderCard(displayName: _displayName),
                const SizedBox(height: 14),
                const _UStatsGrid(),
                const SizedBox(height: 18),
                _UNoticeBoardCarousel(),
                const SizedBox(height: 18),
                const _USectionTitle('Quick Actions'),
                const SizedBox(height: 8),
                const _UActionsGrid(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* -------------------- Header -------------------- */

class _UHeaderCard extends StatelessWidget {
  final String displayName;
  const _UHeaderCard({required this.displayName});

  @override
  Widget build(BuildContext context) {
    const roleLabel = 'Usher';
    final subtitle = 'Role: Usher • Welcome back';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 26,
            backgroundColor: Color(0xFFE8ECF3),
            child: Icon(Icons.verified, color: Colors.indigo, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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

/* -------------------- Stats -------------------- */

class _UStatsGrid extends StatelessWidget {
  const _UStatsGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 720
            ? 4
            : constraints.maxWidth >= 520
            ? 3
            : 3;
        final ratio = crossAxisCount >= 4 ? 1.0 : 0.65;

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: ratio,
          children: const [
            _UStatTile(label: 'Members', icon: Icons.groups, query: _UStatQuery.members),
            _UStatTile(label: 'Ministries', icon: Icons.church, query: _UStatQuery.ministries),
            _UStatTile(label: 'Upcoming', icon: Icons.event_available, query: _UStatQuery.upcomingEvents),
          ],
        );
      },
    );
  }
}

enum _UStatQuery { members, ministries, upcomingEvents }

class _UStatTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final _UStatQuery query;

  const _UStatTile({required this.label, required this.icon, required this.query});

  Stream<int> _stream() {
    final db = FirebaseFirestore.instance;
    switch (query) {
      case _UStatQuery.members:
        return db.collection('members').limit(2000).snapshots().map((s) => s.size);
      case _UStatQuery.ministries:
        return db.collection('ministries').limit(1000).snapshots().map((s) => s.size);
      case _UStatQuery.upcomingEvents:
        return db
            .collection('events')
            .where('startDate', isGreaterThanOrEqualTo: Timestamp.now())
            .limit(1000)
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

class _UNoticeBoardCarousel extends StatefulWidget {
  @override
  State<_UNoticeBoardCarousel> createState() => _UNoticeBoardCarouselState();
}

class _UNoticeBoardCarouselState extends State<_UNoticeBoardCarousel> {
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

            if (combined.isEmpty) return _UEmptyNotice();

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
                  return _UNoticeCard(isEvent: isEvent, data: data);
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _UEmptyNotice extends StatelessWidget {
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

class _UNoticeCard extends StatelessWidget {
  final bool isEvent;
  final Map<String, dynamic> data;

  const _UNoticeCard({required this.isEvent, required this.data});

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

class _USectionTitle extends StatelessWidget {
  final String text;
  const _USectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _UActionsGrid extends StatelessWidget {
  const _UActionsGrid();

  @override
  Widget build(BuildContext context) {
    final items = <_UActionItem>[
      _UActionItem('Settings', Icons.settings, '/settings'),
      _UActionItem('Events', Icons.event, '/events'),
      _UActionItem('Ministries', Icons.group_work, '/view-ministry'),
      _UActionItem('Attendance Check-In', Icons.check_circle_outline, '/attendance'),
      _UActionItem('Follow Up', Icons.assignment_turned_in, '/follow-up'),
      _UActionItem('Register Member/Visitor', Icons.how_to_reg, '/register-member'),
      _UActionItem('View Members', Icons.groups, '/view-members'),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 720 ? 4 : 2;
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
          itemBuilder: (context, i) => _UActionCard(item: items[i]),
        );
      },
    );
  }
}

class _UActionItem {
  final String label;
  final IconData icon;
  final String route;

  _UActionItem(this.label, this.icon, this.route);
}

class _UActionCard extends StatelessWidget {
  final _UActionItem item;
  const _UActionCard({required this.item});

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
