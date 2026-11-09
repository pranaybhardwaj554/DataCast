import 'dart:convert';
import 'dart:math';

/// Result of a PIN attempt.
sealed class AuthResult {
  const AuthResult();
}

class AuthGranted extends AuthResult {
  const AuthGranted(this.token);
  final String token;
}

class AuthDenied extends AuthResult {
  const AuthDenied(this.attemptsLeft);
  final int attemptsLeft;
}

class AuthLocked extends AuthResult {
  const AuthLocked(this.retryAfter);
  final Duration retryAfter;
}

class _Session {
  _Session(this.clientKey, this.lastSeen);
  String clientKey;
  DateTime lastSeen;
}

class _Failures {
  int count = 0;
  int lockouts = 0;
  DateTime? lockedUntil;
}

/// 4-digit PIN check, session tokens and brute-force protection.
///
/// A 4-digit PIN has only 10,000 combinations, so each client IP gets
/// [maxAttempts] tries before being locked out. Every further lockout doubles
/// the wait, starting at [baseLockout].
class PinAuth {
  PinAuth({
    String? pin,
    this.maxAttempts = 5,
    this.baseLockout = const Duration(seconds: 30),
    this.tokenIdleTimeout = const Duration(hours: 12),
    this.activeWindow = const Duration(seconds: 15),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    _pin = pin ?? generatePin(_random);
  }

  final int maxAttempts;
  final Duration baseLockout;
  final Duration tokenIdleTimeout;

  /// A client counts as "connected" if it made a request within this window.
  /// The web page sends a heartbeat (`/api/info`) every 5 s while open.
  final Duration activeWindow;
  final DateTime Function() _clock;
  final Random _random;

  late String _pin;
  final Map<String, _Session> _tokens = {};
  final Map<String, _Failures> _failures = {};

  /// Called whenever the set of connected clients may have changed.
  void Function()? onClientsChanged;

  String get pin => _pin;

  static String generatePin([Random? random]) {
    final r = random ?? Random.secure();
    return r.nextInt(10000).toString().padLeft(4, '0');
  }

  /// Sets a new PIN and signs out every client.
  void setPin(String pin) {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be 4 digits');
    }
    _pin = pin;
    revokeAll();
  }

  String regeneratePin() {
    setPin(generatePin(_random));
    return _pin;
  }

  void revokeAll() {
    _tokens.clear();
    _failures.clear();
    onClientsChanged?.call();
  }

  /// Signs out one client (e.g. it switched to another device).
  void revoke(String? token) {
    if (token == null) return;
    final before = connectedClients;
    _tokens.remove(token);
    if (connectedClients != before) onClientsChanged?.call();
  }

  AuthResult attempt(String clientKey, String? pin) {
    final now = _clock();
    final f = _failures.putIfAbsent(clientKey, _Failures.new);
    final lockedUntil = f.lockedUntil;
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      return AuthLocked(lockedUntil.difference(now));
    }
    if (pin != null && _constantTimeEquals(pin, _pin)) {
      _failures.remove(clientKey);
      final token = _newToken();
      final before = connectedClients;
      _tokens[token] = _Session(clientKey, now);
      if (connectedClients != before) onClientsChanged?.call();
      return AuthGranted(token);
    }
    f.count++;
    if (f.count >= maxAttempts) {
      final wait = baseLockout * (1 << min(f.lockouts, 10));
      f
        ..lockouts += 1
        ..count = 0
        ..lockedUntil = now.add(wait);
      return AuthLocked(wait);
    }
    return AuthDenied(maxAttempts - f.count);
  }

  /// Returns true and refreshes the token if it is valid.
  /// [clientKey] (the client's IP) is recorded so the same browser counts
  /// once in [connectedClients] even if it unlocked more than once.
  bool validate(String? token, [String? clientKey]) {
    if (token == null) return false;
    final session = _tokens[token];
    if (session == null) return false;
    final now = _clock();
    if (now.difference(session.lastSeen) > tokenIdleTimeout) {
      _tokens.remove(token);
      return false;
    }
    final before = connectedClients;
    session.lastSeen = now;
    if (clientKey != null) session.clientKey = clientKey;
    if (connectedClients != before) onClientsChanged?.call();
    return true;
  }

  /// Distinct clients (by IP) that made a request within [activeWindow].
  int get connectedClients {
    final now = _clock();
    return {
      for (final s in _tokens.values)
        if (now.difference(s.lastSeen) <= activeWindow) s.clientKey,
    }.length;
  }

  String _newToken() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
