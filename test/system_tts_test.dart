import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/tts/system_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.example.review_app/tts');

  final calls = <MethodCall>[];
  Object? reply;
  String? channelError;

  setUp(() {
    calls.clear();
    reply = null;
    channelError = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (channelError != null) throw PlatformException(code: channelError!);
      return reply;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads the voices the platform offers', () async {
    reply = [
      {
        'name': 'en-us-x-sfg#female_1-local',
        'locale': 'en-US',
        'quality': 'High',
        'score': 400,
        'network': false,
        'available': true,
        'selected': true,
      },
      {
        'name': 'en-gb-x-ise#male_1-local',
        'locale': 'en-GB',
        'quality': 'Enhanced',
        'score': 300,
        'network': false,
        'available': false,
        'selected': false,
      },
    ];

    final voices = await const SystemTts().voices();

    expect(calls.single.method, 'voices');
    expect(voices, hasLength(2));
    // The voice that is already speaking comes first.
    expect(voices.first.isSelected, isTrue);
    expect(voices.first.shortName, 'female 1 local');
    expect(voices.last.isAvailable, isFalse);
  });

  test('the better voice comes first', () async {
    reply = [
      {
        'name': 'ordinary',
        'locale': 'en-US',
        'quality': 'Normal',
        'score': 200,
        'network': false,
        'available': true,
        'selected': false,
      },
      {
        'name': 'better',
        'locale': 'en-US',
        'quality': 'High',
        'score': 400,
        'network': false,
        'available': true,
        'selected': false,
      },
    ];

    final voices = await const SystemTts().voices();

    // The name is a fallback, not the quality: "better" sorts first whatever it
    // is called.
    expect(voices.map((voice) => voice.name), ['better', 'ordinary']);
  });

  test('a voice with no score is still read', () async {
    // A platform that reports the grade but not the number behind it must not
    // drop the voice.
    reply = [
      {
        'name': 'only a name',
        'locale': 'en-US',
        'quality': 'Normal',
        'network': false,
        'available': true,
        'selected': false,
      },
    ];

    final voices = await const SystemTts().voices();

    expect(voices.single.name, 'only a name');
    expect(voices.single.score, 0);
  });

  test(
    'a voice that needs the network sorts after the on-device ones',
    () async {
      reply = [
        {
          'name': 'streamed',
          'locale': 'en-US',
          'quality': 'High',
          'score': 400,
          'network': true,
          'available': true,
          'selected': false,
        },
        {
          'name': 'on device',
          'locale': 'en-US',
          'quality': 'Normal',
          'score': 200,
          'network': false,
          'available': true,
          'selected': false,
        },
      ];

      final voices = await const SystemTts().voices();
      // Streaming is not offered before a voice that is already on the device,
      // even when the platform grades it higher.
      expect(voices.first.requiresNetwork, isFalse);
    },
  );

  test('an empty voice list is not an error', () async {
    reply = null;
    expect(await const SystemTts().voices(), isEmpty);
  });

  test('a missing platform gives no voices instead of throwing', () async {
    channelError = 'notImplemented';
    expect(await const SystemTts().voices(), isEmpty);
  });

  test('chooses a voice by name', () async {
    reply = true;
    expect(
      await const SystemTts().selectVoice('en-us-x-sfg#female_1-local'),
      isTrue,
    );
    expect(calls.single.method, 'setVoice');
    expect(calls.single.arguments, {'name': 'en-us-x-sfg#female_1-local'});
  });

  test('sends speed and pitch with their values', () async {
    reply = true;
    const tts = SystemTts();
    await tts.setRate(1.25);
    await tts.setPitch(0.8);
    expect(calls[0].method, 'setRate');
    expect(calls[0].arguments, {'rate': 1.25});
    expect(calls[1].method, 'setPitch');
    expect(calls[1].arguments, {'pitch': 0.8});
  });

  test('reads back the speed and pitch in use', () async {
    reply = {'rate': 1.4, 'pitch': 0.9};
    final settings = await const SystemTts().settings();
    expect(settings.rate, 1.4);
    expect(settings.pitch, 0.9);
  });

  test(
    'falls back to the default speed when the platform says nothing',
    () async {
      reply = null;
      final settings = await const SystemTts().settings();
      expect(settings.rate, 1.0);
      expect(settings.pitch, 1.0);
    },
  );
}
