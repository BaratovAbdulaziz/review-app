import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:review_app/tts/system_tts.dart';

/// Speech backend that [Commentator.detect] selected.
enum TtsEngine { piper, espeakNg, android, none }

/// Result of one short-lived child process run. Visible for testing.
class TtsProcessResult {
  const TtsProcessResult(this.exitCode, {this.error = ''});

  /// 0 on success, anything else on failure.
  final int exitCode;

  /// Human readable reason, taken from stderr or from the failure itself.
  final String error;
}

/// Indirection over the child processes the commentator needs, so the queue can
/// be exercised without a real engine installed. Visible for testing.
abstract class TtsProcessRunner {
  /// Absolute path of [name] on PATH, or null when it is not installed.
  Future<String?> which(String name);

  /// Runs [executable] with [arguments], feeding [stdin] to it and closing the
  /// stream, and kills it after [timeout]. [onStarted] receives the process as
  /// soon as it exists so the caller can kill it early.
  Future<TtsProcessResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    required Duration timeout,
    void Function(Process process)? onStarted,
  });
}

/// Default runner that really spawns processes.
class SystemTtsProcessRunner implements TtsProcessRunner {
  const SystemTtsProcessRunner();

  @override
  Future<String?> which(String name) async {
    try {
      final result = await Process.run('which', [
        name,
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return null;
      final path = '${result.stdout}'.trim();
      return path.isEmpty ? null : path;
    } on Object {
      return null;
    }
  }

  @override
  Future<TtsProcessResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    required Duration timeout,
    void Function(Process process)? onStarted,
  }) async {
    Process process;
    try {
      process = await Process.start(executable, arguments);
    } on ProcessException catch (error) {
      return TtsProcessResult(1, error: error.message);
    } on Object {
      return TtsProcessResult(1, error: 'could not start $executable');
    }
    onStarted?.call(process);

    // The last non-empty stderr line becomes the message the UI shows, so keep
    // a bounded tail instead of buffering whatever the engine logs.
    final stderr = StringBuffer();
    final stderrDrained = Completer<void>();
    void finishStderr() {
      if (!stderrDrained.isCompleted) stderrDrained.complete();
    }

    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (stderr.length < 4096) stderr.writeln(line.trim());
          },
          onDone: finishStderr,
          onError: (Object _) => finishStderr(),
        );
    final stdinDone = _writeStdin(process, stdin);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      // Reap the child so it cannot linger as a zombie after we return.
      await process.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: _notFinished)
          .then((_) => null);
      return TtsProcessResult(
        1,
        error: 'timed out after ${timeout.inSeconds}s',
      );
    }
    await stdinDone;
    await stderrDrained.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );

    final message = stderr
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .lastOrNull;
    return TtsProcessResult(
      exitCode,
      error: message == null || exitCode == 0 ? '' : message,
    );
  }

  static int _notFinished() => 1;

  Future<void> _writeStdin(Process process, String? stdin) async {
    try {
      if (stdin != null) {
        process.stdin.write('$stdin\n');
        await process.stdin.flush();
      }
      await process.stdin.close();
    } on Object {
      // The process may have exited before reading its input.
    }
  }
}

/// One queued line of commentary.
class _Utterance {
  const _Utterance(this.text, this.priority);

  final String text;
  final bool priority;
}

/// Speaks short review lines through a locally installed TTS engine.
///
/// Speech is fully offline: text goes to `piper` (or `espeak-ng`), the resulting
/// wav is handed to `paplay` and deleted again. Nothing here ever throws into
/// the caller, because a missing sound card must not break game analysis.
class Commentator {
  /// Both arguments exist only so tests can drive the queue without piper or
  /// espeak-ng installed; the app uses the default constructor.
  Commentator({
    TtsProcessRunner? runner,
    Map<String, String>? environment,
    SystemTts? systemTts,
  }) : _runner = runner ?? const SystemTtsProcessRunner(),
       _systemTts = systemTts ?? const SystemTts(),
       _environment = environment ?? Platform.environment;

  final TtsProcessRunner _runner;

  /// The platform speech engine, used where the command line tools are absent.
  final SystemTts _systemTts;
  final Map<String, String> _environment;

  /// Lines longer than this are cut, so a long move list cannot produce a
  /// half-minute of commentary.
  static const maxCharacters = 220;

  /// Upper bound on lines waiting to be spoken.
  static const maxQueueLength = 3;

  /// A line repeated inside this window is treated as noise.
  static const repeatWindow = Duration(seconds: 5);

  /// Piper loads a ~60 MB model first, so this is generous but not unbounded.
  static const _synthesisTimeout = Duration(seconds: 20);

  /// Bounds playback to a few times the real time of a 220 character line.
  static const _playbackTimeout = Duration(seconds: 90);

  TtsEngine _engine = TtsEngine.none;
  String _engineName = '';
  String? _lastError;
  bool _enabled = true;
  bool _disposed = false;

  String _piperBinary = '';
  String _piperModel = '';
  String _espeakBinary = '';
  String? _player;

  final List<_Utterance> _queue = [];
  bool _pumping = false;
  bool _speaking = false;
  Process? _activeProcess;
  int _generation = 0;
  int _sequence = 0;
  String? _recentLine;
  DateTime? _recentAt;
  Directory? _tempDir;
  Future<void>? _detecting;

  /// Name of the engine in use, or '' when none was found.
  String get engineName => _engineName;

  /// False while no engine has been found; the UI shows a hint instead of a
  /// toggle.
  bool get isAvailable => _engine != TtsEngine.none;

  TtsEngine get engine => _engine;

  /// Latest non-fatal problem, for UI hints.
  String? get lastError => _lastError;

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) stop();
  }

  /// Finds an engine and an audio player. Safe to call more than once; calls
  /// made while a detection is running share its result.
  Future<void> detect() {
    return _detecting ??= _detect().whenComplete(() => _detecting = null);
  }

  /// The voices this device can speak with, for the voice picker.
  ///
  /// Only the platform engine can choose a voice: `piper` ships a single model
  /// and `espeak-ng` is synthesised from the text itself, so neither has a list
  /// of voices to offer.
  Future<List<TtsVoice>> voices() async {
    if (_engine != TtsEngine.android) {
      await detect();
      if (_engine != TtsEngine.android) return const [];
    }
    final voices = await _systemTts.voices();
    return voices;
  }

  /// Switches voice, on the platform engine only. Returns true when it took.
  Future<bool> selectVoice(String name) async {
    if (_engine != TtsEngine.android) return false;
    final ok = await _systemTts.selectVoice(name);
    if (ok) stop();
    return ok;
  }

  /// Sets the speaking speed, 1.0 being the platform default.
  Future<bool> setRate(double rate) async {
    if (_engine != TtsEngine.android) return false;
    return _systemTts.setRate(rate);
  }

  /// Sets the pitch, 1.0 being the platform default.
  Future<bool> setPitch(double pitch) async {
    if (_engine != TtsEngine.android) return false;
    return _systemTts.setPitch(pitch);
  }

  /// The speed and pitch currently in use, so the sliders open where they were
  /// left rather than at the default.
  Future<SpeechSettings> speechSettings() async {
    if (_engine != TtsEngine.android) {
      await detect();
      if (_engine != TtsEngine.android) return const SpeechSettings();
    }
    return _systemTts.settings();
  }

  /// Queues a line. Never blocks and never throws, so the analysis loop can call
  /// it on every move without waiting for audio.
  void speak(String text, {bool interrupt = false, bool priority = false}) {
    if (_disposed || !_enabled) return;
    if (interrupt) {
      _queue.clear();
      _generation++;
      _killActive();
    }
    final line = _condense(text);
    if (line.isEmpty) return;
    if (_queue.length >= maxQueueLength) return;
    // A running game review produces lines faster than they can be spoken, so
    // chatter is dropped rather than queued up into a stale backlog.
    if (!priority && !interrupt && _speaking) return;
    // Collapses the same move being reported twice within a few seconds. An
    // explicit interrupt is a user action and is always honoured.
    if (!interrupt && _isRepeat(line)) return;
    _recentLine = line;
    _recentAt = DateTime.now();

    if (priority) {
      // Ahead of the normal backlog, but still in order relative to the
      // priority lines already waiting.
      final ahead = _queue.indexWhere((item) => !item.priority);
      _queue.insert(ahead < 0 ? _queue.length : ahead, _Utterance(line, true));
    } else {
      _queue.add(_Utterance(line, false));
    }
    _pump();
  }

  /// Stops playback and throws away anything still queued.
  void stop() {
    _queue.clear();
    _generation++;
    _killActive();
  }

  /// Kills every child process and removes the temp directory. Safe to call
  /// twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    final directory = _tempDir;
    _tempDir = null;
    if (directory == null) return;
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // A wav may still be open on a slow shutdown; the temp dir is disposable.
    }
  }

  Future<void> _detect() async {
    if (_disposed) return;
    // Android has none of the command line speech tools used below, so its own
    // engine is used instead of shelling out to something that is not there.
    if (Platform.isAndroid) {
      final name = await _systemTts.engineName();
      if (name == null) {
        _engine = TtsEngine.none;
        _engineName = '';
        _lastError =
            'This device has no speech voice installed. Android Settings > '
            'System > Languages & input > Text-to-speech installs one.';
        return;
      }
      _engine = TtsEngine.android;
      _engineName = name;
      _lastError = null;
      return;
    }

    _player = await _findPlayer();

    // A piper without a voice is unusable, so [problem] is carried into the
    // fallback instead of selecting an engine that cannot speak.
    final piper = await _findPiper();
    final model = piper?.model ?? '';
    if (model.isNotEmpty) {
      _engine = TtsEngine.piper;
      _piperBinary = piper!.binary;
      _piperModel = model;
      _engineName = 'piper (${_modelName(model)})';
      _lastError = _player == null
          ? 'piper found, but no audio player (paplay, pw-play, aplay)'
          : null;
      return;
    }

    final espeak = await _runner.which('espeak-ng');
    if (espeak != null) {
      _engine = TtsEngine.espeakNg;
      _espeakBinary = espeak;
      _engineName = 'espeak-ng';
      _lastError = piper?.problem;
      return;
    }

    _engine = TtsEngine.none;
    _engineName = '';
    _lastError =
        piper?.problem ??
        'No speech engine found. Run tool/install_tts.sh or install espeak-ng.';
  }

  /// Piper is preferred: the bundled one under the app's own data directory
  /// keeps the app self contained, and $PIPER_TTS_BIN wins for packagers.
  Future<_Piper?> _findPiper() async {
    final binary = await _findPiperBinary();
    if (binary == null) return null;
    final model = _findVoiceModel();
    if (model == null) {
      return _Piper(
        binary: binary,
        model: '',
        problem:
            'piper: voice model missing '
            '(set PIPER_TTS_MODEL or run tool/install_tts.sh)',
      );
    }
    return _Piper(binary: binary, model: model);
  }

  Future<String?> _findPiperBinary() async {
    final override = _environment['PIPER_TTS_BIN'];
    if (override != null && override.isNotEmpty && _isExecutable(override)) {
      return override;
    }
    final local = _join(_home, _localPiperDirectory, 'piper');
    if (local.isNotEmpty && _isExecutable(local)) return local;
    return _runner.which('piper');
  }

  /// A model is only usable together with its sibling `.onnx.json` config, so
  /// both must be present.
  String? _findVoiceModel() {
    final override = _environment['PIPER_TTS_MODEL'];
    if (override != null && override.isNotEmpty && _hasConfig(override)) {
      return override;
    }
    final local = _modelIn(_join(_home, _localPiperDirectory));
    if (local != null) return local;
    return _modelIn(_join(_home, 'piper-voices'));
  }

  String? _modelIn(String directoryPath) {
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) return null;
    final models =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.onnx'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final model in models) {
      if (_hasConfig(model.path)) return model.path;
    }
    return null;
  }

  bool _hasConfig(String modelPath) =>
      File(modelPath).existsSync() && File('$modelPath.json').existsSync();

  Future<String?> _findPlayer() async {
    for (final candidate in const ['paplay', 'pw-play', 'aplay']) {
      final path = await _runner.which(candidate);
      if (path != null) return path;
    }
    return null;
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final utterance = _queue.removeAt(0);
        _speaking = true;
        try {
          await _speak(utterance);
        } on Object {
          // Audio is a nicety; a failure here must never reach the analysis
          // loop as an unhandled error.
          _lastError = 'speech failed';
        } finally {
          _speaking = false;
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _speak(_Utterance utterance) async {
    if (_engine == TtsEngine.android) {
      // A stop() or dispose() bumps the generation, so a result that arrives
      // after the line was cancelled is ignored below.
      final generation = _generation;
      final spoken = await _systemTts.speak(utterance.text);
      if (generation != _generation) return;
      if (!spoken) _lastError = '$_label: could not speak';
      return;
    }

    final player = _player;
    if (player == null) {
      _lastError = 'no audio player found (install paplay or pipewire)';
      return;
    }
    final directory = await _tempDirectory();
    if (directory == null) return;
    final wav = File(_join(directory.path, 'line_${_sequence++}.wav'));
    // A stop() or dispose() bumps the generation, which tells the result of
    // each run below that its process was killed on purpose.
    final generation = _generation;

    try {
      final spoken = await _runner.run(
        _engine == TtsEngine.piper ? _piperBinary : _espeakBinary,
        _engine == TtsEngine.piper
            ? ['--model', _piperModel, '--output_file', wav.path]
            : ['-w', wav.path],
        stdin: utterance.text,
        timeout: _synthesisTimeout,
        onStarted: _track,
      );
      if (generation != _generation) return;
      if (spoken.exitCode != 0) {
        _lastError =
            '$_label: ${spoken.error.isEmpty ? 'failed' : spoken.error}';
        return;
      }
      if (!wav.existsSync()) {
        _lastError = '$_label: produced no audio';
        return;
      }

      final played = await _runner.run(
        player,
        [wav.path],
        timeout: _playbackTimeout,
        onStarted: _track,
      );
      if (generation != _generation) return;
      if (played.exitCode != 0) {
        _lastError =
            'playback: ${played.error.isEmpty ? 'failed' : played.error}';
      }
    } finally {
      _remove(wav);
    }
  }

  Future<Directory?> _tempDirectory() async {
    final existing = _tempDir;
    if (existing != null) return existing;
    final created = await Directory.systemTemp.createTemp('review_app_tts_');
    if (_disposed) {
      _remove(created);
      return null;
    }
    return _tempDir = created;
  }

  void _track(Process process) => _activeProcess = process;

  void _killActive() {
    if (_engine == TtsEngine.android) {
      unawaited(_systemTts.stop());
    }
    final process = _activeProcess;
    _activeProcess = null;
    if (process == null) return;
    try {
      process.kill();
    } on Object {
      // Already gone.
    }
  }

  void _remove(FileSystemEntity entity) {
    try {
      if (!entity.existsSync()) return;
      if (entity is Directory) {
        entity.deleteSync(recursive: true);
      } else {
        entity.deleteSync();
      }
    } on FileSystemException {
      // Left behind in the system temp dir, cleaned up by the OS.
    }
  }

  bool _isRepeat(String line) {
    final at = _recentAt;
    if (_recentLine != line || at == null) return false;
    return DateTime.now().difference(at) < repeatWindow;
  }

  /// Collapses the comment templates and long move lists into one line.
  String _condense(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '';
    if (flat.length <= maxCharacters) return flat;
    final cut = flat.substring(0, maxCharacters);
    final space = cut.lastIndexOf(' ');
    return (space > maxCharacters ~/ 2 ? cut.substring(0, space) : cut).trim();
  }

  String get _label => switch (_engine) {
    TtsEngine.piper => 'piper',
    TtsEngine.espeakNg => 'espeak-ng',
    TtsEngine.android => 'device speech',
    TtsEngine.none => 'tts',
  };

  static String get _localPiperDirectory => '.local/share/review_app/tts/piper';

  String? get _home {
    final home = _environment['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  static bool _isExecutable(String path) {
    if (path.isEmpty) return false;
    final file = File(path);
    if (!file.existsSync()) return false;
    // A non-executable file is treated as missing rather than reported as a
    // broken engine, so detection can fall through to espeak-ng.
    return _canExecute(path);
  }

  static String _modelName(String modelPath) {
    final name = modelPath.split('/').last;
    return name.endsWith('.onnx') ? name.substring(0, name.length - 5) : name;
  }

  static String _join(String? directory, String part, [String? last]) {
    if (directory == null || directory.isEmpty) return '';
    final base = '$directory/$part';
    return last == null ? base : '$base/$last';
  }
}

bool _canExecute(String path) {
  try {
    return Process.runSync('test', ['-x', path]).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Piper install found during detection.
class _Piper {
  const _Piper({required this.binary, required this.model, this.problem});

  final String binary;
  final String model;

  /// Set when the binary is there but unusable, so the UI can explain why the
  /// app fell back to espeak-ng.
  final String? problem;
}
