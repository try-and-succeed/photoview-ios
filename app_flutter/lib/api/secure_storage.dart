import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage shared by everything that keeps credentials.
///
/// Two plugin defaults are deliberately overridden so that saved sign-ins
/// survive app updates:
///
/// `resetOnError` defaults to true, which — in the plugin's own words —
/// "will PERMANENTLY erase the data when an error occurs". That includes
/// transient failures such as the Android Keystore not being ready yet
/// shortly after boot, so a single hiccup would throw away every remembered
/// server. Errors are surfaced and handled by the callers instead.
///
/// `migrateWithBackup` keeps a recoverable copy while the plugin re-encrypts
/// data after an algorithm change, so an upgrade interrupted part-way through
/// can still be recovered.
const photoviewSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
);
