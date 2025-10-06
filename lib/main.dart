import 'package:church_management_app/services/notification_center.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Pages (core auth / onboarding)
import 'pages/login_page.dart';
import 'pages/signup1.dart';
import 'pages/signup2.dart';

// Management pages
import 'pages/prayer_request_manage_page.dart';
import 'pages/baptism_manage_page.dart';

// Dashboards & core pages
import 'pages/admin_dashboard_page.dart';
import 'pages/admin_upload_page.dart';
import 'pages/home_dashboard_page.dart';
import 'pages/forms_page.dart';
import 'pages/add_event_page.dart';
import 'pages/follow_up_page.dart';
import 'pages/giving_page.dart';
import 'pages/membership_form_page.dart';
import 'pages/attendance_checkin_page.dart';
import 'pages/post_announcements_page.dart';
import 'pages/view_members_page.dart';
import 'pages/ministres_page.dart';
import 'pages/upload_excel_page.dart';
import 'pages/debadmintestpage.dart';
import 'pages/profilepage.dart';
import 'pages/successpage.dart';

// Role-specific dashboards
import 'pages/pastor_home_dashboard_page.dart';
import 'pages/usher_home_dashboard_page.dart';

// Dedicated form pages
import 'pages/prayer_request_form_page.dart';
import 'pages/baptism_interest_form_page.dart';

// Services
import 'services/theme_provider.dart';
import 'firebase_options.dart';

// ---------------------------------------------------------------------------
// Notifications wiring
// ---------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

const String _androidChannelId = 'default_channel';
const String _androidChannelName = 'General';
const String _androidChannelDescription = 'General notifications';

const AndroidNotificationChannel _androidChannel = AndroidNotificationChannel(
  _androidChannelId,
  _androidChannelName,
  description: _androidChannelDescription,
  importance: Importance.high,
);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> _initLocalNotifications() async {
  final androidImpl =
  _fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.createNotificationChannel(_androidChannel);

  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
  );
  await _fln.initialize(initSettings);
}

Future<void> _initMessaging() async {
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await FirebaseMessaging.instance.requestPermission(
    alert: true, badge: true, sound: true, provisional: false,
  );

  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true, badge: true, sound: true,
  );

  FirebaseMessaging.onMessage.listen((RemoteMessage m) {
    final n = m.notification;
    _fln.show(
      n.hashCode,
      n?.title ?? 'New message',
      n?.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId, _androidChannelName,
          channelDescription: _androidChannelDescription,
          importance: Importance.high, priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: m.data.isNotEmpty ? m.data.toString() : null,
    );
  });
}

// ---------------------------------------------------------------------------

Future<void> _activateAppCheckDebug() async {
  // Activate DEBUG providers for dev builds
  await FirebaseAppCheck.instance.activate(
    androidProvider: AndroidProvider.debug,
    appleProvider: AppleProvider.debug,
    webProvider: null,
  );

  // Helpful logs: force a token fetch (will still 403 if not registered,
  // but helps confirm timing). The actual *debug device token* appears in
  // Logcat/Xcode as: "App Check debug token: <TOKEN>"
  try {
    final t = await FirebaseAppCheck.instance.getToken(true);
    debugPrint('[AppCheck] Got App Check token (len=${t?.length ?? 0}). '
        'If you still see 403, add your *debug device token* from logs to '
        'Firebase Console → App Check → Debug devices.');
  } catch (e) {
    debugPrint('[AppCheck] getToken error (expected until debug device is registered): $e');
  }

  await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 🔐 App Check — enable DEBUG providers for Android & Apple
  await _activateAppCheckDebug();

  // Auth language
  try {
    await FirebaseAuth.instance.setLanguageCode('en-GB');
  } catch (_) {}

  // Stripe
  Stripe.publishableKey = 'pk_test_your_publishable_key';

  // Notifications
  NotificationCenter.instance.bindToAuth();
  await _initLocalNotifications();
  await _initMessaging();

  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
      child: const RoleLoader(),
    ),
  );
}

// ---------------------------------------------------------------------------
// RoleLoader / RoleGate
// ---------------------------------------------------------------------------

class RoleLoader extends StatefulWidget {
  const RoleLoader({super.key});
  @override
  State<RoleLoader> createState() => _RoleLoaderState();
}

class _RoleLoaderState extends State<RoleLoader> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _loadRoleTheme();
  }

  Future<void> _loadRoleTheme() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final doc = await _db.collection('users').doc(user.uid).get();
    final data = doc.data() ?? {};
    final rolesRaw = List<String>.from(data['roles'] ?? const <String>[]);
    final roles = rolesRaw.map((e) => e.toLowerCase()).toList();

    String effectiveRole = 'member';
    if (roles.contains('admin')) {
      effectiveRole = 'admin';
    } else if (roles.contains('pastor')) {
      effectiveRole = 'pastor';
    } else if (roles.contains('leader')) {
      effectiveRole = 'leader';
    } else if (roles.contains('usher')) {
      effectiveRole = 'usher';
    }

    final memberId = data['memberId'] as String?;
    if (memberId != null && effectiveRole == 'member') {
      final mem = await _db.collection('members').doc(memberId).get();
      final mData = mem.data() ?? {};
      final mRoles = (mData['roles'] as List<dynamic>? ?? const [])
          .map((e) => e.toString().toLowerCase())
          .toSet();
      final ms = List<String>.from(mData['leadershipMinistries'] ?? const <String>[]);
      if (mRoles.contains('admin')) {
        effectiveRole = 'admin';
      } else if (mRoles.contains('pastor') || (mData['isPastor'] == true)) {
        effectiveRole = 'pastor';
      } else if (mRoles.contains('leader') || ms.isNotEmpty) {
        effectiveRole = 'leader';
      } else if (mRoles.contains('usher')) {
        effectiveRole = 'usher';
      }
    }

    if (!mounted) return;
    Provider.of<ThemeProvider>(context, listen: false).setRole(effectiveRole);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp(
          title: 'Church Management App',
          debugShowCheckedModeBanner: false,
          theme: themeProvider.themeData,
          home: const RoleGate(),
          onGenerateRoute: _generateRoute,
        );
      },
    );
  }
}

class RoleGate extends StatefulWidget {
  const RoleGate({super.key});
  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  late final DateTime _start;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
  }

  bool _timeout() => DateTime.now().difference(_start) > const Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _auth.userChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.active && !authSnap.hasData) {
          return LoginPage();
        }
        if (!authSnap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final uid = authSnap.data!.uid;

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _db.collection('users').doc(uid).snapshots(),
          builder: (context, userSnap) {
            if (userSnap.hasError) {
              debugPrint('[RoleGate] user doc error: ${userSnap.error}');
              return const HomeDashboardPage();
            }
            if (userSnap.connectionState == ConnectionState.waiting) {
              if (_timeout()) return const HomeDashboardPage();
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            final userExists = userSnap.data?.exists ?? false;
            final userData = userSnap.data?.data() ?? const <String, dynamic>{};

            if (!userExists) return const HomeDashboardPage();

            final userRoles = (userData['roles'] as List<dynamic>? ?? const [])
                .map((e) => e.toString().toLowerCase())
                .toSet();

            final memberId = userData['memberId'] as String?;

            if (userRoles.contains('admin')) return const AdminDashboardPage();
            if (userRoles.contains('pastor')) return const PastorHomeDashboardPage();
            if (userRoles.contains('leader')) return const AdminDashboardPage();
            if (userRoles.contains('usher')) return const UsherHomeDashboardPage();

            if (memberId == null) return const HomeDashboardPage();

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _db.collection('members').doc(memberId).snapshots(),
              builder: (context, memSnap) {
                if (memSnap.hasError) return const HomeDashboardPage();
                if (memSnap.connectionState == ConnectionState.waiting) {
                  if (_timeout()) return const HomeDashboardPage();
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                }

                final md = memSnap.data?.data() ?? const <String, dynamic>{};
                final memberRoles = (md['roles'] as List<dynamic>? ?? const [])
                    .map((e) => e.toString().toLowerCase())
                    .toSet();
                final leads = List<String>.from(md['leadershipMinistries'] ?? const <String>[]);

                if (memberRoles.contains('admin')) return const AdminDashboardPage();
                if (memberRoles.contains('pastor') || (md['isPastor'] == true)) {
                  return const PastorHomeDashboardPage();
                }
                if (memberRoles.contains('leader') || leads.isNotEmpty) {
                  return const AdminDashboardPage();
                }
                if (memberRoles.contains('usher')) return const UsherHomeDashboardPage();

                return const HomeDashboardPage();
              },
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

Route<dynamic> _generateRoute(RouteSettings settings) {
  switch (settings.name) {
    case '/login':
      return MaterialPageRoute(builder: (_) => LoginPage());

    case '/signupStep1':
      return MaterialPageRoute(builder: (_) => const SignupStep1Page());

    case '/signupStep2':
      final args = settings.arguments as Map<String, dynamic>;
      return MaterialPageRoute(
        builder: (_) => SignupStep2Page(uid: args['uid'], email: args['email']),
      );

    case '/admin-dashboard':
      return MaterialPageRoute(builder: (_) => const AdminDashboardPage());

    case '/pastor-dashboard':
      return MaterialPageRoute(builder: (_) => const PastorHomeDashboardPage());

    case '/usher-dashboard':
      return MaterialPageRoute(builder: (_) => const UsherHomeDashboardPage());

    case '/admin-upload':
      return MaterialPageRoute(builder: (_) => const AdminUploadPage());

    case '/forms':
      return MaterialPageRoute(builder: (_) => FormsPage());

    case '/events':
      return MaterialPageRoute(builder: (_) => AddEventPage());

    case '/register-member':
      return MaterialPageRoute(builder: (_) => const MembershipFormPage());

    case '/home-dashboard':
      return MaterialPageRoute(builder: (_) => const HomeDashboardPage());

    case '/giving':
      return MaterialPageRoute(builder: (_) => const GivingPage());

    case '/attendance':
      return MaterialPageRoute(builder: (_) => const AttendanceCheckInPage());

    case '/view-members':
      return MaterialPageRoute(builder: (_) => const ViewMembersPage());

    case '/follow-up':
      return MaterialPageRoute(builder: (_) => const FollowUpPage());

    case '/post-announcements':
      return MaterialPageRoute(builder: (_) => PostAnnouncementsPage());

    case '/view-ministry':
      return MaterialPageRoute(builder: (_) => const MinistresPage());

    case '/manage-prayer-requests':
      return MaterialPageRoute(builder: (_) => const PrayerRequestManagePage());

    case '/manage-baptism':
      return MaterialPageRoute(builder: (_) => const BaptismManagePage());

    case '/form-prayer-request':
      return MaterialPageRoute(builder: (_) => const PrayerRequestFormPage());

    case '/form-baptism-interest':
      return MaterialPageRoute(builder: (_) => const BaptismInterestFormPage());

    case '/uploadExcel':
      return MaterialPageRoute(builder: (_) => const ExcelDatabaseUploader());

    case '/testadmin':
      return MaterialPageRoute(builder: (_) => const DebugAdminSetterPage());

    case '/profile':
      return MaterialPageRoute(builder: (_) => HomePage());

    case '/success':
      return MaterialPageRoute(builder: (_) => const SuccessPage());

    default:
      return MaterialPageRoute(
        builder: (_) => const Scaffold(
          body: Center(child: Text('Page not found')),
        ),
      );
  }
}
