# Chess Game Review

A Flutter app that pulls a player's public games from Chess.com, installs
Stockfish on the device, and reviews each game move by move with engine
evaluations.

## What it does

- Searches Chess.com by username and lists the most recent monthly archives
  ("Load older games" pulls the next month).
- Opens any game and replays the PGN on a board.
- Downloads and unpacks the official Stockfish build on first use, then keeps it
  in the app's support directory.
- Runs the engine over every ply and marks each move as book, best, good,
  inaccuracy, mistake or blunder, with the evaluation before and after the
  move, the engine's preferred move, and its principal variation.
- Explains every move in words, both on screen and out loud: who played it, what
  the engine wanted instead, how much the move gave away, where the position
  ended up, and what the opponent's best reply wins. The reply is searched one
  ply deeper and played out on the board, so the material it reports is counted
  from the position rather than read out of the notation.
- Step through the game with the on-screen controls or Left/Right, Up/Down,
  Space, Home and End. Each move reached this way is spoken when local TTS is
  enabled; flip the board and change the search depth (8 to 16).
- The board marks the move that was played in blue. When the engine preferred a
  different move, its green "Show on board" preview returns to the position
  before the move so both arrows are legal and directly comparable.
- Runs one Stockfish process per core, so the plies of a game are searched in
  parallel instead of one after another, and fills the move list in as results
  land rather than waiting for the whole game.
- Draws the pieces with the Cburnett set, which ships with the app.
- Speaks the review out loud with a local text to speech engine: the speaker
  button in the app bar narrates the progress, the moves that lost material and
  the closing summary. Nothing leaves the machine.

## Running it

```sh
flutter pub get
flutter test
flutter run -d linux      # or windows, macos
```

Engine analysis runs the Stockfish binary as a child process, so it only works
on the desktop builds. The web build still lists games and replays PGNs, but
says that analysis needs the desktop app.

The first analysis downloads about 80 MB, so it needs a network connection.
Later runs are offline.

The last searched Chess.com username is stored locally and loaded automatically
when the app opens.

## Speech

Commentary is optional and stays muted until the speaker button is pressed.

```sh
tool/install_tts.sh        # downloads piper and a voice into ~/.local/share
```

The script needs no root: it puts a single piper binary and one voice inside
`~/.local/share/review_app/tts`. The app then finds them by itself and plays
piper's audio through `paplay`, `pw-play` or `aplay`, whichever is installed.
A machine with no piper falls back to `espeak-ng` if that is present, and the
speaker button stays disabled with the reason in its tooltip if neither is
available. `PIPER_TTS_BIN` overrides the piper path.

## How the scores work

- The centipawn loss of a move is the difference between the engine's best
  score and the score of the move that was played, both from the side to move's
  point of view and from the same multi-PV search, so the numbers are directly
  comparable.
- A move the search never returns is re-searched a few plies shallower on its
  own, which is enough to size the loss.
- Moves in the first 8 plies are reported as book. A move played from a
  position that is already lost (300 centipawns or more down for the mover) is
  reported as "already lost" instead of being graded, and a move where the
  engine saw a forced result is reported as "decisive". Neither counts towards
  the average centipawn loss, because in those positions the score measures the
  game rather than the move.
- The evaluations are clamped to +/-1500 centipawns for the eval bar, and mate
  scores are folded into that range.
- The reply behind an explanation is found by a second, shallower search of the
  position after the move, and only for the moves that gave something away
  (inaccuracies, mistakes and blunders): a good move has nothing to explain, and
  a search of every ply would double the cost of a review. A move whose position
  the search never returns is left without a reply rather than given a guess.

## Known limits

- Games that start from a Chess960 position cannot be replayed, because the
  move library only understands standard castling. The app says so instead of
  failing silently.
- Evaluations come from a single shallow search, so quiet moves in a balanced
  position are only roughly classified.
- Analysis uses one worker per core, less two so the desktop stays responsive,
  capped at 8. Each worker is a separate single-threaded Stockfish process, so a
  search is not faster than a single-threaded search of the same depth; the game
  as a whole just finishes several times sooner.
- Only the most recent archives are listed; there is no full history view.

## Licences

The app bundles the official [Stockfish](https://stockfishchess.org/) binaries for
arm64-v8a and armeabi-v7a in `android/app/src/main/jniLibs`. Stockfish is
licensed under the GNU General Public License v3, which applies to the binary
the app runs. There is no x86_64 build, so an x86_64 Android emulator cannot
analyse.

The piece set in `assets/pieces` is **Lasker** by Derek Schaab, a clean modern
line set, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). If you redistribute
this app, keep that notice and credit Derek Schaab: the licence requires
attribution, though unlike GPL it does not extend to the rest of the app.
`tool/prepare_pieces.py` normalises the upstream files into the plain paths the
app's parser reads.

`tool/install_tts.sh` downloads [piper](https://github.com/rhasspy/piper)
(MIT) and a voice from
[piper-voices](https://huggingface.co/rhasspy/piper-voices) at install time,
neither of which is redistributed here.
