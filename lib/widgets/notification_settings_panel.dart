import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class NotificationSettingsPanel extends StatefulWidget {
  final String title;
  const NotificationSettingsPanel({super.key, this.title = 'Notifications'});

  @override
  State<NotificationSettingsPanel> createState() =>
      _NotificationSettingsPanelState();
}

class _NotificationSettingsPanelState extends State<NotificationSettingsPanel> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _loading = false;
  String? _localToken;
  String? _serverToken;
  DateTime? _serverUpdatedAt;
  String? _permission;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _shortToken(String token) {
    if (token.length <= 12) return token;
    return '${token.substring(0, 6)}...${token.substring(token.length - 4)}';
  }

  Future<void> _load() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      final localToken = await messaging.getToken();

      final userRef = _db.collection('users').doc(user.uid);
      final userSnap = await userRef.get();
      final data = userSnap.data();
      final serverToken = (data?['fcmToken'] as String?)?.trim();
      final updatedAt = data?['fcmTokenUpdatedAt'] as Timestamp?;

      if (mounted) {
        setState(() {
          _localToken = localToken;
          _serverToken = serverToken;
          _serverUpdatedAt = updatedAt?.toDate();
          _permission = settings.authorizationStatus.name;
        });
      }

      final shouldSync =
          localToken != null && localToken.isNotEmpty && localToken != serverToken;
      if (shouldSync) {
        await userRef.set(
          {
            'fcmToken': localToken,
            'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        final refreshed = await userRef.get();
        final refreshedData = refreshed.data();
        if (mounted) {
          setState(() {
            _serverToken = (refreshedData?['fcmToken'] as String?)?.trim();
            _serverUpdatedAt =
                (refreshedData?['fcmTokenUpdatedAt'] as Timestamp?)?.toDate();
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLocal = _localToken != null && _localToken!.isNotEmpty;
    final hasServer = _serverToken != null && _serverToken!.isNotEmpty;
    final inSync = hasLocal && hasServer && _localToken == _serverToken;
    final statusColor = inSync ? Colors.green : Colors.orange;

    String statusText;
    if (_loading) {
      statusText = 'Checking…';
    } else if (_error != null && _error!.isNotEmpty) {
      statusText = 'Error';
    } else if (inSync) {
      statusText = 'Registered';
    } else if (hasLocal && !hasServer) {
      statusText = 'Local only';
    } else if (!hasLocal && hasServer) {
      statusText = 'Server only';
    } else {
      statusText = 'Missing';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(widget.title,
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_permission != null && _permission!.isNotEmpty)
            Text('Permission: $_permission',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            'Local token: ${hasLocal ? _shortToken(_localToken!) : 'none'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Server token: ${hasServer ? _shortToken(_serverToken!) : 'none'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_serverUpdatedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Server updated: ${DateFormat.yMd().add_jm().format(_serverUpdatedAt!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_error != null && _error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Colors.red.shade700, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: Text(_loading ? 'Checking...' : 'Refresh'),
            ),
          ),
        ],
      ),
    );
  }
}
