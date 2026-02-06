import 'dart:async';

import 'package:church_management_app/pages/feedback_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:flutter/foundation.dart'; // for kReleaseMode
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Pages
import 'pages/attendance_setup_page.dart';
import 'pages/login_page.dart';
import 'pages/signup1.dart';

import 'pages/prayer_request_manage_page.dart';
import 'pages/baptism_manage_page.dart';

import 'pages/admin_dashboard_page.dart';
import 'pages/admin_upload_page.dart';
import 'pages/home_dashboard_page.dart';
import 'pages/forms_page.dart';
import 'pages/events_page.dart';
import 'pages/follow_up_page.dart';
import 'pages/giving_page.dart';
import 'pages/membership_form_page.dart';
import 'pages/attendance_checkin_page.dart';
import 'pages/post_announcements_page.dart';
import 'pages/view_members_page.dart';
import 'pages/ministries_page.dart';
import 'pages/upload_excel_page.dart';
import 'pages/debadmintestpage.dart';
import 'pages/profilepage.dart';
import 'pages/successpage.dart';

import 'pages/pastor_home_dashboard_page.dart';
import 'pages/usher_home_dashboard_page.dart';

import 'pages/prayer_request_form_page.dart';
import 'pages/baptism_interest_form_page.dart';

import 'services/theme_provider.dart';
import 'firebase_options.dart';
import 'secrets.dart';

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
  await _fln.initialize(settings: initSettings);
}

Future<void> _initMessaging() async {
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );

  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  FirebaseMessaging.onMessage.listen((RemoteMessage m) {
    final n = m.notification;
    _fln.show(
      id: n.hashCode,
      title: n?.title ?? 'New message',
      body: n?.body ?? '',
      notificationDetails: const NotificationDetails(
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
// App Check
// ---------------------------------------------------------------------------

Future<void> _activateAppCheck() async {
  await FirebaseAppCheck.instance.activate(
    androidProvider: kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
    // Use deviceCheck for stability unless App Attest is configured end-to-end
    appleProvider: kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
  );

  // Force an App Check token now so the first callable won’t race
  try {
    final t = await FirebaseAppCheck.instance
        .getToken(true)
        .timeout(const Duration(seconds: 5));
    debugPrint('[AppCheck] token len=${t?.length ?? 0}');
    if (!kReleaseMode) {
      debugPrint('[AppCheck] If Firestore is denied in debug, add the "App Check debug token" from logcat to Firebase Console.');
      debugPrint('[AppCheck] current token (debug only): ${t ?? 'null'}');
    }
  } on TimeoutException {
    debugPrint('[AppCheck] getToken timeout; continuing startup.');
  } catch (e) {
    debugPrint('[AppCheck] getToken warn: $e');
    if (!kReleaseMode) {
      debugPrint('[AppCheck] If you see "App Check debug token" in logcat, add it in Firebase Console → App Check → Debug tokens.');
    }
  }

  await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const RoleLoader(),
    ),
  );

  // Post-start initialization to avoid blocking first frame.
  unawaited(_postStartInit());
}

Future<void> _postStartInit() async {
  // 🔐 App Check
  await _activateAppCheck();

  // Auth language
  try {
    await FirebaseAuth.instance.setLanguageCode('en-GB');
  } catch (_) {}

  // Stripe (via --dart-define)
  if (kStripePublishableKey.isNotEmpty) {
    Stripe.publishableKey = kStripePublishableKey;
  } else {
    debugPrint('[Stripe] publishable key missing; payments will fail.');
  }

  // Notifications
  await _initLocalNotifications();
  await _initMessaging();
}

// ---------------------------------------------------------------------------
// Role utilities
// ---------------------------------------------------------------------------

/// Order of precedence: admin > pastor > leader > usher > member
String _resolveRoleFromUserData(Map<String, dynamic> data) {
  // First: explicit boolean flags (new/legacy)
  if (data['admin'] == true || data['isAdmin'] == true) return 'admin';
  if (data['pastor'] == true || data['isPastor'] == true) return 'pastor';
  if (data['leader'] == true || data['isLeader'] == true) return 'leader';

  // Prefer canonical single field from backend
  final single = (data['role'] is String)
      ? (data['role'] as String).toLowerCase().trim()
      : null;

  if (single != null && single.isNotEmpty) {
    return single;
  }

  // Fallback to legacy roles[]
  final legacy = (data['roles'] is List)
      ? (data['roles'] as List)
      .map((e) => e.toString().toLowerCase().trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      : <String>{};

  if (legacy.contains('admin')) return 'admin';
  if (legacy.contains('pastor')) return 'pastor';
  if (legacy.contains('leader')) return 'leader';
  if (legacy.contains('usher')) return 'usher';
  return 'member';
}

/// Order of precedence: admin > pastor > leader > member
String _resolveRoleFromClaims(Map<String, dynamic> claims) {
  if (claims['admin'] == true || claims['isAdmin'] == true) return 'admin';
  if (claims['pastor'] == true || claims['isPastor'] == true) return 'pastor';
  if (claims['leader'] == true || claims['isLeader'] == true) return 'leader';
  return 'member';
}

// ---------------------------------------------------------------------------
// RoleLoader / Theme bootstrap
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

    try {
      final snap = await _db.collection('users').doc(user.uid).get();
      final data = snap.data() ?? const <String, dynamic>{};
      final effectiveRole = _resolveRoleFromUserData(data);

      if (!mounted) return;
      Provider.of<ThemeProvider>(context, listen: false).setRole(effectiveRole);
    } catch (e) {
      debugPrint('[RoleLoader] Failed to load theme role: $e');
    }
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

// ---------------------------------------------------------------------------
// RoleGate – decides which dashboard/home to show
// ---------------------------------------------------------------------------

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

  bool _timeout() =>
      DateTime.now().difference(_start) > const Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _auth.userChanges(),
      builder: (context, authSnap) {
        // Not signed in → go to login
        if (authSnap.connectionState == ConnectionState.active &&
            !authSnap.hasData) {
          return LoginPage();
        }

        // Waiting for auth
        if (!authSnap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final uid = authSnap.data!.uid;

        // Listen to users/{uid} – backend keeps role in sync
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _db.collection('users').doc(uid).snapshots(),
          builder: (context, userSnap) {
            if (userSnap.hasError) {
              debugPrint('[RoleGate] user doc error: ${userSnap.error}');
              return const HomeDashboardPage();
            }

            if (userSnap.connectionState == ConnectionState.waiting) {
              if (_timeout()) return const HomeDashboardPage();
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

        final exists = userSnap.data?.exists ?? false;
        if (!exists) {
          return FutureBuilder<IdTokenResult>(
            future: _auth.currentUser?.getIdTokenResult(),
            builder: (context, claimSnap) {
              if (claimSnap.connectionState == ConnectionState.waiting) {
                if (_timeout()) return const HomeDashboardPage();
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              final claims = claimSnap.data?.claims ?? const <String, dynamic>{};
              final claimRole = _resolveRoleFromClaims(claims);
              switch (claimRole) {
                case 'admin':
                  return const AdminDashboardPage();
                case 'pastor':
                  return const PastorHomeDashboardPage();
                case 'leader':
                  return const AdminDashboardPage();
                default:
                  return const HomeDashboardPage();
              }
            },
          );
        }

            final data =
                userSnap.data?.data() ?? const <String, dynamic>{};
            final effectiveRole = _resolveRoleFromUserData(data);

            // Route by canonical role
            if (effectiveRole != 'member') {
              switch (effectiveRole) {
                case 'admin':
                  return const AdminDashboardPage();
                case 'pastor':
                  return const PastorHomeDashboardPage();
                case 'leader':
                  // Leaders share admin dashboard UI in your app
                  return const AdminDashboardPage();
                case 'usher':
                  return const UsherHomeDashboardPage();
                default:
                  return const HomeDashboardPage();
              }
            }

            return FutureBuilder<IdTokenResult>(
              future: _auth.currentUser?.getIdTokenResult(),
              builder: (context, claimSnap) {
                if (claimSnap.connectionState == ConnectionState.waiting) {
                  if (_timeout()) return const HomeDashboardPage();
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                final claims =
                    claimSnap.data?.claims ?? const <String, dynamic>{};
                final claimRole = _resolveRoleFromClaims(claims);
                switch (claimRole) {
                  case 'admin':
                    return const AdminDashboardPage();
                  case 'pastor':
                    return const PastorHomeDashboardPage();
                  case 'leader':
                    return const AdminDashboardPage();
                  default:
                    return const HomeDashboardPage();
                }
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
        builder: (_) => MembershipFormPage(
          selfSignup: true,
          prefillEmail: (args['email'] as String?)?.trim().toLowerCase(),
        ),
      );

    case '/admin-dashboard':
      return MaterialPageRoute(builder: (_) => const AdminDashboardPage());

    case '/pastor-dashboard':
      return MaterialPageRoute(
          builder: (_) => const PastorHomeDashboardPage());

    case '/usher-dashboard':
      return MaterialPageRoute(
          builder: (_) => const UsherHomeDashboardPage());

    case '/admin-upload':
      return MaterialPageRoute(builder: (_) => const AdminUploadPage());

    case '/forms':
      return MaterialPageRoute(builder: (_) => FormsPage());

    case '/events':
      return MaterialPageRoute(builder: (_) => const EventsPage());

    case '/register-member':
      return MaterialPageRoute(
          builder: (_) => const MembershipFormPage());

    case '/home-dashboard':
      return MaterialPageRoute(
          builder: (_) => const HomeDashboardPage());

    case '/giving':
      return MaterialPageRoute(builder: (_) => const GivingPage());

    case '/attendance':
      return MaterialPageRoute(
          builder: (_) => const AttendanceCheckInPage());

    case '/view-members':
      return MaterialPageRoute(
          builder: (_) => const ViewMembersPage());

    case '/follow-up':
      return MaterialPageRoute(builder: (_) => const FollowUpPage());

    case '/my-follow-up':
      return MaterialPageRoute(builder: (_) => const FollowUpPage());

    case '/post-announcements':
      return MaterialPageRoute(
          builder: (_) => PostAnnouncementsPage());

    case '/view-ministry':
      return MaterialPageRoute(builder: (_) => const MinistriesPage());

    case '/manage-prayer-requests':
      return MaterialPageRoute(
          builder: (_) => const PrayerRequestManagePage());

    case '/manage-baptism':
      return MaterialPageRoute(
          builder: (_) => const BaptismManagePage());

    case '/form-prayer-request':
      return MaterialPageRoute(
          builder: (_) => const PrayerRequestFormPage());

    case '/form-baptism-interest':
      return MaterialPageRoute(
          builder: (_) => const BaptismInterestFormPage());

    case '/uploadExcel':
      if (kReleaseMode) {
        return MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Center(
              child: Text('Excel import is disabled in release builds.'),
            ),
          ),
        );
      }
      return MaterialPageRoute(builder: (_) => const ExcelDatabaseUploader());

    case '/testadmin':
      if (kReleaseMode) {
        return MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Center(child: Text('Page not available in release builds.')),
          ),
        );
      }
      return MaterialPageRoute(builder: (_) => const DebugAdminSetterPage());

    case '/attendance-setup':
      return MaterialPageRoute(
          builder: (_) => const AttendanceSetupPage());

    case '/profile':
    // Your "My Profile" page (the HomePage we optimised earlier)
      return MaterialPageRoute(builder: (_) => HomePage());

    case '/success':
      return MaterialPageRoute(builder: (_) => const SuccessPage());

    case '/feedback':
      return MaterialPageRoute(builder: (_) => const FeedbackPage());

    default:
      return MaterialPageRoute(
        builder: (_) => const Scaffold(
          body: Center(child: Text('Page not found')),
        ),
      );
  }
}
