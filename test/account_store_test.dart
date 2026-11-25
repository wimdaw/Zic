import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zic/auth/session_auth.dart';
import 'package:zic/state/account_store.dart';
import 'package:zic/state/app_kv.dart';
import 'package:zic/state/device_store.dart';

/// Three-segment base64url token (shape-valid, unsigned — fine for the
/// identity parser and storage tests; nothing here verifies signatures).
String fakeJwt({String? sub, String? name, Map<String, Object?>? extra}) {
  String enc(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${enc({'sub': sub, 'name': name, ...?extra})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppKv.instance.debugReset();
    SharedPreferences.setMockInitialValues({});
  });

  group('jwtIdentity', () {
    test('extracts subject and label', () {
      final id = jwtIdentity(fakeJwt(sub: 'u-123', name: '阿明'));
      expect(id.subject, 'u-123');
      expect(id.label, '阿明');
      expect(id.identity, '阿明');
    });

    test('identity prefers email, then username, then a short subject', () {
      expect(
        jwtIdentity(fakeJwt(
                sub: 'u-1', name: '阿明', extra: {'email': 'a@b.com'}))
            .identity,
        'a@b.com',
      );
      expect(
        jwtIdentity(fakeJwt(sub: 'a-very-long-subject-uuid-0001')).identity,
        '…uid-0001', // last 8 chars, ellipsis-prefixed
      );
    });

    test('tolerates junk input', () {
      expect(jwtIdentity('not-a-jwt').subject, isNull);
      expect(jwtIdentity('a.b.c').subject, isNull);
      expect(jwtIdentity(fakeJwt(name: 'no-sub')).subject, isNull);
    });
  });

  group('AccountStore', () {
    test('migrates legacy host-keyed logins into accounts', () async {
      const host = 'zcode.z.ai';
      final jwt = fakeJwt(sub: 'u-1', name: '默认用户');
      await AppKv.instance.open();
      await AppKv.instance.setString('zic.auth.jwt.$host', jwt);

      final accounts = AccountStore();
      await accounts.load();

      expect(accounts.length, 1);
      expect(accounts.current!.host, host);
      expect(accounts.current!.subject, 'u-1');
      expect(accounts.current!.label, '默认用户');
      // Credential re-homed under the account scope.
      expect(await sessionAuth.jwtForAccount(accounts.current!.id), jwt);
    });

    test('upsertFromLogin updates the same identity, adds new ones',
        () async {
      final accounts = AccountStore();
      await accounts.load();
      final a1 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));
      final a1b = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));
      final a2 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-2', name: '小张'));

      expect(a1.id, a1b.id);
      expect(a2.id, isNot(a1.id));
      expect(accounts.length, 2);
      // The latest login becomes current (new devices default to it).
      expect(accounts.current!.id, a2.id);
    });

    test('setCurrent and rename', () async {
      final accounts = AccountStore();
      await accounts.load();
      final a1 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));
      final a2 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-2', name: '小张'));

      await accounts.setCurrent(a1.id);
      expect(accounts.current!.id, a1.id);
      await accounts.rename(a1.id, '明哥');
      expect(accounts.byId(a1.id)!.label, '明哥');
      expect(accounts.current!.id, a1.id);
      expect(a2.id, isNot(a1.id));
    });

    test('remove clears the credentials and drops the record', () async {
      final accounts = AccountStore();
      await accounts.load();
      final a1 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));
      expect(await sessionAuth.jwtForAccount(a1.id), isNotNull);

      await accounts.remove(a1.id);
      expect(accounts.length, 0);
      expect(accounts.current, isNull);
      expect(await sessionAuth.jwtForAccount(a1.id), isNull);
    });

    test('registry persists across instances', () async {
      final accounts = AccountStore();
      await accounts.load();
      final a1 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));

      final fresh = AccountStore();
      await fresh.load();
      expect(fresh.length, 1);
      expect(fresh.current!.id, a1.id);
      expect(fresh.current!.label, '阿明');
    });
  });

  group('migrateDeviceOwners', () {
    test('assigns ownerless devices by host, then current', () async {
      final accounts = AccountStore();
      await accounts.load();
      final a1 = await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));

      final store = DeviceStore();
      await store.load();
      await store.addUrl(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&name=one');
      await migrateDeviceOwners(store, accounts);
      expect(store.devices.single.ownerAccountId, a1.id);

      // Idempotent: a second pass changes nothing.
      await migrateDeviceOwners(store, accounts);
      expect(store.devices.single.ownerAccountId, a1.id);
    });

    test('keeps an explicit owner untouched', () async {
      final accounts = AccountStore();
      await accounts.load();
      await accounts.upsertFromLogin(
          host: 'zcode.z.ai', jwt: fakeJwt(sub: 'u-1', name: '阿明'));

      final store = DeviceStore();
      await store.load();
      final d = await store.addUrl(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1&name=one',
          ownerAccountId: 'acct-explicit');
      await migrateDeviceOwners(store, accounts);
      expect(store.devices.firstWhere((x) => x.id == d.id).ownerAccountId,
          'acct-explicit');
    });
  });
}
