import 'dart:async';
import 'dart:convert';
import 'dart:io';

class EngineException implements Exception {
  const EngineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A single `info` line reported by the engine.
class EngineInfoLine {
  const EngineInfoLine({
    required this.depth,
    required this.multiPv,
    required this.scoreCp,
    required this.mateIn,
    required this.nodes,
    required this.pv,
  });

  final int depth;
  final int multiPv;

  /// Score in centipawns from the side-to-move's point of view.
  final int? scoreCp;

  /// Mate distance in moves from the side-to-move's point of view.
  final int? mateIn;

  final int? nodes;

  /// Principal variation in engine notation, starting with the root move.
  final List<String> pv;
}

EngineInfoLine? parseInfoLine(String line) {
  final trimmed = line.trimRight();
  if (!trimmed.startsWith('info ')) return null;
  final tokens = trimmed.split(RegExp(r'\s+'));
  int? depth;
  var multiPv = 1;
  int? scoreCp;
  int? mateIn;
  int? nodes;
  var pv = const <String>[];

  for (var i = 1; i < tokens.length; i++) {
    switch (tokens[i]) {
      case 'depth':
        depth = int.tryParse(_tokenAt(tokens, ++i) ?? '');
      case 'seldepth':
        i++;
      case 'nodes':
        nodes = int.tryParse(_tokenAt(tokens, ++i) ?? '');
      case 'multipv':
        multiPv = int.tryParse(_tokenAt(tokens, ++i) ?? '') ?? 1;
      case 'score':
        final kind = _tokenAt(tokens, ++i);
        final value = int.tryParse(_tokenAt(tokens, ++i) ?? '');
        if (value == null) return null;
        if (kind == 'cp') {
          scoreCp = value;
        } else if (kind == 'mate') {
          mateIn = value;
        }
      case 'lowerbound' || 'upperbound':
        break;
      case 'pv':
        pv = tokens.sublist(i + 1);
        i = tokens.length;
    }
  }

  if (depth == null) return null;
  return EngineInfoLine(
    depth: depth,
    multiPv: multiPv,
    scoreCp: scoreCp,
    mateIn: mateIn,
    nodes: nodes,
    pv: pv,
  );
}

String? _tokenAt(List<String> tokens, int index) =>
    index < tokens.length ? tokens[index] : null;

class EngineResult {
  const EngineResult({
    required this.depth,
    required this.lines,
    required this.nodes,
  });

  final int depth;

  /// Best line first.
  final List<EngineInfoLine> lines;

  final int? nodes;

  String get bestMove =>
      lines.isEmpty || lines.first.pv.isEmpty ? '' : lines.first.pv.first;
}

/// The engine surface the analyser depends on.
abstract interface class ChessEngine {
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves,
    required int depth,
    int multiPv,
    Duration? maxTime,
  });

  /// Releases the engine. Called when the page that owns the engine goes away.
  void dispose();
}

/// Several Stockfish processes sharing the work of one analysis.
///
/// A single binary searching one position at a time leaves most of the machine
/// idle, and a full game is hundreds of independent per-ply searches. This runs
/// [workers] processes with one thread each and hands every request to the next
/// one in turn; each process queues its own requests, so a busy worker simply
/// takes the next one when it finishes. Callers see the same
/// [ChessEngine] surface, and the total time falls roughly with the number of
/// workers.
class StockfishEnginePool implements ChessEngine {
  StockfishEnginePool({
    required this.binaryPath,
    this.workers = 4,
    this.hashMb = 32,
    this.logLines = false,
    List<ChessEngine>? engines,
  }) : assert(workers > 0, 'a pool needs at least one worker') {
    // Visible for testing: lets a test check the dispatch without processes.
    if (engines != null) _engines.addAll(engines);
  }

  final String binaryPath;

  /// How many processes to keep searching at once.
  final int workers;

  /// Hash per process, so the total stays modest.
  final int hashMb;

  final bool logLines;

  /// A sane number of workers for this machine: leave a couple of cores for the
  /// UI and the rest search.
  /// [cores] defaults to the machine's processor count. Two cores are left
  /// free so the desktop keeps responding while a game is analysed.
  static int workersForMachine([int? cores]) {
    final available = cores ?? Platform.numberOfProcessors;
    return (available - 2).clamp(1, 8);
  }

  final List<ChessEngine> _engines = [];
  var _next = 0;
  bool _disposed = false;

  /// How many processes are running.
  int get runningWorkers => _engines.length;

  bool get isRunning => _engines.isNotEmpty;

  /// Starts every process. If one fails to start, the ones already running are
  /// shut down again so a half-started pool never lingers.
  Future<void> start() async {
    // Injected engines are already running, so there is nothing to spawn.
    if (_engines.isNotEmpty) return;
    try {
      for (var i = 0; i < workers; i++) {
        final engine = StockfishEngine(
          binaryPath: binaryPath,
          threads: 1,
          hashMb: hashMb,
          logLines: logLines && workers == 1,
        );
        await engine.start();
        _engines.add(engine);
      }
    } on Object {
      dispose();
      rethrow;
    }
  }

  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) {
    if (_disposed) {
      throw const EngineException('Engine is not running');
    }
    if (_engines.isEmpty) {
      throw const EngineException('Engine is not running');
    }
    // Round robin. A process that is still busy queues the request itself, so
    // there is no need to track which worker is free.
    final engine = _engines[_next++ % _engines.length];
    return engine.analyse(
      fen: fen,
      moves: moves,
      depth: depth,
      multiPv: multiPv,
      maxTime: maxTime,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final engines = List<ChessEngine>.of(_engines);
    _engines.clear();
    for (final engine in engines) {
      engine.dispose();
    }
  }
}

class StockfishEngine implements ChessEngine {
  StockfishEngine({
    required this.binaryPath,
    this.threads = 2,
    this.hashMb = 128,
    this.logLines = false,
  });

  final String binaryPath;
  final int threads;
  final int hashMb;
  final bool logLines;

  /// Upper bound on a single search, so a pathological position cannot stall
  /// the whole game analysis.
  static const defaultMaxSearchTime = Duration(seconds: 15);

  Process? _process;
  final StreamController<String> _lines = StreamController.broadcast();
  StreamSubscription<String>? _subscription;
  Future<void> _queue = Future<void>.value();
  bool _started = false;
  int _multiPv = 0;

  bool get isRunning => _process != null;

  Future<void> start() async {
    if (_started) return;
    if (!File(binaryPath).existsSync()) {
      throw EngineException('Stockfish not found at $binaryPath');
    }
    Process process;
    try {
      process = await Process.start(binaryPath, const []);
    } on ProcessException catch (error) {
      throw EngineException('Could not start Stockfish: ${error.message}');
    }
    _process = process;
    _subscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (logLines) stdout.writeln('[sf] $line');
          _lines.add(line);
        }, onError: (Object _) {});
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (logLines) stderr.writeln('[sf!] $line');
        });

    _write('uci');
    await _waitForLine((line) => line == 'uciok', 'UCI handshake failed');
    _write('setoption name Threads value $threads');
    _write('setoption name Hash value $hashMb');
    _write('isready');
    await _waitForLine(
      (line) => line == 'readyok',
      'Stockfish did not become ready',
    );
    _started = true;
  }

  @override
  Future<EngineResult> analyse({
    required String fen,
    List<String> moves = const [],
    required int depth,
    int multiPv = 1,
    Duration? maxTime,
  }) {
    return _synchronized(() async {
      if (!_started) throw const EngineException('Engine is not running');

      final best = <int, EngineInfoLine>{};
      final completer = Completer<void>();

      // Subscribe before writing so no line can be missed.
      final subscription = _lines.stream.listen((line) {
        final parsed = parseInfoLine(line);
        if (parsed != null) {
          final current = best[parsed.multiPv];
          if (current == null || parsed.depth >= current.depth) {
            best[parsed.multiPv] = parsed;
          }
          return;
        }
        if (line.startsWith('bestmove') && !completer.isCompleted) {
          completer.complete();
        }
      });

      if (_multiPv != multiPv) {
        _write('setoption name MultiPV value $multiPv');
        _multiPv = multiPv;
      }
      _write(
        moves.isEmpty
            ? 'position fen $fen'
            : 'position fen $fen moves ${moves.join(' ')}',
      );
      _write(
        'go depth $depth${maxTime == null ? '' : ' movetime ${maxTime.inMilliseconds}'}',
      );

      try {
        await completer.future.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        throw const EngineException('Stockfish timed out');
      } finally {
        await subscription.cancel();
      }

      final lines = best.values.toList()
        ..sort((a, b) => a.multiPv.compareTo(b.multiPv));
      if (lines.isEmpty) {
        throw const EngineException('Stockfish returned no analysis');
      }
      return EngineResult(
        depth: lines.last.depth,
        lines: lines,
        nodes: lines.last.nodes,
      );
    });
  }

  @override
  Future<void> dispose() async {
    final process = _process;
    if (process == null) return;
    _process = null;
    _started = false;
    try {
      process.stdin.writeln('quit');
      await process.stdin.flush();
      await process.stdin.close();
    } on Object {
      // The process may already be gone.
    }
    await _subscription?.cancel();
    _subscription = null;
    await _lines.close();
  }

  void _write(String command) {
    final stdin = _process?.stdin;
    if (stdin == null) return;
    if (logLines) stdout.writeln('[sf>] $command');
    stdin.writeln(command);
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _waitForLine(
    bool Function(String line) predicate,
    String errorMessage,
  ) async {
    final completer = Completer<void>();
    final subscription = _lines.stream.listen((line) {
      if (predicate(line) && !completer.isCompleted) {
        completer.complete();
      }
    });
    final timer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError(EngineException(errorMessage));
      }
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }
}
