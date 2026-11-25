import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zic/main.dart';
import 'package:zic/state/account_store.dart';
import 'package:zic/state/app_kv.dart';
import 'package:zic/state/device_session.dart';
import 'package:zic/state/device_store.dart';
import 'package:zic/state/scheduled_store.dart';
import 'package:zic/ui/devices_page.dart';
import 'package:zic/ui/theme.dart';
import 'package:zic/ui/ui_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppKv.instance.debugReset();
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(DevicesPage page) => MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: page,
      );

  testWidgets('DevicesPage shows empty state with no devices',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => ui.nativeListEnabled);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      accounts: AccountStore(),
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
    )));
    await tester.pumpAndSettle();

    // Zic home: brand header title + empty state with scan/paste actions.
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('还没有设备'), findsOneWidget);
    expect(find.text('扫码添加'), findsOneWidget);
    expect(find.text('粘贴链接添加'), findsOneWidget);
  });

  testWidgets('DevicesPage renders a device card',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=dev-alpha&app_version=3.8.1');

    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => false);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      accounts: AccountStore(),
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('dev-alpha'), findsOneWidget);
    // Status and host share one caption line in the Zic card anatomy.
    expect(find.textContaining('zcode.z.ai'), findsWidgets);
    // No native connection is attempted with the switch off.
    expect(find.textContaining('离线'), findsOneWidget);
  });

  testWidgets('multi-account home shows owner badges and filters',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.load();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=aaa&hash=x&t=1&mid=m1&name=dev-alpha',
        ownerAccountId: 'acct-a');
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=bbb&hash=y&t=2&mid=m2&name=dev-beta',
        ownerAccountId: 'acct-b');

    final accounts = AccountStore();
    final theme = ThemeController();
    final ui = UiSettings();
    final hub = DeviceSessionHub(nativeListEnabled: () => false);
    await tester.pumpWidget(wrap(DevicesPage(
      store: store,
      accounts: accounts,
      theme: theme,
      ui: ui,
      hub: hub,
      scheduled: ScheduledStore(),
    )));
    await tester.pumpAndSettle();

    // The registry here is empty (raw owner ids), so no badges/filters:
    // badges only appear for accounts the store knows.
    expect(find.text('dev-alpha'), findsOneWidget);
    expect(find.text('dev-beta'), findsOneWidget);
    expect(find.text('全部设备'), findsNothing);

    // Seed two accounts and reload: badges + the 全部设备 filter appear.
    accounts.debugSeedForTesting([
      (id: 'acct-a', host: 'zcode.z.ai', label: '阿明'),
      (id: 'acct-b', host: 'zcode.z.ai', label: '小张'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('全部设备'), findsOneWidget);
    expect(find.text('阿明'), findsWidgets);
    expect(find.text('小张'), findsWidgets);

    // Tapping the 阿明 chip filters to that account's devices only.
    // (The same text also paints as the card's owner badge, so target the
    // chip widget, not the bare text.)
    await tester.tap(find.widgetWithText(FilterChip, '阿明'));
    await tester.pumpAndSettle();
    expect(find.text('dev-alpha'), findsOneWidget);
    expect(find.text('dev-beta'), findsNothing);

    // 全部 brings every device back (all devices always visible).
    await tester.tap(find.widgetWithText(FilterChip, '全部设备'));
    await tester.pumpAndSettle();
    expect(find.text('dev-alpha'), findsOneWidget);
    expect(find.text('dev-beta'), findsOneWidget);
  });

  testWidgets('App boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ZicApp());
    await tester.pumpAndSettle();
    expect(find.text('设备'), findsOneWidget);
  });
}
