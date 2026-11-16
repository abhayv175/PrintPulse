import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/api_config.dart';

export 'package:google_sign_in/google_sign_in.dart'
    show GoogleSignInAccount, GoogleSignInException, GoogleSignInExceptionCode;

/// Signature for mock Google account providers in widget and integration tests.
typedef TestGoogleAccountProvider = Future<GoogleSignInAccount?> Function();

/// Service managing Google OAuth authentication using google_sign_in v7.2+ singleton API.
class GoogleAuthService {
  static bool _isInitialized = false;
  static Completer<void>? _initCompleter;

  /// Optional test hook allowing automated widget tests to simulate Google account authentication.
  @visibleForTesting
  static TestGoogleAccountProvider? testAccountProvider;

  /// Optional test hook allowing automated tests to simulate returning a specific raw ID token.
  @visibleForTesting
  static String? testIdToken;

  /// Initializes the Google Sign-In singleton instance with the configured serverClientId.
  /// Guaranteed to execute exactly once.
  static Future<void> initialize({String? serverClientId}) async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      final clientId = (serverClientId ?? ApiConfig.googleWebClientId).trim();
      await GoogleSignIn.instance.initialize(
        serverClientId: clientId.isNotEmpty ? clientId : null,
      );
      _isInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Triggers interactive Google authentication flow and returns the authenticated GoogleSignInAccount.
  static Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const <String>[],
  }) async {
    if (testAccountProvider != null) {
      final mockAccount = await testAccountProvider!();
      if (mockAccount != null) {
        return mockAccount;
      }
    }

    await initialize();
    return await GoogleSignIn.instance.authenticate(scopeHint: scopeHint);
  }

  /// Extracts the Google ID token for backend OAuth verification.
  static Future<String> authenticateAndGetIdToken() async {
    if (testIdToken != null && testIdToken!.isNotEmpty) {
      return testIdToken!;
    }

    final GoogleSignInAccount account = await authenticate();
    final String? idToken = account.authentication.idToken;

    if (idToken == null || idToken.trim().isEmpty) {
      throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
        description: 'No Google ID token returned from authentication.',
      );
    }

    return idToken.trim();
  }

  /// Signs out of the Google session across the app.
  static Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('Warning: GoogleSignIn.signOut error: $e');
    }
  }

  /// Resets initialization state (primarily for automated test tearDown).
  @visibleForTesting
  static void resetForTesting() {
    _isInitialized = false;
    _initCompleter = null;
    testAccountProvider = null;
    testIdToken = null;
  }
}
