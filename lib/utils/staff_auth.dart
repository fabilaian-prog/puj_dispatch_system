import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result of a successful staff sign-in.
class StaffLogin {
  final String role;
  final String userDocId;
  final Map<String, dynamic> userData;
  const StaffLogin(this.role, this.userDocId, this.userData);
}

class StaffAuthException implements Exception {
  final String message;
  const StaffAuthException(this.message);
  @override
  String toString() => message;
}

/// Staff sign-in with Firebase Auth.
///
/// Staff still type a username and a PIN. The username is turned into the
/// hidden email "<username>@jeepes.ph" and the PIN is the Firebase password
/// (so PINs must be at least 6 digits).
///
/// Firestore collections used:
///   auth_roles/{firebaseUid}  -> { role, user_doc_id, username }
///   login_aliases/{username}  -> { email }   (only after a PIN reset, see resetPin)
///   users/{userDocId}         -> profile; gets auth_uid / auth_email fields
///
/// Save this file as lib/utils/staff_auth.dart
class StaffAuth {
  static const String domain = 'jeepes.ph';
  static const int minPinLength = 6;

  static FirebaseAuth get _auth => FirebaseAuth.instance;
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static String normalize(String username) =>
      username.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '.');

  static String defaultEmail(String username) => '${normalize(username)}@$domain';

  /// The Firebase email for a username (or a full email such as admin@jeepes.ph).
  static Future<String> emailFor(String input) async {
    final u = normalize(input);
    if (u.contains('@')) return u;
    try {
      final alias = await _db.collection('login_aliases').doc(u).get();
      final e = alias.data()?['email'];
      if (e is String && e.isNotEmpty) return e;
    } catch (_) {
      // No alias (normal case) or alias not readable: use the default email.
    }
    return '$u@$domain';
  }

  // ───────────────────────── sign in / session / sign out

  static Future<StaffLogin> signIn(String usernameOrEmail, String pin) async {
    final email = await emailFor(usernameOrEmail);
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: pin);
    return _loadProfile(cred.user!);
  }

  /// Returns the signed-in staff member after an app restart, or null.
  static Future<StaffLogin?> restoreSession() async {
    final user = await _auth.authStateChanges().first;
    if (user == null) return null;
    try {
      return await _loadProfile(user);
    } catch (_) {
      return null;
    }
  }

  static Future<StaffLogin> _loadProfile(User user) async {
    final roleDoc = await _db.collection('auth_roles').doc(user.uid).get();
    final m = roleDoc.data();
    if (m == null) {
      await signOut();
      throw const StaffAuthException(
          'This account has no role assigned yet. Please contact the Super Admin.');
    }
    final role = (m['role'] ?? '').toString().trim().toUpperCase();
    final docId = (m['user_doc_id'] ?? '').toString().trim();
    final userDoc = await _db.collection('users').doc(docId).get();
    if (!userDoc.exists || userDoc.data() == null) {
      await signOut();
      throw const StaffAuthException(
          'Your profile could not be found. Please contact the Super Admin.');
    }
    return StaffLogin(role, userDoc.id, userDoc.data()!);
  }

  static Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {}
    // Clear the old pre-Firebase-Auth session keys too.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('staff_user_id');
    await prefs.remove('staff_role');
  }

  // ───────────────────────── creating accounts

  /// Creates a Firebase account WITHOUT logging out whoever is using the app.
  /// Returns the new account's UID.
  static Future<String> createAccount(String username, String pin) async {
    return _createAuthUser(defaultEmail(username), pin);
  }

  static Future<String> _createAuthUser(String email, String pin) async {
    if (pin.trim().length < minPinLength) {
      throw const StaffAuthException('PIN must be at least 6 digits.');
    }
    final app = await Firebase.initializeApp(
      name: 'tmp_${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    try {
      final cred = await FirebaseAuth.instanceFor(app: app)
          .createUserWithEmailAndPassword(email: email, password: pin.trim());
      return cred.user!.uid;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        throw const StaffAuthException('That username already has a login account.');
      }
      if (e.code == 'invalid-email') {
        throw const StaffAuthException(
            'That username has characters a login cannot use. Use letters, numbers, dots or underscores.');
      }
      throw StaffAuthException('Could not create login: ${e.message ?? e.code}');
    } finally {
      await app.delete();
    }
  }

  /// Links a Firebase account to a users document and its role.
  static Future<void> writeRole(
    String uid,
    String role,
    String userDocId,
    String username,
  ) {
    return _db.collection('auth_roles').doc(uid).set({
      'role': role.toUpperCase(),
      'user_doc_id': userDocId,
      'username': normalize(username),
    });
  }

  // ───────────────────────── PINs

  /// Staff changing their OWN PIN.
  static Future<void> changeOwnPin(String newPin) async {
    if (newPin.trim().length < minPinLength) {
      throw const StaffAuthException('PIN must be at least 6 digits.');
    }
    final user = _auth.currentUser;
    if (user == null) throw const StaffAuthException('You are not signed in.');
    try {
      await user.updatePassword(newPin.trim());
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        throw const StaffAuthException(
            'For security, please log out and log in again, then change your PIN.');
      }
      throw StaffAuthException('Could not change PIN: ${e.message ?? e.code}');
    }
  }

  /// A cooperative / super admin resetting ANOTHER person's PIN.
  /// The app cannot change someone else's Firebase password, so this creates a
  /// fresh login "<username>+vN@jeepes.ph" with the new PIN, points the username
  /// at it, and removes the old login's role so the old PIN stops working.
  static Future<void> resetPin({
    required String userDocId,
    required String newPin,
  }) async {
    final ref = _db.collection('users').doc(userDocId);
    final snap = await ref.get();
    final d = snap.data();
    if (d == null) throw const StaffAuthException('User not found.');

    final username = normalize((d['username'] ?? '').toString());
    if (username.isEmpty) throw const StaffAuthException('This user has no username.');
    final role = (d['role'] ?? '').toString().toUpperCase();
    final oldUid = (d['auth_uid'] ?? '').toString();
    final version = ((d['auth_version'] ?? 1) as num).toInt() + 1;
    final email = '$username+v$version@$domain';

    final newUid = await _createAuthUser(email, newPin);

    final batch = _db.batch();
    batch.set(_db.collection('auth_roles').doc(newUid), {
      'role': role,
      'user_doc_id': userDocId,
      'username': username,
    });
    batch.set(_db.collection('login_aliases').doc(username), {'email': email});
    batch.update(ref, {
      'auth_uid': newUid,
      'auth_email': email,
      'auth_version': version,
      'updated_at': FieldValue.serverTimestamp(),
    });
    if (oldUid.isNotEmpty) {
      batch.delete(_db.collection('auth_roles').doc(oldUid));
    }
    await batch.commit();
  }
}