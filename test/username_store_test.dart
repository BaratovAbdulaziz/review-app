import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:review_app/settings/username_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('remembers the last non-empty username', () async {
    final store = UsernameStore();

    expect(await store.load(), isNull);
    await store.save('  AliceChess  ');

    expect(await store.load(), 'AliceChess');
  });

  test('does not replace a remembered username with empty input', () async {
    final store = UsernameStore();
    await store.save('alice');
    await store.save('   ');

    expect(await store.load(), 'alice');
  });
}
