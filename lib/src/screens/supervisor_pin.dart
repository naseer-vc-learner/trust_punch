import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/ui_text.dart';
import '../services/supervisor_lock.dart';

/// Asks for the supervisor PIN before a protected screen or action.
///
/// The first time, there is no PIN yet, so this asks the supervisor to set
/// one instead. Inside an open supervisor session it passes straight
/// through. Returns true only when the action may go ahead.
Future<bool> requireSupervisor(
  BuildContext context,
  SupervisorLock lock,
  String lang,
) async {
  if (lock.sessionActive) return true;
  if (!lock.hasPin) {
    final pin = await _askNewPin(context, lang, t(lang, T.setSupervisorPin));
    if (pin == null) return false;
    await lock.setPin(pin);
    return true;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _EnterPinDialog(lock: lock, lang: lang),
  );
  return ok ?? false;
}

/// Replaces the PIN. Only offered from inside a screen the PIN already
/// unlocked, so it does not ask for the old one again.
Future<bool> changeSupervisorPin(
  BuildContext context,
  SupervisorLock lock,
  String lang,
) async {
  final pin = await _askNewPin(context, lang, t(lang, T.changePin));
  if (pin == null) return false;
  await lock.setPin(pin);
  return true;
}

Future<String?> _askNewPin(BuildContext context, String lang, String title) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NewPinDialog(lang: lang, title: title),
    );

TextField _pinField(
  TextEditingController controller,
  String label, {
  bool autofocus = false,
  String? error,
  ValueChanged<String>? onSubmitted,
}) =>
    TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(SupervisorLock.maxLength),
      ],
      decoration: InputDecoration(labelText: label, errorText: error),
      onSubmitted: onSubmitted,
    );

class _EnterPinDialog extends StatefulWidget {
  const _EnterPinDialog({required this.lock, required this.lang});

  final SupervisorLock lock;
  final String lang;

  @override
  State<_EnterPinDialog> createState() => _EnterPinDialogState();
}

class _EnterPinDialogState extends State<_EnterPinDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Already locked from an earlier attempt: say so before they type.
    if (widget.lock.lockedFor > Duration.zero) _error = _lockedMessage();
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  String _lockedMessage() => t(widget.lang, T.pinLocked)
      .replaceAll('{s}', '${widget.lock.lockedFor.inSeconds + 1}');

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await widget.lock.verify(_pin.text);
    if (!mounted) return;
    if (result == PinResult.ok) {
      Navigator.pop(context, true);
      return;
    }
    _pin.clear();
    setState(() {
      _busy = false;
      _error = result == PinResult.lockedOut
          ? _lockedMessage()
          : t(widget.lang, T.wrongPin)
              .replaceAll('{n}', '${widget.lock.triesLeft}');
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t(widget.lang, T.enterSupervisorPin)),
      content: _pinField(
        _pin,
        t(widget.lang, T.enterSupervisorPin),
        autofocus: true,
        error: _error,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(t(widget.lang, T.cancel)),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(t(widget.lang, T.unlock)),
        ),
      ],
    );
  }
}

class _NewPinDialog extends StatefulWidget {
  const _NewPinDialog({required this.lang, required this.title});

  final String lang;
  final String title;

  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  final _pin = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _save() {
    final pin = _pin.text;
    if (!SupervisorLock.isValidFormat(pin)) {
      setState(() => _error = t(widget.lang, T.pinFormat));
      return;
    }
    if (pin != _repeat.text) {
      setState(() => _error = t(widget.lang, T.pinMismatch));
      return;
    }
    Navigator.pop(context, pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pinField(_pin, t(widget.lang, T.newPin), autofocus: true),
          const SizedBox(height: 12),
          _pinField(
            _repeat,
            t(widget.lang, T.confirmPin),
            error: _error,
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(widget.lang, T.cancel)),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(t(widget.lang, T.save)),
        ),
      ],
    );
  }
}
