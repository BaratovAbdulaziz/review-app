import 'package:flutter/material.dart';

import 'api/chess_com_api.dart';
import 'models/chess_game.dart';
import 'settings/username_store.dart';
import 'ui/game_analysis_page.dart';

void main() {
  runApp(const ReviewApp());
}

class ReviewApp extends StatelessWidget {
  const ReviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Review App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.white,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const GamesPage(),
    );
  }
}

class GamesPage extends StatefulWidget {
  const GamesPage({super.key, this.usernameStore});

  /// Replaced by tests; the app uses the on-device store.
  final UsernameStore? usernameStore;

  @override
  State<GamesPage> createState() => _GamesPageState();
}

class _GamesPageState extends State<GamesPage> {
  final ChessComApi _api = ChessComApi();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final UsernameStore _usernameStore;

  String? _username;
  List<String> _archives = const [];
  List<ChessGame> _games = const [];
  int _archivesLoaded = 0;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _usernameStore = widget.usernameStore ?? UsernameStore();
    _restoreUsername();
  }

  /// Restores and immediately loads the last account. A user who began typing
  /// before storage answered wins, so their new input is never overwritten.
  Future<void> _restoreUsername() async {
    final username = await _usernameStore.load();
    if (!mounted || username == null || _controller.text.trim().isNotEmpty) {
      return;
    }
    _controller.text = username;
    await _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final username = _controller.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Enter a username.');
      return;
    }
    if (_loading) return;

    await _usernameStore.save(username);
    if (!mounted) return;

    setState(() {
      _username = username;
      _games = const [];
      _archives = const [];
      _archivesLoaded = 0;
      _error = null;
      _loading = true;
    });

    try {
      final archives = await _api.archives(username);
      if (archives.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No public games found for "$username".';
        });
        return;
      }
      final games = await _api.gamesInArchive(archives.first);
      if (!mounted) return;
      setState(() {
        _archives = archives;
        _archivesLoaded = 1;
        _games = games;
        _loading = false;
      });
    } on ChessComException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _archivesLoaded >= _archives.length) return;
    setState(() => _loadingMore = true);
    try {
      final older = await _api.gamesInArchive(_archives[_archivesLoaded]);
      if (!mounted) return;
      setState(() {
        _archivesLoaded++;
        _games = [..._games, ...older];
        _loadingMore = false;
      });
    } on ChessComException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          textInputAction: TextInputAction.search,
                          autocorrect: false,
                          onSubmitted: (_) => _search(),
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            hintText: 'chess.com username',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _loading ? null : _search,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.search),
                            SizedBox(width: 8),
                            Text('Search'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _games.isEmpty) {
      return _Message(
        icon: Icons.error_outline,
        text: _error!,
        onRetry: _search,
      );
    }
    if (_username == null) {
      return const _Message(
        icon: Icons.search,
        text: 'Search a chess.com username to see their public games.',
      );
    }
    if (_games.isEmpty) {
      return _Message(
        icon: Icons.inbox_outlined,
        text: 'No public games found for "$_username".',
        onRetry: _search,
      );
    }

    final records = _games
        .where((game) => game.url.isNotEmpty)
        .toList(growable: false);

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: records.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == records.length) {
          return _LoadMore(
            loading: _loadingMore,
            hasMore: _archivesLoaded < _archives.length,
            onPressed: _loadMore,
          );
        }
        return _GameTile(game: records[index], username: _username!);
      },
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game, required this.username});

  final ChessGame game;
  final String username;

  @override
  Widget build(BuildContext context) {
    final opponent = game.opponentOf(username);
    final outcome = game.outcomeFor(username);

    final color = switch (outcome) {
      GameOutcome.win => const Color(0xFF1B873F),
      GameOutcome.loss => const Color(0xFFB3261E),
      GameOutcome.draw => const Color(0xFF5F6368),
      GameOutcome.unknown => const Color(0xFF9AA0A6),
    };

    final details = <String>[
      if (game.timeClass.isNotEmpty) game.timeClass,
      if (game.timeControl.isNotEmpty) game.timeControl,
      game.rated ? 'Rated' : 'Casual',
    ].join(' · ');

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE0E0E0)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: color,
          foregroundColor: Colors.white,
          child: Text(switch (outcome) {
            GameOutcome.win => 'W',
            GameOutcome.loss => 'L',
            GameOutcome.draw => 'D',
            GameOutcome.unknown => '?',
          }, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        title: Text(
          opponent.username,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            details,
            if (game.opening != null) game.opening!,
            if (game.endTime != null) _formatDate(game.endTime!),
          ].join('\n'),
          style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
        ),
        trailing: Text(
          '${opponent.rating ?? '—'}',
          style: const TextStyle(color: Color(0xFF5F6368)),
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GameAnalysisPage(game: game, username: username),
          ),
        ),
      ),
    );
  }
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({
    required this.loading,
    required this.hasMore,
    required this.onPressed,
  });

  final bool loading;
  final bool hasMore;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!hasMore && !loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'End of public games',
            style: TextStyle(color: Color(0xFF9AA0A6)),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: loading
            ? const CircularProgressIndicator()
            : OutlinedButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.expand_more),
                label: const Text('Load older games'),
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.onRetry});

  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: const Color(0xFF9AA0A6)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF5F6368)),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
