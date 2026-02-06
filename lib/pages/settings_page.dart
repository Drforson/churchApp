import 'package:flutter/material.dart';

import 'package:church_management_app/widgets/notification_settings_panel.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: const [
            NotificationSettingsPanel(),
          ],
        ),
      ),
    );
  }
}
