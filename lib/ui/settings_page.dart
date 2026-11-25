import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/session_auth.dart';
import '../state/account_store.dart';
import '../state/device_store.dart';
import '../update/app_channel.dart';
import '../update/update_prompt.dart';
import 'about_page.dart';
import 'login_page.dart' show runLoginFlowForHost;
import 'theme.dart';
import 'ui_settings.dart';
import 'usage_stats_page.dart';

/// App settings: theme, language, native-list switch, user management
/// (multi-account), plus links to usage stats and about.
class SettingsPage extends StatefulWidget {
  final DeviceStore store;
  final AccountStore accounts;
  final ThemeController theme;
  final UiSettings ui;
  const SettingsPage({
    super.key,
    required this.store,
    required this.accounts,
    required this.theme,
    required this.ui,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _checking = false;

  /// Per-account login states, refreshed after every action and re-entry.
  Map<String, bool> _loginStates = {};
  int _loginStatesEpoch = 0;

  @override
  void initState() {
    super.initState();
    _refreshLoginStates();
  }

  Future<void> _refreshLoginStates() async {
    final epoch = ++_loginStatesEpoch;
    final states = <String, bool>{};
    for (final account in widget.accounts.accounts) {
      states[account.id] = await sessionAuth.hasSessionForAccount(account.id);
    }
    if (!mounted || epoch != _loginStatesEpoch) return;
    setState(() => _loginStates = states);
  }

  /// Adds a user: official-page login for [host]; the captured JWT becomes
  /// a new (or updated) account and is set current.
  Future<void> _addUser(BuildContext context,
      {String host = 'zcode.z.ai'}) async {
    ZicAccount? created;
    final ok = await runLoginFlowForHost(
      context,
      host,
      onSaveJwt: (jwt) async {
        created = await widget.accounts.upsertFromLogin(host: host, jwt: jwt);
      },
    );
    if (!ok || !mounted) return;
    final newAccount = created;
    if (newAccount != null) {
      await widget.accounts.setCurrent(newAccount.id);
    }
    await _refreshLoginStates();
    if (!mounted) return;
    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
        content: Text(tr(this.context, 'auth.logged-in'))));
  }

  /// Per-account sign-out: drops ONLY that account's credentials (the
  /// account record and its devices stay; re-login restores the session).
  Future<void> _logoutAccount(
      BuildContext context, ZicAccount account) async {
    await sessionAuth.clearAccount(account.id);
    try {
      await CookieManager.instance()
          .deleteCookies(url: WebUri('https://${account.host}'));
    } catch (_) {}
    await _refreshLoginStates();
    if (!mounted) return;
    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
        content: Text(tr(this.context, 'accounts.loggedOut'))));
  }

  Future<void> _renameAccount(
      BuildContext context, ZicAccount account) async {
    final controller = TextEditingController(text: account.label);
    final label = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(c, 'accounts.rename.title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(hintText: tr(c, 'accounts.rename.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(c, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(c, 'devices.rename.save'))),
        ],
      ),
    );
    if (label != null) await widget.accounts.rename(account.id, label);
  }

  /// Removes the account record + its credentials. Devices owned by it are
  /// re-homed to the first remaining account (they stay visible either way
  /// — ownership is attribution, not a permission).
  Future<void> _deleteAccount(
      BuildContext context, ZicAccount account) async {
    final owned = widget.store.devices
        .where((d) => d.ownerAccountId == account.id)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(c, 'accounts.delete.title')),
        content: Text(trP(c, 'accounts.delete.body', ['$owned'])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(c, 'devices.add.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(c, 'accounts.delete.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final remaining = widget.accounts.accounts
        .where((a) => a.id != account.id)
        .toList();
    await widget.store.reassignOwner(
        account.id, remaining.isEmpty ? null : remaining.first.id);
    await widget.accounts.remove(account.id);
    await _refreshLoginStates();
    if (!mounted) return;
    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
        content: Text(tr(this.context, 'accounts.removed'))));
  }

  /// Store builds open their listing. The github build checks the pinned
  /// repository and offers a browser download. The app never installs an APK.
  Future<void> _checkForUpdates() async {
    if (_checking) return;
    final storeUrl = storeListingUrl;
    if (storeUrl != null) {
      await launchUrl(storeUrl, mode: LaunchMode.externalApplication);
      return;
    }
    if (appChannel == 'appstore') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'update.storePending'))));
      return;
    }
    setState(() => _checking = true);
    try {
      await presentGithubUpdate(context, silent: false);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ui = widget.ui;
    final accounts = widget.accounts.accounts;
    final currentId = widget.accounts.current?.id;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'settings.title'))),
      body: AnimatedBuilder(
        animation: Listenable.merge([theme, ui, widget.accounts]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _header(context, tr(context, 'settings.appearance')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(tr(context, 'settings.theme')),
                  const Spacer(),
                  SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(tr(context, 'settings.theme.dark')),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text(tr(context, 'settings.theme.light')),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(tr(context, 'settings.theme.system')),
                      ),
                    ],
                    selected: {theme.mode},
                    onSelectionChanged: (s) => theme.setMode(s.first),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ),
            _header(context, tr(context, 'settings.general')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(tr(context, 'settings.language')),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'zh-CN',
                        label: Text(tr(context, 'settings.language.zh')),
                      ),
                      ButtonSegment(
                        value: 'en-US',
                        label: Text(tr(context, 'settings.language.en')),
                      ),
                    ],
                    selected: {ui.locale},
                    onSelectionChanged: (s) => ui.setLocale(s.first),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.list_alt_outlined),
              title: Text(tr(context, 'settings.nativeList')),
              subtitle: Text(tr(context, 'settings.nativeListHint')),
              value: ui.nativeListEnabled,
              onChanged: (v) => ui.setNativeListEnabled(v),
            ),
            _header(context, tr(context, 'settings.users')),
            if (accounts.isEmpty)
              ListTile(
                leading: const Icon(Icons.person_add_alt_outlined),
                title: Text(tr(context, 'accounts.add')),
                subtitle: Text(tr(context, 'accounts.empty')),
                onTap: () => _addUser(context),
              )
            else ...[
              for (final account in accounts)
                ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        Theme.of(context).colorScheme.primary,
                    child: Text(
                      account.label.isEmpty
                          ? '?'
                          : account.label[0].toUpperCase(),
                      style: TextStyle(
                          fontSize: 13,
                          color:
                              Theme.of(context).colorScheme.onPrimary),
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(account.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (account.id == currentId) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(tr(context, 'accounts.current'),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary)),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      account.host,
                      if (account.identity != null && account.identity!.isNotEmpty)
                        account.identity!,
                      _loginStates[account.id] == true
                          ? tr(context, 'auth.logged-in')
                          : tr(context, 'auth.not-logged-in'),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'current') {
                        widget.accounts.setCurrent(account.id);
                      }
                      if (v == 'rename') _renameAccount(context, account);
                      if (v == 'logout') _logoutAccount(context, account);
                      if (v == 'delete') _deleteAccount(context, account);
                    },
                    itemBuilder: (c) => [
                      if (account.id != currentId)
                        PopupMenuItem(
                            value: 'current',
                            child: Text(tr(c, 'accounts.set-current'))),
                      PopupMenuItem(
                          value: 'rename',
                          child: Text(tr(c, 'accounts.rename'))),
                      if (_loginStates[account.id] == true)
                        PopupMenuItem(
                            value: 'logout',
                            child: Text(tr(c, 'accounts.logout'))),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(tr(c, 'accounts.delete'),
                            style: TextStyle(
                                color: Theme.of(c).colorScheme.error)),
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.person_add_alt_outlined),
                title: Text(tr(context, 'accounts.add')),
                subtitle: Text(tr(context, 'accounts.addHint')),
                onTap: () => _addUser(context),
              ),
            ],
            _header(context, tr(context, 'settings.notifications')),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: Text(tr(context, 'settings.notifications')),
              subtitle: Text(tr(context, 'settings.notificationsHint')),
              value: ui.notificationsEnabled,
              onChanged: (v) => ui.setNotificationsEnabled(v),
            ),
            if (ui.notificationsEnabled) ...[
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                dense: true,
                title: Text(tr(context, 'settings.notify.tasks')),
                value: ui.notifyTasksEnabled,
                onChanged: (v) => ui.setNotifyTasksEnabled(v),
              ),
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                dense: true,
                title: Text(tr(context, 'settings.notify.offPeak')),
                value: ui.notifyOffPeakEnabled,
                onChanged: (v) => ui.setNotifyOffPeakEnabled(v),
              ),
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                dense: true,
                title: Text(tr(context, 'settings.notify.auto')),
                value: ui.notifyAutoEnabled,
                onChanged: (v) => ui.setNotifyAutoEnabled(v),
              ),
            ],
            _header(context, tr(context, 'settings.data')),
            ListTile(
              leading: const Icon(Icons.bar_chart_outlined),
              title: Text(tr(context, 'settings.usageStats')),
              subtitle: Text(tr(context, 'settings.usageStatsHint')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    UsageStatsPage(store: widget.store, ui: widget.ui),
              )),
            ),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: Text(tr(context, 'settings.checkUpdate')),
              trailing: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: _checkForUpdates,
            ),
            _header(context, tr(context, 'settings.about')),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tr(context, 'settings.about')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AboutPage(),
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: ZInk.muted(context),
          ),
        ),
      );
}
