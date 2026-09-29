import 'dart:math' as math;

import 'package:chess/chess.dart' show Chess;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../engine/engine_installer.dart';
import '../engine/game_analyzer.dart';
import '../engine/move_explainer.dart';
import '../engine/move_tags.dart';
import '../engine/performance_summary.dart';
import '../engine/pgn_parser.dart';
import '../engine/stockfish_engine.dart';
import '../models/chess_game.dart';
import '../tts/commentator.dart';
import '../tts/system_tts.dart';
import 'chess_board_view.dart';

final _largeIconButtonStyle = IconButton.styleFrom(
  minimumSize: const Size.square(52),
  iconSize: 30,
  padding: const EdgeInsets.all(11),
);

final _largeFilledButtonStyle = FilledButton.styleFrom(
  minimumSize: const Size.fromHeight(52),
  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
);

final _largeOutlinedButtonStyle = OutlinedButton.styleFrom(
  minimumSize: const Size.fromHeight(52),
  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
);

class GameAnalysisPage extends StatefulWidget {
  const GameAnalysisPage({
    super.key,
    required this.game,
    required this.username,
    this.engine,
    this.commentator,
  });

  final ChessGame game;
  final String username;

  /// Skips installing and starting an engine, which lets tests drive the page
  /// with a stand-in. The app itself never passes this.
  final ChessEngine? engine;

  /// Stands in for the local speech engine, so tests never spawn a process.
  final Commentator? commentator;

  @override
  State<GameAnalysisPage> createState() => _GameAnalysisPageState();
}

class _GameAnalysisPageState extends State<GameAnalysisPage> {
  static const _depths = [8, 10, 12, 14, 16];

  /// What the engine's reply wins after the moves that gave something away,
  /// keyed by ply.
  Map<int, MoveConsequence> _consequences = const {};

  /// How many of those replies are still being searched.
  int _explaining = 0;
  int _explainingTotal = 0;

  /// Counts the reviews, so replies belonging to a review the user has already
  /// replaced are dropped instead of landing on the new one.
  int _review = 0;

  final EngineInstaller _installer = const EngineInstaller();

  GameLadder? _ladder;
  String? _ladderError;

  ChessEngine? _engine;
  bool _ownsEngine = true;
  int _workerCount = 1;
  String? _engineError;
  bool _starting = true;
  EngineInstallStatus _status = const EngineInstallStatus(
    isSupported: true,
    isInstalled: false,
  );

  GameAnalysis? _analysis;
  bool _analyzing = false;
  int _completed = 0;
  int _total = 0;
  bool _installing = false;
  double _installProgress = 0;
  String? _installStage;
  String? _installError;
  int _depth = 12;

  int _ply = 0;
  bool _whiteAtBottom = true;

  /// Narrates the review out loud. Started muted so nothing talks until the
  /// reader asks for it.
  late final Commentator _commentator = widget.commentator ?? Commentator();
  bool _ttsReady = false;

  @override
  void initState() {
    super.initState();
    _parseGame();
    _bootstrapEngine();
    _detectSpeech();
  }

  @override
  void dispose() {
    if (_ownsEngine) _engine?.dispose();
    _commentator.dispose();
    super.dispose();
  }

  Future<void> _detectSpeech() async {
    await _commentator.detect();
    if (!mounted) return;
    setState(() => _ttsReady = true);
  }

  void _toggleSpeech() {
    final enabled = !_commentator.enabled;
    _commentator.enabled = enabled;
    setState(() {});
    if (enabled) {
      _commentator.speak('Commentary is on.', priority: true);
    } else {
      _commentator.stop();
    }
  }

  void _parseGame() {
    final pgn = widget.game.pgn;
    if (pgn == null || pgn.trim().isEmpty) {
      setState(() => _ladderError = 'This game has no PGN data to analyse.');
      return;
    }
    try {
      setState(() => _ladder = parsePgn(pgn));
    } on PgnParseException catch (error) {
      setState(() => _ladderError = error.message);
    }
  }

  Future<void> _bootstrapEngine() async {
    final injected = widget.engine;
    if (injected != null) {
      _ownsEngine = false;
      setState(() {
        _engine = injected;
        _status = const EngineInstallStatus(
          isSupported: true,
          isInstalled: true,
        );
        _starting = false;
      });
      return;
    }
    if (kIsWeb) {
      setState(() {
        _starting = false;
        _engineError =
            'Stockfish runs locally, so analysis needs the desktop app. '
            'This build cannot start an engine process.';
      });
      return;
    }
    try {
      final status = await _installer.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _starting = false;
      });
      if (status.isInstalled) await _startEngine(status.binaryPath!);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _engineError = '$error';
      });
    }
  }

  Future<void> _startEngine(String binaryPath) async {
    setState(() {
      _starting = true;
      _engineError = null;
    });
    try {
      // One process per core: a game is hundreds of independent searches, so
      // they run side by side instead of one after another.
      final workers = StockfishEnginePool.workersForMachine();
      final engine = StockfishEnginePool(
        binaryPath: binaryPath,
        workers: workers,
        hashMb: 64,
      );
      await engine.start();
      _workerCount = workers;
      if (!mounted) {
        engine.dispose();
        return;
      }
      setState(() {
        _engine = engine;
        _starting = false;
      });
    } on EngineException catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _engineError = error.message;
      });
    }
  }

  Future<void> _install() async {
    setState(() {
      _installError = null;
      _installProgress = 0;
      _installing = true;
      _installStage = 'Starting';
    });
    try {
      final status = await _installer.install(
        onProgress: (progress) {
          if (mounted) setState(() => _installProgress = progress);
        },
        onStage: (stage) {
          if (mounted) setState(() => _installStage = stage);
        },
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        _installing = false;
        _installStage = null;
      });
      await _startEngine(status.binaryPath!);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _installStage = null;
        _installError = 'Install failed: $error';
      });
    }
  }

  Future<void> _analyze() async {
    final engine = _engine;
    final ladder = _ladder;
    if (engine == null || ladder == null || _analyzing) return;

    final review = ++_review;
    setState(() {
      _analyzing = true;
      _completed = 0;
      _total = ladder.plies.length;
      _analysis = null;
      _consequences = const {};
      _explaining = 0;
      _explainingTotal = 0;
    });

    final workers = engine is StockfishEnginePool ? engine.runningWorkers : 1;
    _commentator.speak(
      'Starting the review. I will let you know when it is ready.',
      priority: true,
    );
    try {
      final analysis = await analyzeGame(
        engine: engine,
        ladder: ladder,
        depth: _depth,
        concurrency: math.max(1, workers),
        onProgress: (completed, total) {
          if (mounted) {
            setState(() {
              _completed = completed;
              _total = total;
            });
          }
        },
        onPartial: (partial) {
          if (mounted) setState(() => _analysis = partial);
        },
      );
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _analyzing = false;
        _ply = 0;
      });
      _commentator.speak(_summary(analysis), priority: true, interrupt: true);
      await _explainMistakes(engine, ladder, analysis, review);
    } on EngineException catch (error) {
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _engineError = error.message;
      });
    }
  }

  /// Asks the engine what the opponent does after every move that gave
  /// something away, so the explanation can say what the move actually let go
  /// of rather than only how much it was worth.
  ///
  /// This runs after the review is on screen, a ply deep and only for the moves
  /// that were wrong, and each reply appears as it arrives.
  Future<void> _explainMistakes(
    ChessEngine engine,
    GameLadder ladder,
    GameAnalysis analysis,
    int review,
  ) async {
    final workers = engine is StockfishEnginePool ? engine.runningWorkers : 1;
    try {
      final found = await probeConsequences(
        engine: engine,
        ladder: ladder,
        moves: analysis.moves,
        concurrency: math.max(1, workers),
        onProgress: (done, total) {
          if (mounted && review == _review) {
            setState(() {
              _explaining = done;
              _explainingTotal = total;
            });
          }
        },
      );
      if (!mounted || review != _review) return;
      setState(() {
        _consequences = found;
        _explaining = 0;
        _explainingTotal = 0;
      });
    } on EngineException {
      // The explanations are an addition to the review, not part of it: if the
      // engine cannot answer them the move is still explained without one.
      if (mounted && review == _review) {
        setState(() {
          _explaining = 0;
          _explainingTotal = 0;
        });
      }
    }
  }

  void _step(int delta) {
    final total = _ladder?.plies.length ?? 0;
    setState(() => _ply = (_ply + delta).clamp(0, total));
    _speakAboutPly();
  }

  /// The searched profile is the person using the app, so the review addresses
  /// them as "you" and the other player as "opponent" instead of repeating the
  /// two usernames back at them.
  bool _isReviewer(bool isWhite) =>
      widget.game.isWhite(widget.username) == isWhite;

  String _moverName(bool isWhite) => _isReviewer(isWhite) ? 'you' : 'opponent';

  String _otherName(bool isWhite) => _isReviewer(isWhite) ? 'opponent' : 'you';

  /// Reads out the move that is now on the board: every move the person walks
  /// to is commented, opening book moves included, because they are looking at
  /// that move and want to hear about it.
  void _speakAboutPly() {
    final analysis = _analysis;
    if (analysis == null || _ply == 0 || _ply > analysis.moves.length) return;
    final move = analysis.moves[_ply - 1];
    _commentator.speak(
      spokenMoveCommentary(move, playerName: _moverName(move.isWhite)),
      interrupt: true,
    );
  }

  /// The factual explanation shown in the move panel.
  String _explain(AnalyzedMove move) => explainMove(
    move,
    consequence: _consequences[move.ply.index],
    playerName: _moverName(move.isWhite),
    opponentName: _otherName(move.isWhite),
  );

  /// The plain-language notes for a move: captures, castling, pieces left
  /// hanging, and material the engine could have taken.
  ///
  /// A note needs the move that followed it, since a pawn is only really free
  /// once the opponent has declined to recapture.
  List<MoveNote> _notesFor(AnalyzedMove move) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    final index = analysis.moves.indexWhere(
      (other) => other.ply.index == move.ply.index,
    );
    return notesFor(
      move,
      who: _moverName(move.isWhite),
      next: index >= 0 && index + 1 < analysis.moves.length
          ? analysis.moves[index + 1]
          : null,
    );
  }

  /// How the whole game went, in the reviewer's own words rather than engine
  /// numbers, for the panel and for the closing line that is read out.
  PerformanceSummary _performance(GameAnalysis analysis) => summarise(
    analysis,
    isReviewerWhite: widget.game.isWhite(widget.username),
  );

  /// The spoken closing line avoids reading engine data that is already on
  /// screen. It gives the verdict, the one thing worth acting on, and then
  /// leaves the moves to the player.
  String _summary(GameAnalysis analysis) {
    final summary = _performance(analysis);
    return [
      'Review complete. ${summary.headline}.',
      if (summary.points.isNotEmpty) summary.points.first,
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final ladder = _ladder;
    final fen = _currentFen();
    final analysis = _analysis;
    final currentMove =
        _ply > 0 && analysis != null && _ply <= analysis.moves.length
        ? analysis.moves[_ply - 1]
        : null;
    // The engine's own move is always drawn on the position that was actually
    // played, so there is no preview mode to toggle: the blue arrow is what
    // happened and the green arrow is what the engine wanted instead.
    final boardFen = fen;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You vs opponent', style: const TextStyle(fontSize: 16)),
            Text(
              widget.game.opening ?? widget.game.title ?? 'chess.com game',
              style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
            ),
          ],
        ),
        actions: [_speechButton()],
      ),
      body: ladder == null
          ? Center(child: Text(_ladderError ?? 'Loading game…'))
          : _StepKeys(
              onStep: _step,
              onFirst: () => _step(-_ply),
              onLast: () => _step(ladder.plies.length - _ply),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth > 880;
                  final mover = currentMove == null
                      ? ''
                      : _moverName(currentMove.isWhite);

                  final board = _BoardPanel(
                    fen: boardFen,
                    lastMove: _ply == 0 ? null : ladder.plies[_ply - 1].uci,
                    bestMove: currentMove?.bestMoveUci,
                    statusSymbol: currentMove?.verdict.symbol,
                    statusColor: currentMove == null
                        ? null
                        : _MoveDetail._verdictColors[currentMove.verdict],
                    inCheck: _inCheck(boardFen),
                    whiteAtBottom: _whiteAtBottom,
                    onFlip: () =>
                        setState(() => _whiteAtBottom = !_whiteAtBottom),
                    evalCp: currentMove?.evalAfter ?? analysis?.finalEval,
                    evalFor: currentMove == null ? 'start' : mover,
                  );

                  final details = <Widget>[
                    if (analysis != null && !_analyzing)
                      _PerformanceCard(summary: _performance(analysis)),
                    if (currentMove != null)
                      _MoveDetail(
                        move: currentMove,
                        playerName: mover,
                        depth: analysis?.depth ?? _depth,
                        explanation: _explain(currentMove),
                        notes: _notesFor(currentMove),
                      ),
                    if (_explainingTotal > 0) _explainingPanel(),
                    _enginePanel(),
                    _moveList(ladder, analysis),
                  ];

                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: board,
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        SizedBox(
                          width: 420,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _controls(ladder),
                              const Divider(height: 1),
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.all(16),
                                  children: details,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      board,
                      const SizedBox(height: 8),
                      _controls(ladder),
                      ...details,
                    ],
                  );
                },
              ),
            ),
    );
  }

  /// Mutes or unmutes the spoken commentary, and says why it is unavailable
  /// when no local speech engine is installed.
  Widget _speechButton() {
    final available = _commentator.isAvailable;
    final on = available && _commentator.enabled;
    final tooltip = !_ttsReady
        ? 'Looking for a local speech engine…'
        : !available
        ? '${_commentator.lastError ?? 'No speech engine'} '
              '(install one with tool/install_tts.sh)'
        : on
        ? 'Mute commentary (${_commentator.engineName})'
        : 'Speak commentary (${_commentator.engineName})';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: !_ttsReady || !available ? null : _toggleSpeech,
          tooltip: tooltip,
          icon: Icon(on ? Icons.volume_up : Icons.volume_off),
          style: _largeIconButtonStyle,
        ),
        IconButton(
          onPressed: !_ttsReady || !available ? null : _voiceSettings,
          tooltip: 'Commentary voice',
          icon: const Icon(Icons.record_voice_over),
          style: _largeIconButtonStyle,
        ),
      ],
    );
  }

  /// Lets the reader pick the voice, speed and pitch, and hear each change as
  /// they make it. Only the platform engine has any of these to offer.
  Future<void> _voiceSettings() async {
    final voices = await _commentator.voices();
    final settings = await _commentator.speechSettings();
    if (!mounted) return;
    if (voices.isEmpty) {
      _commentator.speak(
        'This engine speaks with a single voice, so there is nothing '
        'to choose.',
        priority: true,
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _VoiceSheet(
        commentator: _commentator,
        voices: voices,
        rate: settings.rate,
        pitch: settings.pitch,
      ),
    );
  }

  String _currentFen() {
    final ladder = _ladder;
    if (ladder == null) return Chess.DEFAULT_POSITION;
    if (_ply == 0) return ladder.startFen;
    return ladder.plies[_ply - 1].fenAfter;
  }

  bool _inCheck(String fen) {
    try {
      return Chess.fromFEN(fen).in_check;
    } on Object {
      return false;
    }
  }

  Widget _controls(GameLadder ladder) {
    final afterWhite = _ply.isOdd;
    final number = afterWhite ? (_ply + 1) ~/ 2 : _ply ~/ 2;
    final label = _ply == 0
        ? 'Start position'
        : '$number${afterWhite ? '.' : '..'} after $_ply of '
              '${ladder.plies.length}';
    return Row(
      children: [
        IconButton(
          onPressed: _ply == 0 ? null : () => _step(-_ply),
          icon: const Icon(Icons.first_page),
          tooltip: 'Start position',
          style: _largeIconButtonStyle,
        ),
        IconButton(
          onPressed: _ply == 0 ? null : () => _step(-1),
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous move',
          style: _largeIconButtonStyle,
        ),
        Expanded(
          child: Center(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ),
        IconButton(
          onPressed: _ply >= ladder.plies.length ? null : () => _step(1),
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next move',
          style: _largeIconButtonStyle,
        ),
        IconButton(
          onPressed: _ply >= ladder.plies.length
              ? null
              : () => _step(ladder.plies.length - _ply),
          icon: const Icon(Icons.last_page),
          tooltip: 'Final position',
          style: _largeIconButtonStyle,
        ),
      ],
    );
  }

  /// A quiet note while the engine is being asked what the mistakes let go of,
  /// so the moves already on screen are not left looking unexplained.
  Widget _explainingPanel() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Checking what the opponent gets after the wrong moves: '
              '$_explaining of $_explainingTotal.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _enginePanel() {
    if (_starting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_installError != null) {
      return _panel(_installError!, onRetry: _install);
    }
    if (!_status.isSupported) {
      return _panel(
        'Stockfish has no build for this platform, so analysis is unavailable.',
      );
    }
    if (_engine == null && _engineError != null) {
      return _panel(_engineError!, onRetry: _bootstrapEngine);
    }
    if (_engine == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _installing
                  ? '${_installStage ?? 'Installing'}…'
                  : 'Stockfish is not installed yet. It is a ~80 MB download '
                        'and analyses games on this machine.',
              style: const TextStyle(color: Color(0xFF5F6368)),
            ),
            if (_installing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _installProgress),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _installing ? null : _install,
              icon: const Icon(Icons.download),
              label: Text(_installing ? 'Installing…' : 'Install Stockfish'),
              style: _largeFilledButtonStyle,
            ),
          ],
        ),
      );
    }
    if (_analyzing) {
      final progress = _total == 0 ? 0.0 : _completed / _total;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Analysing move $_completed of $_total'
              '${_workerCount > 1 ? ' on $_workerCount engines' : ''}…',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _depth,
              decoration: const InputDecoration(
                labelText: 'Search depth',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final depth in _depths)
                  DropdownMenuItem(value: depth, child: Text('$depth ply')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _depth = value);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _analyze,
              icon: Icon(_analysis == null ? Icons.play_arrow : Icons.refresh),
              label: Text(_analysis == null ? 'Analyse game' : 'Re-analyse'),
              style: _largeFilledButtonStyle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _moveList(GameLadder ladder, GameAnalysis? analysis) {
    if (analysis == null) {
      return const SizedBox.shrink();
    }
    final rows = <Widget>[];
    for (var i = 0; i < analysis.moves.length; i += 2) {
      rows.add(
        InkWell(
          onTap: () {
            setState(() => _ply = i + 1);
            _speakAboutPly();
          },
          child: _MoveRow(
            number: i ~/ 2 + 1,
            white: analysis.moves[i],
            black: i + 1 < analysis.moves.length ? analysis.moves[i + 1] : null,
            selected: _ply == i + 1 || _ply == i + 2,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        Text(
          'Moves — ${analysis.plies} ply, depth ${analysis.depth}. '
          'White avg loss ${analysis.averageCplWhite().toStringAsFixed(0)}cp, '
          'Black avg loss ${analysis.averageCplBlack().toStringAsFixed(0)}cp.'
          '${analysis.truncatedPlies == 0 ? '' : ' ${analysis.truncatedPlies} '
                    'searches hit the time limit, so those numbers are shallower.'}',
          style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
        ),
        const SizedBox(height: 8),
        ...rows,
      ],
    );
  }

  Widget _panel(String message, {VoidCallback? onRetry}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: const TextStyle(color: Color(0xFFB3261E))),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: onRetry,
              style: _largeOutlinedButtonStyle,
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gives the review the same one-move-at-a-time controls on a keyboard as it
/// has on screen. Each callback uses [_GameAnalysisPageState._step], which also
/// speaks the move that lands on the board.
class _StepKeys extends StatelessWidget {
  const _StepKeys({
    required this.onStep,
    required this.onFirst,
    required this.onLast,
    required this.child,
  });

  final ValueChanged<int> onStep;
  final VoidCallback onFirst;
  final VoidCallback onLast;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => onStep(-1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => onStep(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => onStep(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => onStep(1),
        const SingleActivator(LogicalKeyboardKey.space): () => onStep(1),
        const SingleActivator(LogicalKeyboardKey.home): onFirst,
        const SingleActivator(LogicalKeyboardKey.end): onLast,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

class _BoardPanel extends StatelessWidget {
  const _BoardPanel({
    required this.fen,
    required this.lastMove,
    required this.bestMove,
    required this.statusSymbol,
    required this.statusColor,
    required this.inCheck,
    required this.whiteAtBottom,
    required this.onFlip,
    required this.evalCp,
    required this.evalFor,
  });

  final String fen;
  final String? lastMove;
  final String? bestMove;
  final String? statusSymbol;
  final Color? statusColor;
  final bool inCheck;
  final bool whiteAtBottom;
  final VoidCallback onFlip;
  final int? evalCp;
  final String evalFor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              onPressed: onFlip,
              icon: const Icon(Icons.swap_vert),
              tooltip: 'Flip board',
              style: _largeIconButtonStyle,
            ),
          ],
        ),
        // The board is square and the bar matches its height, so the board
        // size is worked out here: the panel sits in a sliver, where a row
        // cannot stretch its children to fill an unbounded height.
        LayoutBuilder(
          builder: (context, constraints) {
            const barWidth = 18.0;
            const gap = 8.0;
            // Cap the board so a wide window does not stretch it, and centre
            // whatever is left over.
            final boardSize = math.min(
              ChessBoardView.maxBoardSize,
              math.max(0.0, constraints.maxWidth - barWidth - gap),
            );
            final panelWidth = boardSize + barWidth + gap;
            return Center(
              child: SizedBox(
                width: panelWidth,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: barWidth,
                      height: boardSize,
                      child: _EvalBar(
                        value: evalCp,
                        orientation: whiteAtBottom,
                      ),
                    ),
                    const SizedBox(width: gap),
                    SizedBox(
                      width: boardSize,
                      height: boardSize,
                      child: ChessBoardView(
                        fen: fen,
                        lastMove: lastMove,
                        bestMove: bestMove,
                        statusSymbol: statusSymbol,
                        statusColor: statusColor,
                        inCheck: inCheck,
                        whiteAtBottom: whiteAtBottom,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (evalCp != null) ...[
          const SizedBox(height: 8),
          Text(
            '${_formatEval(evalCp!)} ($evalFor)',
            style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
          ),
        ],
        const SizedBox(height: 6),
        _BoardLegend(showingEngineMove: bestMove != null),
      ],
    );
  }
}

/// Names the things drawn on the board, so the arrows do not have to be guessed
/// at.
class _BoardLegend extends StatelessWidget {
  const _BoardLegend({required this.showingEngineMove});

  final bool showingEngineMove;

  static const _style = TextStyle(fontSize: 12, color: Color(0xFF5F6368));

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        _legendEntry(const Color(0xFF2F6FD0), 'move that was played'),
        if (showingEngineMove)
          _legendEntry(const Color(0xFF34A853), "engine's move"),
        _legendEntry(const Color(0xFFE23D3D), 'king in check'),
      ],
    );
  }

  Widget _legendEntry(Color colour, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF1B1B1B), width: 0.5),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: _style),
      ],
    );
  }
}

class _EvalBar extends StatelessWidget {
  const _EvalBar({required this.value, required this.orientation});

  final int? value;
  final bool orientation;

  @override
  Widget build(BuildContext context) {
    final cp = value ?? 0;
    final whiteShare = 1 / (1 + math.pow(10, -cp / 400).toDouble());
    return Container(
      width: 18,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFBDBDBD)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: orientation
            ? Column(
                children: [
                  Expanded(
                    flex: (whiteShare * 1000).round().clamp(1, 999),
                    child: const ColoredBox(color: Colors.white),
                  ),
                  Expanded(
                    flex: ((1 - whiteShare) * 1000).round().clamp(1, 999),
                    child: const ColoredBox(color: Color(0xFF303030)),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(
                    flex: ((1 - whiteShare) * 1000).round().clamp(1, 999),
                    child: const ColoredBox(color: Color(0xFF303030)),
                  ),
                  Expanded(
                    flex: (whiteShare * 1000).round().clamp(1, 999),
                    child: const ColoredBox(color: Colors.white),
                  ),
                ],
              ),
      ),
    );
  }
}

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({
    required this.commentator,
    required this.voices,
    required this.rate,
    required this.pitch,
  });

  final Commentator commentator;
  final List<TtsVoice> voices;

  /// Where the sliders open: the last speed and pitch that was chosen.
  final double rate;
  final double pitch;

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  late String _voice = widget.voices
      .firstWhere(
        (voice) => voice.isSelected && voice.isAvailable,
        orElse: () => widget.voices.firstWhere(
          (voice) => voice.isAvailable,
          orElse: () => widget.voices.first,
        ),
      )
      .name;
  late double _rate = widget.rate;
  late double _pitch = widget.pitch;

  /// Speaks the sample line so the change is heard as it is made.
  void _preview() => widget.commentator.speak(
    'Knight to f three. Clear and steady commentary for your review.',
    priority: true,
    interrupt: true,
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text(
              'Commentary voice',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick a voice, then hear it before you keep it. These are the '
              'English voices installed on this phone.',
              style: TextStyle(color: Color(0xFF5F6368)),
            ),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: _voice,
              onChanged: (name) async {
                if (name == null) return;
                setState(() => _voice = name);
                await widget.commentator.selectVoice(name);
                _preview();
              },
              child: Column(
                children: [
                  for (final voice in widget.voices)
                    RadioListTile<String>(
                      value: voice.name,
                      dense: false,
                      contentPadding: EdgeInsets.zero,
                      enabled: voice.isAvailable,
                      title: Text(voice.shortName),
                      subtitle: Text(
                        voice.isAvailable
                            ? '${voice.quality} quality'
                                  '${voice.requiresNetwork ? ', needs internet' : ', on device'}'
                            : '${voice.quality} quality, not downloaded yet',
                        style: TextStyle(
                          fontSize: 12,
                          color: voice.isAvailable
                              ? const Color(0xFF5F6368)
                              : const Color(0xFFB3261E),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 24),
            _slider(
              label: 'Speed',
              value: _rate,
              onChanged: (value) => widget.commentator.setRate(value),
              onChangeEnd: (value) {
                setState(() => _rate = value);
                _preview();
              },
            ),
            _slider(
              label: 'Pitch',
              value: _pitch,
              onChanged: (value) => widget.commentator.setPitch(value),
              onChangeEnd: (value) {
                setState(() => _pitch = value);
                _preview();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: value,
          min: 0.6,
          max: 1.6,
          divisions: 20,
          label: value.toStringAsFixed(2),
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.summary});

  final PerformanceSummary summary;

  @override
  Widget build(BuildContext context) {
    const positive = Color(0xFF1B873F);
    final missed =
        summary.best +
        summary.good +
        summary.inaccuracies +
        summary.mistakes +
        summary.blunders;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: const Color(0xFFF8F9FA),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.insights, size: 20, color: positive),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary.headline,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(summary.overview, style: const TextStyle(height: 1.4)),
            if (missed > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final entry in [
                    ('Best', summary.best, positive),
                    ('Good', summary.good, const Color(0xFF7CB342)),
                    ('Sloppy', summary.inaccuracies, const Color(0xFFE6A817)),
                    ('Mistakes', summary.mistakes, const Color(0xFFEF6C00)),
                    ('Blunders', summary.blunders, const Color(0xFFB3261E)),
                  ])
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            '${entry.$2}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: entry.$3,
                            ),
                          ),
                          Text(
                            entry.$1,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF5F6368),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            if (summary.points.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final point in summary.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6, right: 8),
                        child: Icon(
                          Icons.circle,
                          size: 6,
                          color: Color(0xFF9AA0A6),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          point,
                          style: const TextStyle(height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MoveDetail extends StatelessWidget {
  const _MoveDetail({
    required this.move,
    required this.playerName,
    required this.depth,
    required this.explanation,
    this.notes = const [],
  });

  final AnalyzedMove move;
  final String playerName;
  final int depth;

  /// What happened on this move, in words: the engine's choice, what the move
  /// gave away, and what the opponent's reply wins.
  final String explanation;

  /// The short labels for this move: castling, free pieces, wrong captures.
  final List<MoveNote> notes;

  static const _verdictColors = <MoveVerdict, Color>{
    MoveVerdict.book: Color(0xFF9AA0A6),
    MoveVerdict.wasLost: Color(0xFF9AA0A6),
    MoveVerdict.decisive: Color(0xFF9AA0A6),
    MoveVerdict.best: Color(0xFF1B873F),
    MoveVerdict.good: Color(0xFF7CB342),
    MoveVerdict.inaccuracy: Color(0xFFE6A817),
    MoveVerdict.mistake: Color(0xFFEF6C00),
    MoveVerdict.blunder: Color(0xFFB3261E),
  };

  @override
  Widget build(BuildContext context) {
    final color = _verdictColors[move.verdict] ?? const Color(0xFF9AA0A6);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${move.moveNumber}${move.isWhite ? '.' : '..'} ${move.san}'
              '${move.verdict.symbol.isEmpty ? '' : ' ${move.verdict.symbol}'}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '$playerName — ${move.verdict.label}'
              '${move.countsTowardAverage ? ' (${move.cpl}cp lost)' : ''}',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            if (move.bestMoveSan.isNotEmpty && !move.isBestMove) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x1934A853),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0x8034A853)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  spacing: 6,
                  children: [
                    const Icon(Icons.route, size: 18, color: Color(0xFF27813F)),
                    Text(
                      'Engine move: ${move.bestMoveSan}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final note in notes)
                    Tooltip(
                      message: note.sentence,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: note.isGood
                              ? const Color(0x1A1B873F)
                              : const Color(0x1AF4511E),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          note.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: note.isGood
                                ? const Color(0xFF1B873F)
                                : const Color(0xFFB3261E),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(explanation, style: const TextStyle(height: 1.4)),
            if (move.pv.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Line (depth $depth): ${move.pv}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({
    required this.number,
    required this.white,
    required this.black,
    required this.selected,
  });

  final int number;
  final AnalyzedMove white;
  final AnalyzedMove? black;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: selected ? const Color(0xFFF1F3F4) : null,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$number.',
              style: const TextStyle(color: Color(0xFF5F6368), fontSize: 12),
            ),
          ),
          Expanded(child: _chip(white)),
          const SizedBox(width: 8),
          Expanded(
            child: black == null ? const SizedBox.shrink() : _chip(black!),
          ),
        ],
      ),
    );
  }

  Widget _chip(AnalyzedMove move) {
    final color = _MoveDetail._verdictColors[move.verdict];
    final symbol = move.verdict.symbol;
    return Row(
      children: [
        // The mark reads faster than a coloured dot, so it takes the dot's
        // place; an unjudged move keeps the dot to hold the column still.
        SizedBox(
          width: 14,
          child: symbol.isEmpty
              ? Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                )
              : Text(
                  symbol,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(move.san, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _formatEval(move.evalAfter),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
          ),
        ),
      ],
    );
  }
}

String _formatEval(int cp) {
  final pawns = cp / 100;
  final sign = pawns > 0 ? '+' : '';
  return '$sign${pawns.toStringAsFixed(2)}';
}
