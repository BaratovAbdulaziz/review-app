import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_parsing/path_parsing.dart' as svg;

/// The bundled chess piece set.
///
/// The artwork is Derek Schaab's "Lasker" pieces, a clean modern line set
/// (CC BY 4.0). The twelve SVGs in
/// `assets/pieces/` are named after the FEN letter and the colour of the piece,
/// e.g. `wQ.svg` is a white queen and `bK.svg` a black king. Each set chooses its
/// own viewBox and its own padding, so every path is parsed and keeps the
/// colours it asks for, and each piece is measured from its own ink rather than
/// from the file's frame of reference.
///
/// The set is parsed once per app and shared by every board, because a painter
/// cannot do async work while it paints.
class ChessPieceSet {
  const ChessPieceSet._(this._art, this.maxInkExtent);

  /// Artwork by FEN letter, so `P` is a white pawn and `p` a black one.
  final Map<String, ChessPieceArt> _art;

  /// The biggest effective width or height any piece's ink reaches, in viewBox
  /// units. Every piece is drawn with one scale derived from this, so the set
  /// keeps its own size hierarchy: a pawn stays smaller than a queen instead of
  /// every piece being stretched to fill its square.
  final double maxInkExtent;

  /// The artwork for a FEN letter, or null when it could not be parsed, in
  /// which case the caller draws its own outline instead.
  ChessPieceArt? operator [](String piece) => _art[piece];

  static const Map<String, String> _assetNames = {
    'P': 'wP',
    'N': 'wN',
    'B': 'wB',
    'R': 'wR',
    'Q': 'wQ',
    'K': 'wK',
    'p': 'bP',
    'n': 'bN',
    'b': 'bB',
    'r': 'bR',
    'q': 'bQ',
    'k': 'bK',
  };

  static Future<ChessPieceSet>? _pending;
  static ChessPieceSet? _ready;

  /// The whole set, parsed once. The paths live as long as the process, so
  /// there is nothing to dispose and every board shares one copy.
  static Future<ChessPieceSet> load(BuildContext context) {
    final ready = _ready;
    if (ready != null) return SynchronousFuture(ready);
    return _pending ??= _loadAll(context);
  }

  static Future<ChessPieceSet> _loadAll(BuildContext context) async {
    final bundle = DefaultAssetBundle.of(context);
    final art = <String, ChessPieceArt>{};
    for (final entry in _assetNames.entries) {
      final loaded = await _loadArt(bundle, entry.key, entry.value);
      if (loaded != null) art[entry.key] = loaded;
    }
    // A piece whose asset is missing or malformed is simply left out, so the
    // board falls back to its own outlines for it instead of drawing nothing.
    final maxExtent = art.values.fold<double>(
      0,
      (largest, piece) => math.max(largest, piece.inkExtent),
    );
    return _ready = ChessPieceSet._(art, maxExtent);
  }

  static Future<ChessPieceArt?> _loadArt(
    AssetBundle bundle,
    String letter,
    String name,
  ) async {
    final asset = 'assets/pieces/$name.svg';
    try {
      final source = await bundle.loadString(asset);
      final art = _parse(
        asset,
        source,
        isWhite: letter == letter.toUpperCase(),
        sizeScale: _sizeScaleFor(letter),
      );
      if (art == null) debugPrint('Chess piece $asset drew nothing.');
      return art;
    } catch (error) {
      debugPrint('Could not load chess piece $asset: $error');
      return null;
    }
  }

  /// Reads the paint attributes of every shape in [source], following the group
  /// nesting the way SVG inheritance does.
  static ChessPieceArt? _parse(
    String asset,
    String source, {
    required bool isWhite,
    required double sizeScale,
  }) {
    final shapes = <ChessPieceShape>[];
    // Each open group pushes the attributes it sets, so a shape picks up the
    // innermost value for fill, stroke and stroke-width.
    final groups = <Map<String, String>>[];
    // The root element is inherited by everything too, which is where sets put
    // properties that apply to the whole piece, such as `fill-rule`.
    Map<String, String> root = const {};
    for (final match in _tagPattern.allMatches(source)) {
      if (match.group(1) == null) {
        if (groups.isNotEmpty) groups.removeLast();
        continue;
      }
      final tag = match.group(1)!;
      final attributes = _attributes(match.group(2) ?? '');
      if (tag == 'svg') {
        root = attributes;
        continue;
      }
      if (tag == 'g') {
        groups.add(attributes);
        continue;
      }
      final path = switch (tag) {
        'path' => _path(attributes['d']),
        'circle' => _circle(attributes),
        _ => null,
      };
      if (path == null || path.getBounds().isEmpty) continue;
      if (_resolved(attributes, groups, root, 'fill-rule') == 'evenodd') {
        path.fillType = ui.PathFillType.evenOdd;
      }
      shapes.add(
        ChessPieceShape._(
          path,
          // An unset fill means black in SVG, an unset stroke means none.
          fill: _colour(attributes, groups, root, 'fill', whenUnset: _black),
          outline: _colour(attributes, groups, root, 'stroke'),
          outlineWidth:
              double.tryParse(
                _resolved(attributes, groups, root, 'stroke-width') ?? '',
              ) ??
              1,
        ),
      );
    }
    if (shapes.isEmpty) return null;

    final combined = ui.Path();
    for (final shape in shapes) {
      combined.addPath(shape.path, Offset.zero);
    }
    return ChessPieceArt._(
      shapes,
      combined.getBounds(),
      canvas: _viewBoxOf(source),
      isWhite: isWhite,
      sizeScale: sizeScale,
    );
  }

  /// Lasker gives each SVG a near-identical outer box. These scales restore
  /// the familiar physical hierarchy without changing the artist's outlines:
  /// pawn and rook smallest, queen and king largest.
  static double _sizeScaleFor(String letter) => switch (letter.toUpperCase()) {
    'P' => 0.80,
    'N' => 0.86,
    'B' => 0.90,
    'R' => 0.80,
    'Q' => 0.97,
    'K' => 1.0,
    _ => 1.0,
  };

  /// The square the artwork declares, in its own units.
  ///
  /// Each piece set chooses its own viewBox, so this is read from the file
  /// rather than assumed: everything the board does is measured against the
  /// artwork's ink, and the viewBox is only the artwork's own frame of
  /// reference. A set with none is assumed to be drawn in the classic 45x45.
  static Size _viewBoxOf(String source) {
    final match = RegExp(
      r'viewBox\s*=\s*"([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"',
    ).firstMatch(source);
    if (match == null) return const Size(45, 45);
    return Size(double.parse(match.group(3)!), double.parse(match.group(4)!));
  }

  static final RegExp _tagPattern = RegExp(
    r'<(svg|g|path|circle)\b([^>]*?)/?>|</g>',
  );

  static final RegExp _attributePattern = RegExp(
    r'([a-zA-Z-]+)\s*=\s*"([^"]*)"',
  );

  static const Color _black = Color(0xFF000000);

  static Map<String, String> _attributes(String source) {
    return {
      for (final match in _attributePattern.allMatches(source))
        match.group(1)!: match.group(2)!,
    };
  }

  /// The value [name] resolves to, or null when nothing sets it.
  ///
  /// The shape's own attributes win, then the groups it sits in from the
  /// inside out, then the root element.
  static String? _resolved(
    Map<String, String> attributes,
    List<Map<String, String>> groups,
    Map<String, String> root,
    String name,
  ) {
    var value = attributes[name];
    for (final group in groups.reversed) {
      value ??= group[name];
    }
    return value ?? root[name];
  }

  /// The colour [name] resolves to, or null when it is `none`. [whenUnset] is
  /// used for `fill`, which SVG defines as black.
  static Color? _colour(
    Map<String, String> attributes,
    List<Map<String, String>> groups,
    Map<String, String> root,
    String name, {
    Color? whenUnset,
  }) {
    final value = _resolved(attributes, groups, root, name);
    if (value == null) return whenUnset;
    if (value == 'none') return null;
    return _parseHex(value);
  }

  static ui.Path? _path(String? data) {
    if (data == null) return null;
    final path = ui.Path();
    svg.writeSvgPathDataToPath(data, _PathSink(path));
    return path;
  }

  static ui.Path? _circle(Map<String, String> attributes) {
    final cx = double.tryParse(attributes['cx'] ?? '');
    final cy = double.tryParse(attributes['cy'] ?? '');
    final radius = double.tryParse(attributes['r'] ?? '');
    if (cx == null || cy == null || radius == null || radius <= 0) return null;
    return ui.Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: radius));
  }

  /// Accepts the `#rgb` and `#rrggbb` forms these files use.
  static Color? _parseHex(String value) {
    var digits = value.replaceFirst('#', '').toLowerCase();
    if (digits.length == 3) {
      digits = digits.split('').map((digit) => '$digit$digit').join();
    }
    if (digits.length != 6) return null;
    final channel = int.parse(digits.substring(0, 2), radix: 16);
    final green = int.parse(digits.substring(2, 4), radix: 16);
    final blue = int.parse(digits.substring(4, 6), radix: 16);
    return Color.fromARGB(0xFF, channel, green, blue);
  }
}

/// Feeds the SVG parser's normalised segments into a [ui.Path].
class _PathSink implements svg.PathProxy {
  const _PathSink(this.path);

  final ui.Path path;

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}

/// One parsed piece, ready to be painted.
class ChessPieceArt {
  const ChessPieceArt._(
    this.shapes,
    this.ink, {
    required this.canvas,
    required this.isWhite,
    required this.sizeScale,
  });

  /// The paths that make up the piece, in drawing order.
  final List<ChessPieceShape> shapes;

  /// Bounds of the artwork inside the viewBox. The artwork keeps its own
  /// padding, and it is the ink that belongs in the middle of a square.
  final Rect ink;

  /// The frame the artwork declared, in its own units.
  final Size canvas;

  final bool isWhite;

  /// Scale applied around [ink]'s centre to restore the set's visual hierarchy.
  final double sizeScale;

  /// The biggest painted dimension after [sizeScale] is applied.
  double get inkExtent => math.max(ink.width, ink.height) * sizeScale;
}

/// One path of a piece, with the colours the artwork asks for.
class ChessPieceShape {
  const ChessPieceShape._(
    this.path, {
    required this.fill,
    required this.outline,
    required this.outlineWidth,
  });

  final ui.Path path;

  /// Null when the shape is not filled, i.e. `fill="none"`.
  final Color? fill;

  /// Null when the shape has no outline, i.e. `stroke="none"`.
  final Color? outline;

  /// Outline weight in viewBox units.
  final double outlineWidth;
}
