import 'package:church_management_app/services/notification_center.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

// ✅ Add these
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Pages
import 'pages/login_page.dart';
import 'pages/signup1.dart';
import 'pages/signup2.dart';
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

// Services
import 'services/theme_provider.dart';
import 'firebase_options.dart';

// ---------------------------------------------------------------------------
// 🔔 Notification wiring (FCM + foreground banners)
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

// Runs in its own isolate on background push
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Handle background data if needed.
}

Future<void> _initLocalNotifications() async {
  // Android: create channel
  final androidImpl = _fln.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
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
  // Background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Ask permissions (iOS + Android 13+)
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );

  // Show alerts while app is foreground (iOS)
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // Foreground notifications -> show a local banner
  FirebaseMessaging.onMessage.listen((RemoteMessage m) {
    final n = m.notification;
    _fln.show(
      n.hashCode,
      n?.title ?? 'New message',
      n?.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          _androidChannelName,
          channelDescription: _androidChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: m.data.isNotEmpty ? m.data.toString() : null,
    );
  });
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 🔑 Stripe (replace with your real key)
  Stripe.publishableKey = 'pk_test_your_publishable_key';

  // ✅ Ensure in-app Firestore listeners start/stop with auth changes
  // (so real-time updates work even if the bell icon hasn't built yet)
  NotificationCenter.instance.bindToAuth();

  // 🔔 OS-level notifications
  await _initLocalNotifications();
  await _initMessaging();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const RoleLoader(),
    ),
  );
}

// 🌟 RoleLoader => Loads user role theme first, then starts app (routing is below)
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
    final roles = List<String>.from(data['roles'] ?? const <String>[]);

    String effectiveRole = 'member';
    if (roles.contains('admin')) {
      effectiveRole = 'admin';
    } else if (roles.contains('leader')) {
      effectiveRole = 'leader';
    }

    final memberId = data['memberId'] as String?;
    if (effectiveRole == 'member' && memberId != null) {
      final mem = await _db.collection('members').doc(memberId).get();
      final ms = List<String>.from(
          (mem.data() ?? const {})['leadershipMinistries'] ?? const <String>[]);
      if (ms.isNotEmpty) effectiveRole = 'leader';
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

// Gate to decide initial page after login
class RoleGate extends StatelessWidget {
  const RoleGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = FirebaseAuth.instance;
    final db = FirebaseFirestore.instance;

    return StreamBuilder<User?>(
      stream: auth.authStateChanges(),
      builder: (context, authSnap) {
        if (!authSnap.hasData) return LoginPage();

        final uid = authSnap.data!.uid;
        return FutureBuilder<DocumentSnapshot>(
          future: db.collection('users').doc(uid).get(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }

            final userData =
                (userSnap.data?.data() as Map<String, dynamic>?) ?? {};
            final roles =
            List<String>.from(userData['roles'] ?? const <String>[]);
            final memberId = userData['memberId'] as String?;

            String effectiveRole = 'member';
            if (roles.contains('admin')) {
              effectiveRole = 'admin';
            } else if (roles.contains('leader')) {
              effectiveRole = 'leader';
            }

            if (effectiveRole == 'admin' || effectiveRole == 'leader') {
              return const AdminDashboardPage();
            }

            if (memberId == null) {
              return const HomeDashboardPage();
            }

            return StreamBuilder<DocumentSnapshot>(
              stream: db.collection('members').doc(memberId).snapshots(),
              builder: (context, memSnap) {
                if (memSnap.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                      body: Center(child: CircularProgressIndicator()));
                }
                final md = memSnap.data?.data() as Map<String, dynamic>?;
                final leads = List<String>.from(
                    md?['leadershipMinistries'] ?? const <String>[]);
                if (leads.isNotEmpty) {
                  return const AdminDashboardPage();
                }
                return const HomeDashboardPage();
              },
            );
          },
        );
      },
    );
  }
}

// 📚 Route Generator — centralized
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
