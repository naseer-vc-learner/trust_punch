import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PinResult { ok, wrong, lockedOut }

/// Puts the screens that decide who can punch, and where, behind a
/// supervisor PIN: workers, sites, the phone's mode, and deleting history.
///
/// On a shared gate phone, anyone holding it could otherwise delete a worker
/// or move a site. This stops that casual misuse. It does not stop someone
/// with root access to the app's files, because the rest of the data sits in
/// plain shared_preferences as well; the enterprise edition moves both into
/// encrypted, hardware-keyed storage.
class SupervisorLock {
  SupervisorLock._(this._prefs);

  static Future<SupervisorLock> load() async =>
      SupervisorLock._(await SharedPreferences.getInstance());

  static const _hashKey = 'supervisorPinHash';
  static const _saltKey = 'supervisorPinSalt';
  static const _failsKey = 'supervisorPinFails';
  static const _lockedUntilKey = 'supervisorPinLockedUntil';

  static const minLength = 4;
  static const maxLength = 8;

  /// Wrong guesses allowed before the lock starts making people wait.
  static const freeTries = 5;

  /// Hash rounds. A 4–8 digit PIN cannot survive an offline brute force
  /// however it is hashed, so the lockout below is the real control; hashing
  /// keeps the PIN itself unreadable, since people reuse PINs elsewhere.
  static const _rounds = 20000;

  final SharedPreferences _prefs;

  /// True while someone who entered the PIN is in the supervisor role, so
  /// the screens inside it do not ask again. Kept in memory only: a restart
  /// always starts locked.
  bool _session = false;

  bool get sessionActive => _session;

  void beginSession() => _session = true;

  void endSession() => _session = false;

  bool get hasPin => _prefs.getString(_hashKey) != null;

  int get triesLeft => max(0, freeTries - (_prefs.getInt(_failsKey) ?? 0));

  /// How long until another guess is accepted; zero when not locked.
  Duration get lockedFor {
    final until = _prefs.getInt(_lockedUntilKey);
    if (until == null) return Duration.zero;
    final left =
        DateTime.fromMillisecondsSinceEpoch(until).difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  static bool isValidFormat(String pin) =>
      pin.length >= minLength &&
      pin.length <= maxLength &&
      RegExp(r'^\d+$').hasMatch(pin);

  Future<void> setPin(String pin) async {
    if (!isValidFormat(pin)) {
      throw ArgumentError('PIN must be $minLength–$maxLength digits');
    }
    final salt = _randomSalt();
    await _prefs.setString(_saltKey, salt);
    await _prefs.setString(_hashKey, _hash(pin, salt));
    await _clearFails();
  }

  /// Checks [pin]. After [freeTries] wrong guesses each further wrong guess
  /// locks the PIN: 30 s first, doubling each time, capped at 32 minutes.
  /// The count survives an app restart, so killing the app does not reset it.
  Future<PinResult> verify(String pin) async {
    if (lockedFor > Duration.zero) return PinResult.lockedOut;

    final salt = _prefs.getString(_saltKey);
    final stored = _prefs.getString(_hashKey);
    if (salt == null || stored == null) return PinResult.wrong;

    if (_constantTimeEquals(_hash(pin, salt), stored)) {
      await _clearFails();
      return PinResult.ok;
    }

    final fails = (_prefs.getInt(_failsKey) ?? 0) + 1;
    await _prefs.setInt(_failsKey, fails);
    if (fails < freeTries) return PinResult.wrong;

    final wait = Duration(seconds: 30 * (1 << min(fails - freeTries, 6)));
    await _prefs.setInt(
      _lockedUntilKey,
      DateTime.now().add(wait).millisecondsSinceEpoch,
    );
    return PinResult.lockedOut;
  }

  Future<void> _clearFails() async {
    await _prefs.remove(_failsKey);
    await _prefs.remove(_lockedUntilKey);
  }

  static String _randomSalt() {
    final random = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  static String _hash(String pin, String salt) {
    final saltBytes = utf8.encode(salt);
    var digest = sha256.convert([...saltBytes, ...utf8.encode(pin)]).bytes;
    for (var i = 1; i < _rounds; i++) {
      digest = sha256.convert([...digest, ...saltBytes]).bytes;
    }
    return base64Encode(digest);
  }

  /// Compares without stopping at the first difference, so response time
  /// does not reveal how much of a guess was right.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
