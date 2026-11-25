import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trust_punch/src/services/supervisor_lock.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no PIN until one is set', () async {
    final lock = await SupervisorLock.load();
    expect(lock.hasPin, isFalse);
    await lock.setPin('4821');
    expect(lock.hasPin, isTrue);
  });

  test('the PIN itself is never stored', () async {
    final lock = await SupervisorLock.load();
    await lock.setPin('4821');
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect('${prefs.get(key)}'.contains('4821'), isFalse, reason: key);
    }
  });

  test('right PIN opens, wrong PIN does not', () async {
    final lock = await SupervisorLock.load();
    await lock.setPin('4821');
    expect(await lock.verify('0000'), PinResult.wrong);
    expect(await lock.verify('4821'), PinResult.ok);
  });

  test('rejects PINs that are too short, too long or not digits', () async {
    final lock = await SupervisorLock.load();
    for (final bad in ['123', '123456789', '12a4', '']) {
      expect(() => lock.setPin(bad), throwsArgumentError, reason: bad);
    }
  });

  test('locks after five wrong tries, even against the right PIN', () async {
    final lock = await SupervisorLock.load();
    await lock.setPin('4821');
    for (var i = 0; i < SupervisorLock.freeTries - 1; i++) {
      expect(await lock.verify('0000'), PinResult.wrong);
    }
    expect(lock.triesLeft, 1);
    expect(await lock.verify('0000'), PinResult.lockedOut);
    expect(lock.lockedFor, greaterThan(Duration.zero));
    expect(await lock.verify('4821'), PinResult.lockedOut);
  });

  test('the lockout survives an app restart', () async {
    final first = await SupervisorLock.load();
    await first.setPin('4821');
    for (var i = 0; i < SupervisorLock.freeTries; i++) {
      await first.verify('0000');
    }
    final afterRestart = await SupervisorLock.load();
    expect(afterRestart.lockedFor, greaterThan(Duration.zero));
  });

  test('a right PIN resets the wrong-try count', () async {
    final lock = await SupervisorLock.load();
    await lock.setPin('4821');
    await lock.verify('0000');
    await lock.verify('0000');
    await lock.verify('4821');
    expect(lock.triesLeft, SupervisorLock.freeTries);
  });
}
