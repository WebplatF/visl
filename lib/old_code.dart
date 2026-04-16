import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';

// void main() {
//   runApp(const MyApp());
// }

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ConverterPage(),
    );
  }
}

class ConverterPage extends StatefulWidget {
  const ConverterPage({super.key});

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  String? mp4Path;

  bool converting = false;
  bool zipping = false;

  double progress = 0;
  String progressText = "";

  /// ---------------- FFmpeg PATH ----------------
  String get ffmpegPath {
    final root = Directory.current.path;
    return p.join(root, 'ffmpeg', 'ffmpeg.exe');
  }

  /// ---------------- PICK VIDEO ----------------
  Future<void> pickVideo() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4'],
    );

    if (result != null) {
      setState(() {
        mp4Path = result.files.single.path!;
      });
    }
  }

  /// ---------------- VIDEO DURATION ----------------
  Future<double> getDuration() async {
    final result = await Process.run(ffmpegPath, ['-i', mp4Path!]);
    final reg = RegExp(r'Duration: (\d+):(\d+):(\d+\.\d+)');
    final match = reg.firstMatch(result.stderr);
    if (match == null) return 0;

    return double.parse(match.group(1)!) * 3600 +
        double.parse(match.group(2)!) * 60 +
        double.parse(match.group(3)!);
  }

  /// ---------------- FFmpeg ARGS (SAFE) ----------------
  List<String> buildArgsOld(String outDir) {
    return [
      '-y',
      '-hide_banner',
      '-loglevel', 'info',
      '-nostdin',

      '-i', mp4Path!,

      // 🔥 SPLIT VIDEO + AUDIO
      '-filter_complex',
      '[0:v]split=3[v0][v1][v2];'
          '[v0]scale=426:240[v0out];'
          '[v1]scale=854:480[v1out];'
          '[v2]scale=1280:720[v2out];'
          '[0:a]asplit=3[a0][a1][a2]',

      // MAP VIDEO
      '-map', '[v0out]',
      '-map', '[v1out]',
      '-map', '[v2out]',

      // MAP AUDIO (SEPARATE STREAMS!)
      '-map', '[a0]',
      '-map', '[a1]',
      '-map', '[a2]',

      // VIDEO
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '18',
      '-sc_threshold', '0',

      '-b:v:0', '4000k',
      '-b:v:1', '2500k',
      '-b:v:2', '1000k',
      '-maxrate:v:0', '4200k',
      '-maxrate:v:1', '2625k',
      '-maxrate:v:2', '1050k',
      '-bufsize:v:0', '6000k',
      '-bufsize:v:1', '3750k',
      '-bufsize:v:2', '1500k',

      // AUDIO
      '-c:a', 'aac',
      '-b:a', '96k',
      '-ar', '44100',
      '-ac', '2',

      // HLS
      '-f', 'hls',
      '-hls_time', '6',
      '-hls_playlist_type', 'vod',
      '-hls_flags', 'independent_segments',

      '-hls_segment_filename',
      p.join(outDir, 'v%v_%03d.ts'),

      // 🔥 EACH VARIANT HAS ITS OWN AUDIO
      '-var_stream_map',
      'v:0,a:0 v:1,a:1 v:2,a:2',

      '-master_pl_name', 'master.m3u8',

      p.join(outDir, 'v%v.m3u8'),
    ];
  }

  List<String> buildArgs(String mp4Path, String outDir) {
    return [
      '-y',
      '-hide_banner',
      '-loglevel', 'info',
      '-nostdin',
      '-i', '"$mp4Path"',

      // Split video and audio into 3 streams
      '-filter_complex',
      '[0:v]split=3[v0][v1][v2];'
          '[v0]scale=426:240[v0out];'
          '[v1]scale=854:480[v1out];'
          '[v2]scale=1280:720[v2out];'
          '[0:a]asplit=3[a0][a1][a2]',

      // Map video streams
      '-map', '[v0out]',
      '-map', '[v1out]',
      '-map', '[v2out]',

      // Map audio streams
      '-map', '[a0]',
      '-map', '[a1]',
      '-map', '[a2]',

      // Video encoding
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '18', // higher quality for larger size
      '-sc_threshold', '0',

      // Bitrate control (optional)
      '-b:v:0', '4000k',
      '-b:v:1', '2500k',
      '-b:v:2', '1000k',
      '-maxrate:v:0', '4200k',
      '-maxrate:v:1', '2625k',
      '-maxrate:v:2', '1050k',
      '-bufsize:v:0', '6000k',
      '-bufsize:v:1', '3750k',
      '-bufsize:v:2', '1500k',

      // Audio encoding
      '-c:a', 'aac',
      '-b:a', '96k',
      '-ar', '44100',
      '-ac', '2',

      // HLS settings
      '-f', 'hls',
      '-hls_time', '6',
      '-hls_playlist_type', 'vod',
      '-hls_flags', 'independent_segments',
      '-hls_segment_filename', '"${p.join(outDir, 'v%v_%03d.ts')}"',
      '-var_stream_map', 'v:0,a:0 v:1,a:1 v:2,a:2',
      '-master_pl_name', 'master.m3u8',
      '"${p.join(outDir, 'v%v.m3u8')}"',
    ];
  }

  /// ---------------- ZIP ----------------
  /*Future<void> zipFolder(String folderPath) async {
    setState(() {
      zipping = true;
    });

    final zipPath = '$folderPath.zip';
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    final files =
        Directory(folderPath).listSync(recursive: true).whereType<File>();

    for (final f in files) {
      final rel = p.relative(f.path, from: folderPath);
      encoder.addFile(f, rel);
    }

    encoder.close();

    setState(() {
      zipping = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("ZIP created: $zipPath")),
    );
  }*/
  Future<void> zipDirectorySafe(Directory sourceDir, File zipFile) async {
    if (p.isWithin(sourceDir.path, zipFile.path)) {
      throw Exception('ZIP file cannot be inside source directory');
    }

    if (zipFile.existsSync()) {
      zipFile.deleteSync();
    }

    final encoder = ZipFileEncoder();

    try {
      encoder.create(zipFile.path);

      for (final entity in sourceDir.listSync(recursive: true)) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: sourceDir.path);
          encoder.addFile(entity, relativePath);
        }
      }
    } finally {
      encoder.close(); // 🔒 REQUIRED
    }
  }

  /// ---------------- CONVERT ----------------
  Future<void> convert() async {
    if (mp4Path == null) return;

    try {
      final name = p.basenameWithoutExtension(mp4Path!);
      final parentDir = p.dirname(mp4Path!);

      final outDir = p.join(parentDir, '${name}_hls');
      final zipPath = p.join(parentDir, '${name}_hls.zip');

      final dir = Directory(outDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      final duration = await getDuration();

      setState(() {
        converting = true;
        progress = 0;
        progressText = "0 %";
      });

      final process = await Process.start(
        ffmpegPath,
        buildArgsOld(outDir),
        runInShell: false,
      );

      process.stderr.transform(utf8.decoder).listen((line) {
        debugPrint(line);

        final match = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)').firstMatch(line);

        if (match != null && duration > 0) {
          final t = double.parse(match.group(1)!) * 3600 +
              double.parse(match.group(2)!) * 60 +
              double.parse(match.group(3)!);

          setState(() {
            progress = (t / duration).clamp(0.0, 1.0);
            progressText = "${(progress * 100).toStringAsFixed(1)} %";
          });
        }
      });

      final code = await process.exitCode;

      setState(() {
        converting = false;
      });

      // if (code == 0) {
      //   await zipDirectorySafe(
      //     Directory(outDir),
      //     File(zipPath),
      //   );
      //
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(content: Text("HLS ZIP created successfully")),
      //   );
      // } else {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(content: Text("FFmpeg failed: exit code $code")),
      //   );
      // }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  /// ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("MP4 → HLS → ZIP")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ElevatedButton(
              onPressed: pickVideo,
              child: const Text("Select MP4"),
            ),
            const SizedBox(height: 10),
            Text(mp4Path ?? "No file selected"),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: converting ? null : convert,
              child: const Text("Convert"),
            ),
            if (converting) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: progress),
              Text(progressText),
            ],
            if (zipping) ...[
              const SizedBox(height: 20),
              const Text("Zipping files..."),
            ],
          ],
        ),
      ),
    );
  }
}
