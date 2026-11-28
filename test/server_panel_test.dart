import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/connected/device_token.dart';
import 'package:trust_punch/src/connected/punch_sync.dart';
import 'package:trust_punch/src/connected/server_api.dart';
import 'package:trust_punch/src/connected/server_panel.dart';
import 'package:trust_punch/src/services/supervisor_lock.dart';
import 'package:trust_punch/src/store/attendance_store.dart';

/// Answers without a network, so the widget test stays in fake time.
class _InstantApi extends ServerApi {
  _InstantApi() : super(baseUrl: Uri.parse('http://127.0.0.1:1'));

  String? pairedWith;

  @override
  Future<ServerHealth> health() async => ServerHealth.failed('offline test');

  @override
  Future<(String, String)> pair({
    required String code,
    required String deviceName,
    required String platform,
  }) async {
    if (code != '123456') {
      throw const ServerException(ServerProblem.refused, 'Code not valid');
    }
    pairedWith = deviceName;
    return ('d1', 'token');
  }
}

void main() {
  late AttendanceStore store;
  late SupervisorLock lock;
  late _InstantApi api;
  late PunchSync sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AttendanceStore.load();
    lock = await SupervisorLock.load();
    api = _InstantApi();
    sync = PunchSync(store: store, api: api, tokens: MemoryTokenStore());
  });

  Future<void> openPairing(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [ServerPanel(sync: sync, store: store, lock: lock)],
        ),
      ),
    ));
    await tester.tap(find.textContaining('not paired'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair with server'));
    await tester.pumpAndSettle();
  }

  testWidgets('pairing closes cleanly and the line updates', (tester) async {
    await openPairing(tester);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.enterText(find.byType(TextField).last, 'Gate A phone');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    // Through the whole closing animation: the bug threw here.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(api.pairedWith, 'Gate A phone');
    expect(sync.paired, isTrue);
    expect(find.descendant(
        of: find.byType(SnackBar), matching: find.text('Paired')),
        findsOneWidget);
    expect(find.text('Unpair this phone'), findsOneWidget);
  });

  testWidgets('cancel and a wrong code close cleanly too', (tester) async {
    await openPairing(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Pair with server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '000000');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sync.paired, isFalse);
    expect(find.text('Code not valid — ask for a new one'), findsOneWidget);
  });
}
