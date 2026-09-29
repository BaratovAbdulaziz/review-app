import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the most recently reviewed Chess.com account, so reopening the app
/// resumes that player's games without asking for the username again.
class UsernameStore {
  static const _key = 'chess_com_username';

  Future<String?> load() async {
    final value = await SharedPreferences.getInstance().then(
      (preferences) => preferences.getString(_key),
    );
    final username = value?.trim() ?? '';
    return username.isEmpty ? null : username;
  }

  Future<void> save(String username) async {
    final value = username.trim();
    if (value.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, value);
  }
}
