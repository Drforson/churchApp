import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

import 'package:church_management_app/widgets/notification_settings_panel.dart';
import 'package:church_management_app/pages/notification_center_page.dart';
import 'package:church_management_app/pages/pastor_ministry_approvals_page.dart';
import 'package:church_management_app/pages/join_request_approval_page.dart';
import 'package:church_management_app/services/attendance_ping_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  final _messaging = FirebaseMessaging.instance;

  String _versionLabel = '';
  String _locationStatus = 'Checking...';
  bool _locationBusy = false;
  bool _prefsBusy = false;
  bool _loadedConfig = false;

  final _churchNameCtrl = TextEditingController();
  final _churchEmailCtrl = TextEditingController();
  final _churchPhoneCtrl = TextEditingController();
  final _churchAddressCtrl = TextEditingController();
  final _privacyPolicyCtrl = TextEditingController();
  final _termsCtrl = TextEditingController();
  final _defaultRadiusCtrl = TextEditingController();
  final _welcomeTitleCtrl = TextEditingController();
  final _welcomeBodyCtrl = TextEditingController();
  final _welcomeMessageCtrl = TextEditingController();
  final _reminderTitleCtrl = TextEditingController();
  final _reminderBodyCtrl = TextEditingController();
  final _closingTitleCtrl = TextEditingController();
  final _closingBodyCtrl = TextEditingController();
  final _closingMessageCtrl = TextEditingController();

  Map<String, dynamic> _globalConfig = const {};
  Map<String, dynamic> _legalConfig = const {};

  @override
  void initState() {
    super.initState();
    _loadAppInfo();
    _refreshLocationStatus();
    _loadConfig();
  }

  @override
  void dispose() {
    _churchNameCtrl.dispose();
    _churchEmailCtrl.dispose();
    _churchPhoneCtrl.dispose();
    _churchAddressCtrl.dispose();
    _privacyPolicyCtrl.dispose();
    _termsCtrl.dispose();
    _defaultRadiusCtrl.dispose();
    _welcomeTitleCtrl.dispose();
    _welcomeBodyCtrl.dispose();
    _welcomeMessageCtrl.dispose();
    _reminderTitleCtrl.dispose();
    _reminderBodyCtrl.dispose();
    _closingTitleCtrl.dispose();
    _closingBodyCtrl.dispose();
    _closingMessageCtrl.dispose();
    super.dispose();
  }

  Future<_RoleInfo> _loadRoleInfo() async {
    final user = _auth.currentUser;
    if (user == null) return _RoleInfo.empty();

    final token = await user.getIdTokenResult(true);
    final claims = token.claims ?? const <String, dynamic>{};

    final userSnap = await _db.collection('users').doc(user.uid).get();
    final u = userSnap.data() ?? const <String, dynamic>{};

    final roles = (u['roles'] is List)
        ? (u['roles'] as List).map((e) => e.toString().toLowerCase()).toSet()
        : <String>{};
    final roleSingle = (u['role'] ?? '').toString().toLowerCase().trim();
    final hasLeadMins =
        (u['leadershipMinistries'] is List) && (u['leadershipMinistries'] as List).isNotEmpty;

    bool isAdmin = roles.contains('admin') ||
        roleSingle == 'admin' ||
        u['admin'] == true ||
        u['isAdmin'] == true ||
        claims['admin'] == true ||
        claims['isAdmin'] == true;
    bool isPastor = roles.contains('pastor') ||
        roleSingle == 'pastor' ||
        u['pastor'] == true ||
        u['isPastor'] == true ||
        claims['pastor'] == true ||
        claims['isPastor'] == true;
    bool isLeader = roles.contains('leader') ||
        roleSingle == 'leader' ||
        u['leader'] == true ||
        u['isLeader'] == true ||
        hasLeadMins ||
        claims['leader'] == true ||
        claims['isLeader'] == true;
    bool isUsher = roles.contains('usher') || roleSingle == 'usher';

    final memberId = (u['memberId'] ?? '').toString();
    if (memberId.isNotEmpty) {
      try {
        final mSnap = await _db.collection('members').doc(memberId).get();
        final m = mSnap.data() ?? const <String, dynamic>{};
        final mRoles = (m['roles'] is List)
            ? (m['roles'] as List).map((e) => e.toString().toLowerCase()).toSet()
            : <String>{};
        final mLeads =
            (m['leadershipMinistries'] is List) && (m['leadershipMinistries'] as List).isNotEmpty;
        isAdmin = isAdmin || mRoles.contains('admin');
        isPastor = isPastor || mRoles.contains('pastor') || m['isPastor'] == true;
        isLeader = isLeader || mRoles.contains('leader') || mLeads;
      } catch (_) {}
    }

    String roleLabel = 'Member';
    if (isAdmin) {
      roleLabel = 'Admin';
    } else if (isPastor) {
      roleLabel = 'Pastor';
    } else if (isLeader) {
      roleLabel = 'Leader';
    } else if (isUsher) {
      roleLabel = 'Usher';
    }

    return _RoleInfo(
      isAdmin: isAdmin,
      isPastor: isPastor,
      isLeader: isLeader,
      isUsher: isUsher,
      roleLabel: roleLabel,
      memberId: memberId,
    );
  }

  Future<void> _sendPasswordReset() async {
    final email = _auth.currentUser?.email;
    if (email == null || email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No email found for this account.')),
      );
      return;
    }
    await _auth.sendPasswordResetEmail(email: email);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password reset email sent.')),
    );
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _versionLabel = '${info.version} (${info.buildNumber})';
      });
    } catch (_) {}
  }

  Future<void> _refreshLocationStatus() async {
    setState(() => _locationBusy = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      if (!mounted) return;
      setState(() {
        _locationStatus =
            'Service: ${enabled ? 'on' : 'off'} · Permission: ${perm.name}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _locationStatus = 'Error: $e');
    } finally {
      if (mounted) setState(() => _locationBusy = false);
    }
  }

  Future<void> _loadConfig() async {
    if (_loadedConfig) return;
    _loadedConfig = true;
    try {
      final globalSnap = await _db.doc('church_config/global').get();
      final legalSnap = await _db.doc('church_config/legal').get();
      final attendanceSnap = await _db.doc('church_config/attendance').get();
      final notifSnap = await _db.doc('church_config/notifications').get();

      final global = globalSnap.data() ?? <String, dynamic>{};
      final legal = legalSnap.data() ?? <String, dynamic>{};
      final attendance = attendanceSnap.data() ?? <String, dynamic>{};
      final notif = notifSnap.data() ?? <String, dynamic>{};

      _churchNameCtrl.text = (global['churchName'] ?? '').toString();
      _churchEmailCtrl.text = (global['email'] ?? '').toString();
      _churchPhoneCtrl.text = (global['phone'] ?? '').toString();
      _churchAddressCtrl.text = (global['address'] ?? '').toString();
      _privacyPolicyCtrl.text = (legal['privacyPolicyUrl'] ?? '').toString();
      _termsCtrl.text = (legal['termsUrl'] ?? '').toString();

      final radius = attendance['defaultRadiusMeters'];
      if (radius != null) {
        _defaultRadiusCtrl.text = radius.toString();
      }

      _welcomeTitleCtrl.text = (notif['attendanceWelcomeTitle'] ?? '').toString();
      _welcomeBodyCtrl.text = (notif['attendanceWelcomeBody'] ?? '').toString();
      _welcomeMessageCtrl.text = (notif['attendanceWelcomeMessage'] ?? '').toString();
      _reminderTitleCtrl.text = (notif['attendanceReminderTitle'] ?? '').toString();
      _reminderBodyCtrl.text = (notif['attendanceReminderBody'] ?? '').toString();
      _closingTitleCtrl.text = (notif['attendanceClosingTitle'] ?? '').toString();
      _closingBodyCtrl.text = (notif['attendanceClosingBody'] ?? '').toString();
      _closingMessageCtrl.text = (notif['attendanceClosingMessage'] ?? '').toString();

      if (!mounted) return;
      setState(() {
        _globalConfig = global;
        _legalConfig = legal;
      });
    } catch (_) {}
  }

  Future<void> _saveGlobalInfo() async {
    await _db.doc('church_config/global').set(
      {
        'churchName': _churchNameCtrl.text.trim(),
        'email': _churchEmailCtrl.text.trim(),
        'phone': _churchPhoneCtrl.text.trim(),
        'address': _churchAddressCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    if (!mounted) return;
    setState(() {
      _globalConfig = {
        'churchName': _churchNameCtrl.text.trim(),
        'email': _churchEmailCtrl.text.trim(),
        'phone': _churchPhoneCtrl.text.trim(),
        'address': _churchAddressCtrl.text.trim(),
      };
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Global church info saved.')),
    );
  }

  Future<void> _saveLegalLinks() async {
    await _db.doc('church_config/legal').set(
      {
        'privacyPolicyUrl': _privacyPolicyCtrl.text.trim(),
        'termsUrl': _termsCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    if (!mounted) return;
    setState(() {
      _legalConfig = {
        'privacyPolicyUrl': _privacyPolicyCtrl.text.trim(),
        'termsUrl': _termsCtrl.text.trim(),
      };
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Legal links saved.')),
    );
  }

  Future<void> _saveAttendanceDefaults() async {
    final radius = double.tryParse(_defaultRadiusCtrl.text.trim());
    await _db.doc('church_config/attendance').set(
      {
        'defaultRadiusMeters': radius ?? 500,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Attendance defaults saved.')),
    );
  }

  Future<void> _saveNotificationTemplates() async {
    await _db.doc('church_config/notifications').set(
      {
        'attendanceWelcomeTitle': _welcomeTitleCtrl.text.trim(),
        'attendanceWelcomeBody': _welcomeBodyCtrl.text.trim(),
        'attendanceWelcomeMessage': _welcomeMessageCtrl.text.trim(),
        'attendanceReminderTitle': _reminderTitleCtrl.text.trim(),
        'attendanceReminderBody': _reminderBodyCtrl.text.trim(),
        'attendanceClosingTitle': _closingTitleCtrl.text.trim(),
        'attendanceClosingBody': _closingBodyCtrl.text.trim(),
        'attendanceClosingMessage': _closingMessageCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notification templates saved.')),
    );
  }

  Future<void> _updateNotificationPrefs({
    required bool enabled,
    required bool attendancePing,
    required bool prayerUpdates,
    required bool ministryFeed,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (mounted) setState(() => _prefsBusy = true);
    try {
      await _db.doc('users/${user.uid}').set(
        {
          'notificationPrefs': {
            'enabled': enabled,
            'attendancePing': attendancePing,
            'prayerUpdates': prayerUpdates,
            'ministryFeed': ministryFeed,
          },
          'notificationPrefsUpdatedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      if (enabled && attendancePing) {
        await _messaging.subscribeToTopic('all_members');
      } else {
        await _messaging.unsubscribeFromTopic('all_members');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update notification prefs: $e')),
      );
    } finally {
      if (mounted) setState(() => _prefsBusy = false);
    }
  }

  Future<void> _testGpsNow() async {
    final ok = await AttendancePingService.I.ensureLocationReady(
      context,
      proactive: false,
      requireBackground: false,
    );
    if (!ok) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('GPS ok: ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GPS failed: $e')),
      );
    }
  }

  Future<void> _exportAttendanceReport() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    final dateKey = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    try {
      final res = await _functions.httpsCallable('exportAttendanceReport').call({
        'dateKey': dateKey,
      });
      final data = (res.data is Map) ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      final csv = (data['csv'] ?? '').toString();
      if (csv.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: csv));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attendance report copied to clipboard ($dateKey).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _signOutAllDevices() async {
    try {
      await _functions.httpsCallable('revokeMySessions').call();
      await _auth.signOut();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign out failed: $e')),
      );
    }
  }

  Future<void> _confirmSignOutAllDevices() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out of all devices?'),
        content: const Text('This will revoke sessions on every device. You will need to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) {
      await _signOutAllDevices();
    }
  }

  Future<void> _launchLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid link.')),
      );
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link.')),
      );
    }
  }

  InputDecoration _denseDecoration(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon == null ? null : Icon(icon),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
    );
  }

  Widget _notificationPrefsPanel(User user) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _db.collection('users').doc(user.uid).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? const <String, dynamic>{};
        final prefs = (data['notificationPrefs'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
        final enabled = prefs['enabled'] != false;
        final attendancePing = prefs['attendancePing'] != false;
        final prayerUpdates = prefs['prayerUpdates'] != false;
        final ministryFeed = prefs['ministryFeed'] != false;

        return Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable notifications'),
              dense: true,
              visualDensity: VisualDensity.compact,
              value: enabled,
              onChanged: _prefsBusy
                  ? null
                  : (v) => _updateNotificationPrefs(
                        enabled: v,
                        attendancePing: attendancePing,
                        prayerUpdates: prayerUpdates,
                        ministryFeed: ministryFeed,
                      ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Attendance pings'),
              subtitle: const Text('Receive attendance check-in pings'),
              dense: true,
              visualDensity: VisualDensity.compact,
              value: attendancePing,
              onChanged: (!enabled || _prefsBusy)
                  ? null
                  : (v) => _updateNotificationPrefs(
                        enabled: enabled,
                        attendancePing: v,
                        prayerUpdates: prayerUpdates,
                        ministryFeed: ministryFeed,
                      ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prayer request updates'),
              dense: true,
              visualDensity: VisualDensity.compact,
              value: prayerUpdates,
              onChanged: (!enabled || _prefsBusy)
                  ? null
                  : (v) => _updateNotificationPrefs(
                        enabled: enabled,
                        attendancePing: attendancePing,
                        prayerUpdates: v,
                        ministryFeed: ministryFeed,
                      ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ministry feed updates'),
              dense: true,
              visualDensity: VisualDensity.compact,
              value: ministryFeed,
              onChanged: (!enabled || _prefsBusy)
                  ? null
                  : (v) => _updateNotificationPrefs(
                        enabled: enabled,
                        attendancePing: attendancePing,
                        prayerUpdates: prayerUpdates,
                        ministryFeed: v,
                      ),
            ),
          ],
        );
      },
    );
  }

  Widget _consentTile(String memberId) {
    if (memberId.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Consent to data use'),
        subtitle: Text('Link your member profile to manage consent.'),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _db.collection('members').doc(memberId).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? const <String, dynamic>{};
        final consent = data['consentToDataUse'] == true;
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Consent to data use'),
          dense: true,
          visualDensity: VisualDensity.compact,
          value: consent,
          onChanged: (v) async {
            await _db.collection('members').doc(memberId).set(
              {
                'consentToDataUse': v,
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_RoleInfo>(
      future: _loadRoleInfo(),
      builder: (context, snap) {
        final info = snap.data ?? _RoleInfo.empty();
        final user = _auth.currentUser;
        final canManage = info.isAdmin || info.isPastor || info.isLeader;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            centerTitle: true,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              children: [
                _Section(
                  title: 'Account',
                  children: [
                    _ActionTile(
                      icon: Icons.person_outline,
                      title: 'My Profile',
                      onTap: () => Navigator.pushNamed(context, '/profile'),
                    ),
                    _InfoTile(
                      icon: Icons.badge_outlined,
                      title: 'Role',
                      value: info.roleLabel,
                    ),
                  ],
                ),
                _Section(
                  title: 'Security',
                  children: [
                    _ActionTile(
                      icon: Icons.lock_outline,
                      title: 'Change Password',
                      onTap: _sendPasswordReset,
                    ),
                    _ActionTile(
                      icon: Icons.logout,
                      title: 'Sign Out',
                      onTap: _signOut,
                    ),
                    _ActionTile(
                      icon: Icons.logout_outlined,
                      title: 'Sign Out of All Devices',
                      onTap: _confirmSignOutAllDevices,
                    ),
                  ],
                ),
                _Section(
                  title: 'Notifications',
                  children: [
                    _ActionTile(
                      icon: Icons.notifications_none,
                      title: 'Notification Center',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const NotificationCenterPage()),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6.0),
                      child: NotificationSettingsPanel(),
                    ),
                    if (user != null) _notificationPrefsPanel(user),
                  ],
                ),
                _Section(
                  title: 'Location',
                  children: [
                    _InfoTile(
                      icon: Icons.gps_fixed,
                      title: 'Status',
                      value: _locationStatus,
                    ),
                    _ActionTile(
                      icon: Icons.refresh,
                      title: _locationBusy ? 'Refreshing...' : 'Refresh Status',
                      onTap: _locationBusy ? () {} : _refreshLocationStatus,
                    ),
                    _ActionTile(
                      icon: Icons.location_on_outlined,
                      title: 'Open Location Settings',
                      onTap: () => Geolocator.openLocationSettings(),
                    ),
                    _ActionTile(
                      icon: Icons.settings_outlined,
                      title: 'Open App Settings',
                      onTap: () => Geolocator.openAppSettings(),
                    ),
                    _ActionTile(
                      icon: Icons.my_location_outlined,
                      title: 'Allow All the Time',
                      onTap: () => AttendancePingService.I.ensureLocationReady(
                        context,
                        proactive: false,
                        requireBackground: true,
                      ),
                    ),
                  ],
                ),
                _Section(
                  title: 'Privacy',
                  children: [
                    _consentTile(info.memberId),
                    _ActionTile(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      onTap: () {
                        final url = (_legalConfig['privacyPolicyUrl'] ?? '').toString().trim();
                        if (url.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Privacy policy link not configured.')),
                          );
                          return;
                        }
                        _launchLink(url);
                      },
                    ),
                  ],
                ),
                if (info.isAdmin || info.isPastor || info.isLeader)
                  _Section(
                    title: 'Attendance Tools',
                    children: [
                      _ActionTile(
                        icon: Icons.gps_fixed,
                        title: 'Test GPS Now',
                        onTap: _testGpsNow,
                      ),
                      _ActionTile(
                        icon: Icons.schedule_outlined,
                        title: 'Attendance Setup',
                        onTap: () => Navigator.pushNamed(context, '/attendance-setup'),
                      ),
                      _ActionTile(
                        icon: Icons.check_circle_outline,
                        title: 'Attendance Check-In',
                        onTap: () => Navigator.pushNamed(context, '/attendance'),
                      ),
                    ],
                  ),
                _Section(
                  title: 'Ministry Tools',
                  children: [
                    _ActionTile(
                      icon: Icons.groups_outlined,
                      title: canManage ? 'Manage Ministry Members' : 'View Ministries',
                      onTap: () => Navigator.pushNamed(context, '/view-ministry'),
                    ),
                    if (canManage)
                      _ActionTile(
                        icon: Icons.people_outline,
                        title: 'View Members',
                        onTap: () => Navigator.pushNamed(context, '/view-members'),
                      ),
                    if (info.isLeader || info.isAdmin || info.isPastor)
                      _ActionTile(
                        icon: Icons.how_to_reg_outlined,
                        title: 'Join Requests',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const JoinRequestApprovalPage()),
                        ),
                      ),
                  ],
                ),
                if (canManage)
                  _Section(
                    title: 'Reports',
                    children: [
                      _ActionTile(
                        icon: Icons.download_outlined,
                        title: 'Attendance Report Export',
                        onTap: _exportAttendanceReport,
                      ),
                      _ActionTile(
                        icon: Icons.assignment_outlined,
                        title: 'Follow-Up Summary',
                        onTap: () => Navigator.pushNamed(context, '/follow-up'),
                      ),
                    ],
                  ),
                if (info.isAdmin || info.isPastor)
                  _Section(
                    title: 'Ministry Creation Requests',
                    children: [
                      _ActionTile(
                        icon: Icons.approval_outlined,
                        title: 'Approve/Deny Requests',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
                        ),
                      ),
                    ],
                  ),
                if (info.isAdmin || info.isPastor)
                  _Section(
                    title: 'Admin Utilities',
                    children: [
                      _ActionTile(
                        icon: Icons.group_add_outlined,
                        title: 'Register Member',
                        onTap: () => Navigator.pushNamed(context, '/register-member'),
                      ),
                      _ActionTile(
                        icon: Icons.upload_file_outlined,
                        title: 'Import Members (CSV/Excel)',
                        onTap: () => Navigator.pushNamed(context, '/uploadExcel'),
                      ),
                      _ActionTile(
                        icon: Icons.admin_panel_settings_outlined,
                        title: 'Manage Roles & Permissions',
                        onTap: () => Navigator.pushNamed(context, '/manage-roles'),
                      ),
                      if (!kReleaseMode)
                        _ActionTile(
                          icon: Icons.cloud_upload_outlined,
                          title: 'Admin Upload Tools',
                          onTap: () => Navigator.pushNamed(context, '/admin-upload'),
                        ),
                    ],
                  ),
                if (info.isAdmin || info.isPastor)
                  _Section(
                    title: 'System Settings',
                    children: [
                      _SubHeader('Attendance Defaults'),
                      TextField(
                        controller: _defaultRadiusCtrl,
                        keyboardType: TextInputType.number,
                        decoration: _denseDecoration(
                          'Default radius (meters)',
                          icon: Icons.place_outlined,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ActionTile(
                        icon: Icons.save_outlined,
                        title: 'Save Attendance Defaults',
                        onTap: _saveAttendanceDefaults,
                      ),
                      const Divider(),
                      _SubHeader('Notification Templates'),
                      TextField(
                        controller: _welcomeTitleCtrl,
                        decoration: _denseDecoration(
                          'Welcome title',
                          icon: Icons.notifications_outlined,
                        ),
                      ),
                      TextField(
                        controller: _welcomeBodyCtrl,
                        decoration: _denseDecoration('Welcome body'),
                      ),
                      TextField(
                        controller: _welcomeMessageCtrl,
                        decoration: _denseDecoration('Welcome message (payload)'),
                      ),
                      TextField(
                        controller: _reminderTitleCtrl,
                        decoration: _denseDecoration('Reminder title'),
                      ),
                      TextField(
                        controller: _reminderBodyCtrl,
                        decoration: _denseDecoration('Reminder body'),
                      ),
                      TextField(
                        controller: _closingTitleCtrl,
                        decoration: _denseDecoration('Closing title'),
                      ),
                      TextField(
                        controller: _closingBodyCtrl,
                        decoration: _denseDecoration('Closing body'),
                      ),
                      TextField(
                        controller: _closingMessageCtrl,
                        decoration: _denseDecoration('Closing message (payload)'),
                      ),
                      const SizedBox(height: 6),
                      _ActionTile(
                        icon: Icons.save_outlined,
                        title: 'Save Notification Templates',
                        onTap: _saveNotificationTemplates,
                      ),
                      const Divider(),
                      _SubHeader('Global Church Info'),
                      TextField(
                        controller: _churchNameCtrl,
                        decoration: _denseDecoration('Church name'),
                      ),
                      TextField(
                        controller: _churchEmailCtrl,
                        decoration: _denseDecoration('Church email'),
                      ),
                      TextField(
                        controller: _churchPhoneCtrl,
                        decoration: _denseDecoration('Church phone'),
                      ),
                      TextField(
                        controller: _churchAddressCtrl,
                        decoration: _denseDecoration('Church address'),
                      ),
                      const SizedBox(height: 6),
                      _ActionTile(
                        icon: Icons.save_outlined,
                        title: 'Save Global Info',
                        onTap: _saveGlobalInfo,
                      ),
                      const Divider(),
                      _SubHeader('Legal Links'),
                      TextField(
                        controller: _privacyPolicyCtrl,
                        decoration: _denseDecoration('Privacy policy URL'),
                      ),
                      TextField(
                        controller: _termsCtrl,
                        decoration: _denseDecoration('Terms & conditions URL'),
                      ),
                      const SizedBox(height: 6),
                      _ActionTile(
                        icon: Icons.save_outlined,
                        title: 'Save Legal Links',
                        onTap: _saveLegalLinks,
                      ),
                    ],
                  ),
                _Section(
                  title: 'Support',
                  children: [
                    _ActionTile(
                      icon: Icons.feedback_outlined,
                      title: 'Send Feedback',
                      onTap: () => Navigator.pushNamed(context, '/feedback'),
                    ),
                    _ActionTile(
                      icon: Icons.contact_mail_outlined,
                      title: 'Contact Church Admin',
                      onTap: () {
                        final email = (_globalConfig['email'] ?? '').toString().trim();
                        final phone = (_globalConfig['phone'] ?? '').toString().trim();
                        if (email.isNotEmpty) {
                          _launchLink('mailto:$email');
                          return;
                        }
                        if (phone.isNotEmpty) {
                          _launchLink('tel:$phone');
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Church contact info not configured.')),
                        );
                      },
                    ),
                  ],
                ),
                _Section(
                  title: 'App Info',
                  children: [
                    _InfoTile(
                      icon: Icons.info_outline,
                      title: 'Version',
                      value: _versionLabel.isEmpty ? 'Unknown' : _versionLabel,
                    ),
                    _ActionTile(
                      icon: Icons.description_outlined,
                      title: 'Terms & Conditions',
                      onTap: () {
                        final url = (_legalConfig['termsUrl'] ?? '').toString().trim();
                        if (url.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Terms link not configured.')),
                          );
                          return;
                        }
                        _launchLink(url);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RoleInfo {
  final bool isAdmin;
  final bool isPastor;
  final bool isLeader;
  final bool isUsher;
  final String roleLabel;
  final String memberId;

  const _RoleInfo({
    required this.isAdmin,
    required this.isPastor,
    required this.isLeader,
    required this.isUsher,
    required this.roleLabel,
    required this.memberId,
  });

  factory _RoleInfo.empty() => const _RoleInfo(
        isAdmin: false,
        isPastor: false,
        isLeader: false,
        isUsher: false,
        roleLabel: 'Member',
        memberId: '',
      );
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 32,
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 32,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(value),
    );
  }
}

class _SubHeader extends StatelessWidget {
  final String text;
  const _SubHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 6.0),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
