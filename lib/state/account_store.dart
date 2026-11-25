import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../auth/session_auth.dart';
import '../protocol/id.dart';
import 'app_kv.dart';
import 'device_store.dart';

/// One logged-in ZCode account (multi-user support).
///
/// An account binds a login host to a stable identity (the JWT `sub`
/// claim). The JWT/cookie credentials themselves live in [SessionAuth]
/// under account-scoped keys — never in this registry — so the security
/// rules (app-private file, TLS-only, never logged) stay in one place.
class ZicAccount {
  final String id;

  /// Login host this account belongs to (e.g. `zcode.z.ai`).
  final String host;

  /// Stable identity from the JWT payload (`sub`/`uid`). Two logins with
  /// the same host+subject are the same account; a different subject on
  /// the same host is a different account.
  final String? subject;

  /// Display name (JWT name/email claim, else a fallback).
  String label;
  final int createdAt;

  ZicAccount({
    required this.id,
    required this.host,
    this.subject,
    required this.label,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        if (subject != null) 'subject': subject,
        'label': label,
        'createdAt': createdAt,
      };

  factory ZicAccount.fromJson(Map<String, dynamic> j) => ZicAccount(
        id: j['id'] as String? ?? generateUuid(),
        host: j['host'] as String? ?? 'zcode.z.ai',
        subject: j['subject'] as String?,
        label: j['label'] as String? ?? '默认用户',
        createdAt: j['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      );
}

/// Registry of accounts + the "current account" pointer. New devices are
/// owned by [current]; every device carries its owner's account id and
/// dials with that account's credentials (see main.dart's relay providers).
class AccountStore extends ChangeNotifier {
  static const _key = 'zic_accounts_v1';
  static const _currentKey = 'zic_current_account_v1';

  final List<ZicAccount> _accounts = [];
  String? _currentId;
  bool _loaded = false;

  bool get loaded => _loaded;
  List<ZicAccount> get accounts => List.unmodifiable(_accounts);
  int get length => _accounts.length;

  /// Test seam: inject accounts without any login/storage round-trip.
  @visibleForTesting
  void debugSeedForTesting(
      List<({String id, String host, String label})> seed) {
    _accounts
      ..clear()
      ..addAll(seed
          .map((e) => ZicAccount(
                id: e.id,
                host: e.host,
                label: e.label,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              )));
    _currentId = _accounts.isEmpty ? null : _accounts.first.id;
    _loaded = true;
    notifyListeners();
  }

  /// The pointer for NEW devices / default login target. Falls back to the
  /// first account so a stale id can never leave the app ownerless.
  ZicAccount? get current => byId(_currentId) ?? (_accounts.isEmpty ? null : _accounts.first);

  ZicAccount? byId(String? id) =>
      id == null ? null : _accounts.where((a) => a.id == id).firstOrNull;

  /// First account on [host] (migration / single-account fallback).
  ZicAccount? byHost(String host) =>
      _accounts.where((a) => a.host == host).firstOrNull;

  Future<void> load() async {
    if (_loaded) return;
    try {
      await AppKv.instance.open();
      final raw = await AppKv.instance.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _accounts
          ..clear()
          ..addAll(list
              .whereType<Map>()
              .map((e) => ZicAccount.fromJson(Map<String, dynamic>.from(e)))
              .where((a) => a.host.isNotEmpty));
        _currentId = await AppKv.instance.getString(_currentKey);
      } else {
        // First run after the multi-user upgrade: lift the legacy
        // host-keyed logins into accounts (default user), then persist.
        await _migrateLegacy();
      }
    } catch (_) {
      // Degraded storage: keep whatever loaded; the app stays usable.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Legacy `zic.auth.jwt.<host>` keys → one account per host, credentials
  /// re-homed under account-scoped keys. Legacy keys are kept (harmless,
  /// and the dial path still reads them as a fallback).
  Future<void> _migrateLegacy() async {
    try {
      final hosts = await sessionAuth.legacyJwtHosts();
      for (final host in hosts) {
        final jwt = await sessionAuth.jwtFor(host);
        if (jwt == null || jwt.isEmpty) continue;
        final identity = jwtIdentity(jwt);
        final account = ZicAccount(
          id: generateUuid(),
          host: host,
          subject: identity.subject,
          label: identity.label ?? '默认用户',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        _accounts.add(account);
        await sessionAuth.saveJwtForAccount(account.id, jwt);
        final cookie = await sessionAuth.legacyCookieFor(host);
        if (cookie != null && cookie.isNotEmpty) {
          await sessionAuth.saveCookieForAccount(account.id, cookie);
        }
      }
      if (_accounts.isNotEmpty) {
        _currentId = _accounts.first.id;
        await _save();
      }
    } catch (_) {
      // Migration is best-effort; the legacy fallback path still works.
    }
  }

  /// Serializes disk writes (same discipline as DeviceStore).
  Future<void> _diskQueue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _diskQueue.then((_) => action());
    _diskQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _save() {
    return _serialized(() async {
      try {
        await AppKv.instance
            .setString(_key, jsonEncode(_accounts.map((a) => a.toJson()).toList()));
        if (_currentId != null) {
          await AppKv.instance.setString(_currentKey, _currentId!);
        } else {
          await AppKv.instance.remove(_currentKey);
        }
      } catch (_) {
        // Degraded storage: memory still carries the registry.
      }
    });
  }

  /// Login result: same host+subject updates in place, a different subject
  /// (or a fresh host) creates a new account. Becomes the current account.
  Future<ZicAccount> upsertFromLogin({
    required String host,
    required String jwt,
    String? cookie,
  }) async {
    final identity = jwtIdentity(jwt);
    var account = identity.subject == null
        ? byHost(host)
        : _accounts
            .where((a) => a.host == host && a.subject == identity.subject)
            .firstOrNull;
    if (account == null) {
      account = ZicAccount(
        id: generateUuid(),
        host: host,
        subject: identity.subject,
        label: identity.label ?? '用户${_accounts.length + 1}',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _accounts.add(account);
    }
    if (identity.label != null && identity.label!.isNotEmpty) {
      account.label = identity.label!;
    }
    await sessionAuth.saveJwtForAccount(account.id, jwt);
    if (cookie != null && cookie.isNotEmpty) {
      await sessionAuth.saveCookieForAccount(account.id, cookie);
    }
    _currentId = account.id;
    await _save();
    notifyListeners();
    return account;
  }

  Future<void> setCurrent(String id) async {
    if (byId(id) == null || _currentId == id) return;
    _currentId = id;
    await _save();
    notifyListeners();
  }

  Future<void> rename(String id, String label) async {
    final account = byId(id);
    if (account == null) return;
    final next = label.trim();
    if (next.isEmpty || next == account.label) return;
    account.label = next;
    await _save();
    notifyListeners();
  }

  /// Removes the account record and its credentials. Devices owned by it
  /// are re-homed first (see [DeviceStore.reassignOwner] callers) — this
  /// method only handles the registry + credentials.
  Future<void> remove(String id) async {
    if (byId(id) == null) return;
    await sessionAuth.clearAccount(id);
    _accounts.removeWhere((a) => a.id == id);
    if (_currentId == id) {
      _currentId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    await _save();
    notifyListeners();
  }
}

/// Decoded identity claims from a ZCode JWT payload. Pure function.
class JwtIdentity {
  final String? subject;
  final String? label;
  const JwtIdentity({this.subject, this.label});
}

/// Extracts the stable subject (`sub`/`uid`) and a display label
/// (`name`/`nickname`/`email`/`username`) from the JWT payload without
/// verifying the signature — the JWT is only ever sent back to the host
/// that issued it, so this is labelling, not trust.
JwtIdentity jwtIdentity(String jwt) {
  try {
    final parts = jwt.split('.');
    if (parts.length < 2) return const JwtIdentity();
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return const JwtIdentity();
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final subject = str(decoded['sub']) ??
        str(decoded['uid']) ??
        str(decoded['user_id']) ??
        str(decoded['jti']);
    final label = str(decoded['name']) ??
        str(decoded['nickname']) ??
        str(decoded['email']) ??
        str(decoded['username']);
    return JwtIdentity(subject: subject, label: label);
  } catch (_) {
    return const JwtIdentity();
  }
}

/// One-time upgrade: devices saved before multi-user have no owner. Attach
/// each to the account on the same host, else the current account. Safe to
/// call on every startup — it no-ops once every device has an owner.
Future<void> migrateDeviceOwners(DeviceStore store, AccountStore accounts) async {
  if (!store.loaded || !accounts.loaded) return;
  for (final device in store.devices) {
    if (device.ownerAccountId != null) continue;
    final host = device.params?.source.host ?? '';
    final account = accounts.byHost(host) ?? accounts.current;
    if (account == null) continue;
    await store.assignOwner(device.id, account.id);
  }
}
