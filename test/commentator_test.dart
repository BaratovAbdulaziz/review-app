import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:review_app/tts/commentator.dart';

/// Stands in for the real child processes. Records every run and writes a stub
/// wav so the queue can be driven without piper or espeak-ng installed.
class _FakeRunner implements TtsProcessRunner {
  _FakeRunner({Map<String, String>? executables})
    : executables = executables ?? const <String, String>{};

  final Map<String, String> executables;
  final List<String> spoken = [];
  final List<String> played = [];
  final firstRunStarted = Completer<void>();
  final _spokenWaiters = <(int, Completer<void>)>[];
  final _playedWaiters = <(int, Completer<void>)>[];
  TtsProcessResult result = const TtsProcessResult(0);

  /// When set, every run blocks until this completes.
  Completer<void>? gate;

  @override
  Future<String?> which(String name) async => executables[name];

  @override
  Future<TtsProcessResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    required Duration timeout,
    void Function(Process process)? onStarted,
  }) async {
    if (!firstRunStarted.isCompleted) firstRunStarted.complete();
    final gate = this.gate;
    if (gate != null) await gate.future;

    if (stdin != null) {
      spoken.add(stdin);
      _completeWaiters(_spokenWaiters, spoken.length);
      final wav = _wavArgument(arguments);
      if (wav != null) {
        File(wav).writeAsBytesSync(const [0x52, 0x49, 0x46, 0x46]);
      }
    } else {
      played.add(arguments.first);
      _completeWaiters(_playedWaiters, played.length);
    }
    return result;
  }

  Future<void> waitForSpoken(int count) =>
      _waitFor(_spokenWaiters, spoken.length, count);

  Future<void> waitForPlayed(int count) =>
      _waitFor(_playedWaiters, played.length, count);

  Future<void> _waitFor(
    List<(int, Completer<void>)> waiters,
    int current,
    int wanted,
  ) {
    if (current >= wanted) return Future.value();
    final done = Completer<void>();
    waiters.add((wanted, done));
    return done.future;
  }

  void _completeWaiters(List<(int, Completer<void>)> waiters, int current) {
    final complete = waiters.where((waiter) => waiter.$1 <= current).toList();
    waiters.removeWhere((waiter) => waiter.$1 <= current);
    for (final (_, done) in complete) {
      done.complete();
    }
  }

  String? _wavArgument(List<String> arguments) {
    for (final flag in const ['--output_file', '-w']) {
      final index = arguments.indexOf(flag);
      if (index >= 0 && index + 1 < arguments.length) {
        return arguments[index + 1];
      }
    }
    return null;
  }
}

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('commentator_test_');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// A voice model plus its config, which piper needs to be considered usable.
  String writeModel([String name = 'en_US-lessac-medium']) {
    final model = File('${workspace.path}/$name.onnx');
    model.writeAsBytesSync(const [0x01]);
    File('${model.path}.json').writeAsStringSync('{}');
    return model.path;
  }

  group('disabled commentator', () {
    test('speak returns immediately and starts no process', () {
      final runner = _FakeRunner(
        executables: const {'piper': '/fake/piper', 'paplay': '/fake/paplay'},
      );
      final commentator = Commentator(runner: runner, environment: const {});
      commentator.enabled = false;

      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 500; i++) {
        commentator.speak('move $i played on c4');
      }
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(runner.spoken, isEmpty);
      expect(runner.played, isEmpty);
    });

    test('stop and dispose are safe, twice, and swallow later calls', () async {
      final commentator = Commentator(
        runner: _FakeRunner(),
        environment: const {},
      );
      commentator.stop();
      await commentator.dispose();
      await commentator.dispose();
      commentator.stop();
      commentator.speak('after dispose');
    });

    test('detect never throws and reports a helpful error', () async {
      final commentator = Commentator(
        runner: _FakeRunner(),
        environment: const {},
      );
      await commentator.detect();

      expect(commentator.engine, TtsEngine.none);
      expect(commentator.isAvailable, isFalse);
      expect(commentator.engineName, isEmpty);
      expect(commentator.lastError, contains('No speech engine found'));
    });
  });

  group('detection', () {
    test('prefers piper and names the voice', () async {
      final model = writeModel();
      final commentator = Commentator(
        runner: _FakeRunner(executables: const {'paplay': '/fake/paplay'}),
        environment: {
          'PIPER_TTS_BIN': Platform.resolvedExecutable,
          'PIPER_TTS_MODEL': model,
        },
      );
      await commentator.detect();

      expect(commentator.engine, TtsEngine.piper);
      expect(commentator.isAvailable, isTrue);
      expect(commentator.engineName, 'piper (en_US-lessac-medium)');
      expect(commentator.lastError, isNull);
      await commentator.dispose();
    });

    test(
      'finds a model with its sibling json under the app data directory',
      () async {
        final home = Directory('${workspace.path}/home')..createSync();
        final voices = Directory(
          '${home.path}/.local/share/review_app/tts/piper',
        )..createSync(recursive: true);
        final piper = File('${voices.path}/piper')
          ..writeAsStringSync('#!/bin/sh\n');
        Process.runSync('chmod', ['+x', piper.path]);
        final model = File('${voices.path}/en_US-lessac-medium.onnx')
          ..writeAsBytesSync(const [0x01]);
        File('${model.path}.json').writeAsStringSync('{}');

        final commentator = Commentator(
          runner: _FakeRunner(executables: const {'paplay': '/fake/paplay'}),
          environment: {'HOME': home.path},
        );
        await commentator.detect();

        expect(commentator.engine, TtsEngine.piper);
        expect(commentator.engineName, 'piper (en_US-lessac-medium)');
        await commentator.dispose();
      },
    );

    test('ignores an onnx model without its config', () async {
      final home = Directory('${workspace.path}/home')..createSync();
      final voices = Directory('${home.path}/piper-voices')..createSync();
      File('${voices.path}/broken.onnx').writeAsBytesSync(const [0x01]);

      final commentator = Commentator(
        runner: _FakeRunner(
          executables: const {'espeak-ng': '/fake/espeak-ng'},
        ),
        environment: {'HOME': home.path},
      );
      await commentator.detect();

      expect(commentator.engine, TtsEngine.espeakNg);
      expect(commentator.engineName, 'espeak-ng');
      await commentator.dispose();
    });

    test('falls back to espeak-ng and explains the missing voice', () async {
      final home = Directory('${workspace.path}/home')..createSync();
      final voices = Directory('${home.path}/.local/share/review_app/tts/piper')
        ..createSync(recursive: true);
      final piper = File('${voices.path}/piper')
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', piper.path]);

      final commentator = Commentator(
        runner: _FakeRunner(
          executables: const {'espeak-ng': '/fake/espeak-ng'},
        ),
        environment: {'HOME': home.path},
      );
      await commentator.detect();

      expect(commentator.engine, TtsEngine.espeakNg);
      expect(commentator.lastError, contains('voice model missing'));
      await commentator.dispose();
    });

    test('falls back from pw-play when paplay is missing', () async {
      final commentator = Commentator(
        runner: _FakeRunner(
          executables: const {
            'pw-play': '/fake/pw-play',
            'espeak-ng': '/fake/espeak-ng',
          },
        ),
        environment: const {},
      );
      await commentator.detect();
      expect(commentator.engine, TtsEngine.espeakNg);
      await commentator.dispose();
    });

    test('detect is safe to call more than once', () async {
      final runner = _FakeRunner(
        executables: const {'piper': '/fake/piper', 'paplay': '/fake/paplay'},
      );
      final commentator = Commentator(
        runner: runner,
        environment: {'PIPER_TTS_MODEL': writeModel()},
      );
      await Future.wait([commentator.detect(), commentator.detect()]);
      await commentator.detect();

      expect(commentator.engine, TtsEngine.piper);
      expect(commentator.engineName, 'piper (en_US-lessac-medium)');
      await commentator.dispose();
    });
  });

  group('queue', () {
    late _FakeRunner runner;
    late Commentator commentator;
    late Completer<void> gate;

    setUp(() async {
      runner = _FakeRunner(
        executables: const {'piper': '/fake/piper', 'paplay': '/fake/paplay'},
      );
      commentator = Commentator(
        runner: runner,
        environment: {'PIPER_TTS_MODEL': writeModel()},
      );
      await commentator.detect();
      gate = Completer<void>();
      runner.gate = gate;
    });

    tearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await commentator.dispose();
    });

    test('speaks a queued line and plays the wav', () async {
      commentator.speak('Knight to b5 wins a piece.');
      gate.complete();
      await runner.waitForSpoken(1);
      await runner.waitForPlayed(1);

      expect(runner.spoken, ['Knight to b5 wins a piece.']);
      expect(runner.played, hasLength(1));
    });

    test('truncates a long line', () async {
      commentator.speak('x' * 900);
      gate.complete();
      await runner.waitForSpoken(1);

      expect(runner.spoken.single.length, lessThanOrEqualTo(220));
    });

    test('collapses whitespace and drops empty lines', () async {
      commentator.speak('  Rook   to\n\td7  ');
      commentator.speak('    ');
      gate.complete();
      await runner.waitForSpoken(1);

      expect(runner.spoken, ['Rook to d7']);
    });

    test('collapses a repeated line within the repeat window', () async {
      commentator.speak('The knight hangs.');
      commentator.speak('The knight hangs.');
      gate.complete();
      await runner.waitForSpoken(1);

      expect(runner.spoken, ['The knight hangs.']);
    });

    test('drops a normal line while something is already speaking', () async {
      commentator.speak('First comment.');
      await runner.firstRunStarted.future;
      commentator.speak('Second comment.');
      gate.complete();
      await runner.waitForSpoken(1);

      expect(runner.spoken, ['First comment.']);
    });

    test('keeps priority lines ahead of normal ones', () async {
      commentator.speak('Normal one.');
      await runner.firstRunStarted.future;
      commentator.speak('Priority line.', priority: true);
      commentator.speak('Normal two.', priority: true);
      gate.complete();
      await runner.waitForSpoken(3);

      expect(runner.spoken, ['Normal one.', 'Priority line.', 'Normal two.']);
    });

    test('interrupt clears the queue and is always spoken', () async {
      commentator.speak('First comment.');
      await runner.firstRunStarted.future;
      commentator.speak('Queued comment.');
      commentator.speak('Now stop that.', interrupt: true);
      gate.complete();
      await runner.waitForSpoken(2);

      expect(runner.spoken, ['First comment.', 'Now stop that.']);
    });

    test('a broken engine surfaces an error instead of throwing', () async {
      runner.result = const TtsProcessResult(1, error: 'model file is corrupt');
      expect(() => commentator.speak('This will fail.'), returnsNormally);
      gate.complete();
      // The error is recorded after the runner and the temp file, which is more
      // than one event loop turn on a loaded machine.
      await pumpEventQueue(times: 50);

      expect(commentator.lastError, 'piper: model file is corrupt');
    });
  });
}
