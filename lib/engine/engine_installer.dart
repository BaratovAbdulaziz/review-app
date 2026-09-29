import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Describes the Stockfish build this machine can run.
class EngineRelease {
  const EngineRelease({
    required this.asset,
    required this.entryHint,
    required this.archiveExtension,
  });

  /// File name of the release asset.
  final String asset;

  /// Substring that identifies the binary inside the archive.
  final String entryHint;

  final String archiveExtension;

  String get downloadUrl =>
      'https://github.com/official-stockfish/Stockfish/releases/latest/download/$asset';
}

class EngineInstallStatus {
  const EngineInstallStatus({
    required this.isSupported,
    required this.isInstalled,
    this.binaryPath,
    this.installedVersion,
  });

  final bool isSupported;
  final bool isInstalled;
  final String? binaryPath;
  final String? installedVersion;

  static const unsupported = EngineInstallStatus(
    isSupported: false,
    isInstalled: false,
  );
}

class EngineInstaller {
  const EngineInstaller();

  static const _versionFile = 'version.txt';

  /// Where Android puts a native library that was shipped inside the APK.
  static const _nativeLibraryDirChannel = MethodChannel(
    'com.example.review_app/native_library_dir',
  );

  /// The engine as it is packaged: a native library, so that Android extracts
  /// it somewhere it is allowed to run.
  static const _bundledEngineName = 'libstockfish.so';

  /// The engine that came with the app, or null on a platform without one.
  Future<EngineInstallStatus?> _bundledStatus() async {
    if (!Platform.isAndroid) return null;
    final String? directory;
    try {
      directory = await _nativeLibraryDirChannel.invokeMethod<String>(
        'getNativeLibraryDir',
      );
    } on MissingPluginException {
      return null;
    } on Object {
      return null;
    }
    if (directory == null || directory.isEmpty) return null;
    final binary = File(
      '$directory${Platform.pathSeparator}$_bundledEngineName',
    );
    if (!binary.existsSync()) return null;
    await _deleteStaleDownload();
    return EngineInstallStatus(
      isSupported: true,
      isInstalled: true,
      binaryPath: binary.path,
      installedVersion: 'bundled with the app',
    );
  }

  /// Removes an engine downloaded by an earlier build. It could never have run
  /// on Android, and it is large enough to be worth reclaiming.
  Future<void> _deleteStaleDownload() async {
    try {
      final directory = await _engineDirectory();
      if (!directory.existsSync()) return;
      for (final entity in directory.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException {
          // Anything we cannot remove is not worth failing over.
        }
      }
    } on Object {
      // No data directory means there is nothing stale to clear.
    }
  }

  EngineRelease? releaseForCurrentPlatform() {
    if (Platform.isLinux) {
      final arm =
          Platform.version.contains('arm64') ||
          Platform.version.contains('aarch64');
      return EngineRelease(
        asset: arm
            ? 'stockfish-linux-arm64-universal.tar.gz'
            : 'stockfish-linux-x86-64-universal.tar.gz',
        entryHint: arm
            ? 'stockfish-linux-arm64-universal'
            : 'stockfish-linux-x86-64-universal',
        archiveExtension: '.tar.gz',
      );
    }
    if (Platform.isMacOS) {
      return const EngineRelease(
        asset: 'stockfish-macos-universal.tar.gz',
        entryHint: 'stockfish-macos-universal',
        archiveExtension: '.tar.gz',
      );
    }
    if (Platform.isWindows) {
      return const EngineRelease(
        asset: 'stockfish-windows-x86-64-universal.zip',
        entryHint: '.exe',
        archiveExtension: '.zip',
      );
    }
    // Android is not here on purpose. It has Stockfish builds, but a binary
    // downloaded to the app's data directory cannot be executed there at all, so
    // Android uses the copy bundled in the APK (see _bundledStatus) instead of
    // downloading one that would fail to start.
    return null;
  }

  Future<Directory> _engineDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}engine');
  }

  Future<EngineInstallStatus> status() async {
    final bundled = await _bundledStatus();
    if (bundled != null) return bundled;

    final release = releaseForCurrentPlatform();
    if (release == null) return EngineInstallStatus.unsupported;

    final directory = await _engineDirectory();
    final binary = File(_binaryPath(directory, release));
    if (!binary.existsSync()) {
      return const EngineInstallStatus(isSupported: true, isInstalled: false);
    }
    final marker = File(
      '${directory.path}${Platform.pathSeparator}$_versionFile',
    );
    return EngineInstallStatus(
      isSupported: true,
      isInstalled: true,
      binaryPath: binary.path,
      installedVersion: marker.existsSync()
          ? marker.readAsStringSync().trim()
          : 'unknown',
    );
  }

  /// Downloads and extracts the engine. [onProgress] receives 0..1.
  Future<EngineInstallStatus> install({
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    // Android already ships the engine inside the APK, so there is nothing to
    // download: it is extracted by the installer to a path that can be run.
    final bundled = await _bundledStatus();
    if (bundled != null) return bundled;

    final release = releaseForCurrentPlatform();
    if (release == null) {
      throw StateError('Stockfish is not available for this platform');
    }

    final directory = await _engineDirectory();
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final binary = File(_binaryPath(directory, release));
    final archiveFile = File(
      '${directory.path}${Platform.pathSeparator}download${release.archiveExtension}',
    );

    onStage?.call('Downloading ${release.asset}');
    await _download(release.downloadUrl, archiveFile, onProgress);

    onStage?.call('Extracting engine');
    final bytes = await archiveFile.readAsBytes();
    final Archive archive = release.archiveExtension.endsWith('.zip')
        ? ZipDecoder().decodeBytes(bytes)
        : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));

    final entry = _findBinary(archive, release);
    if (entry == null) {
      await archiveFile.delete();
      throw StateError('Could not find the engine binary in the archive');
    }

    await binary.writeAsBytes(entry.content as List<int>, flush: true);
    await archiveFile.delete();
    await _makeExecutable(binary);

    final version = await _readVersion(binary);
    await File('${directory.path}${Platform.pathSeparator}$_versionFile')
        .writeAsString(version);
    onProgress?.call(1);

    return EngineInstallStatus(
      isSupported: true,
      isInstalled: true,
      binaryPath: binary.path,
      installedVersion: version,
    );
  }

  Future<void> uninstall() async {
    final release = releaseForCurrentPlatform();
    if (release == null) return;
    final directory = await _engineDirectory();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  String _binaryPath(Directory directory, EngineRelease release) {
    final name = release.entryHint.endsWith('.exe')
        ? 'stockfish.exe'
        : 'stockfish';
    return '${directory.path}${Platform.pathSeparator}$name';
  }

  Future<void> _download(
    String url,
    File target,
    void Function(double progress)? onProgress,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..headers['Accept'] = 'application/octet-stream';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 120));
      if (response.statusCode != 200) {
        throw StateError('Download failed (HTTP ${response.statusCode})');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response.stream) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received < total) {
        throw StateError('Download incomplete');
      }
    } finally {
      client.close();
    }
  }

  ArchiveFile? _findBinary(Archive archive, EngineRelease release) {
    final matches = archive.files
        .where((file) => file.isFile && !file.name.startsWith('__MACOSX'))
        .where((file) => file.name.contains(release.entryHint))
        .toList();
    if (matches.isNotEmpty) {
      matches.sort((a, b) => b.size.compareTo(a.size));
      return matches.first;
    }
    return archive.files
        .where((file) => file.isFile && !file.name.startsWith('__MACOSX'))
        .where((file) => file.size > 1024 * 1024)
        .fold<ArchiveFile?>(null, (best, file) {
          if (best == null || file.size > best.size) return file;
          return best;
        });
  }

  Future<void> _makeExecutable(File binary) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['+x', binary.path]);
    if (result.exitCode != 0) {
      throw StateError('Could not make the engine executable');
    }
  }

  Future<String> _readVersion(File binary) async {
    try {
      final process = await Process.start(binary.path, const ['--version']);
      final output =
          (await process.stdout
                  .transform(const Utf8Decoder(allowMalformed: true))
                  .join()
                  .timeout(const Duration(seconds: 10)))
              .trim();
      process.kill();
      final line = output.split('\n').first.trim();
      return line.isEmpty ? 'unknown' : line;
    } on Object {
      return 'unknown';
    }
  }
}
