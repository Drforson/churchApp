import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class RoleManagementPage extends StatefulWidget {
  const RoleManagementPage({super.key});

  @override
  State<RoleManagementPage> createState() => _RoleManagementPageState();
}

class _RoleManagementPageState extends State<RoleManagementPage> {
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  final _memberIdCtrl = TextEditingController();
  bool _saving = false;

  final Map<String, bool> _roles = {
    'admin': false,
    'pastor': false,
    'leader': false,
    'usher': false,
  };

  @override
  void dispose() {
    _memberIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final memberId = _memberIdCtrl.text.trim();
    if (memberId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a member ID.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final rolesAdd = _roles.entries.where((e) => e.value).map((e) => e.key).toList();
      final rolesRemove = _roles.entries.where((e) => !e.value).map((e) => e.key).toList();

      await _functions.httpsCallable('setMemberRoles').call({
        'memberIds': [memberId],
        'rolesAdd': rolesAdd,
        'rolesRemove': rolesRemove,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Roles updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Roles'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _memberIdCtrl,
            decoration: const InputDecoration(
              labelText: 'Member ID',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 16),
          ..._roles.keys.map(
            (role) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(role[0].toUpperCase() + role.substring(1)),
              value: _roles[role] == true,
              onChanged: (v) => setState(() => _roles[role] = v),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving...' : 'Save Roles'),
          ),
        ],
      ),
    );
  }
}
