import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MP4 → HLS Converter',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF5F6FA),
        fontFamily: 'Segoe UI',
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF2563EB),
          surface: Color(0xFFFFFFFF),
        ),
      ),
      home: const ConverterPage(),
    );
  }
}

// ─────────────────────────────────────────────
//  THEME CONSTANTS  (light palette)
// ─────────────────────────────────────────────
class _C {
  static const bg          = Color(0xFFF5F6FA);
  static const surface     = Color(0xFFFFFFFF);
  static const surfaceLow  = Color(0xFFF8F9FC);
  static const border      = Color(0xFFE2E5EF);
  static const titleBar    = Color(0xFFECEDF2);
  static const titleBorder = Color(0xFFDDE0EA);

  static const blue        = Color(0xFF2563EB);
  static const blueDark    = Color(0xFF1D4ED8);
  static const blueFill    = Color(0xFFEEF2FF);
  static const blueBorder  = Color(0xFFC7D2FE);
  static const blueLight   = Color(0xFFDBEAFE);

  static const green       = Color(0xFF16A34A);
  static const greenFill   = Color(0xFFDCFCE7);
  static const greenBorder = Color(0xFFBBF7D0);
  static const greenBg     = Color(0xFFF0FDF4);

  static const amber       = Color(0xFFD97706);
  static const amberFill   = Color(0xFFFEF3C7);

  static const red         = Color(0xFFDC2626);
  static const redFill     = Color(0xFFFEE2E2);

  // text
  static const t1 = Color(0xFF1E293B);
  static const t2 = Color(0xFF374151);
  static const t3 = Color(0xFF64748B);
  static const t4 = Color(0xFF9DA3B4);
}

// ─────────────────────────────────────────────
//  VARIANT STATUS
// ─────────────────────────────────────────────
enum VariantStatus { waiting, encoding, done }

class HlsVariant {
  final String label;
  final String resolution;
  final String bitrate;
  VariantStatus status;

  HlsVariant({
    required this.label,
    required this.resolution,
    required this.bitrate,
    this.status = VariantStatus.waiting,
  });
}

// ─────────────────────────────────────────────
//  PAGE
// ─────────────────────────────────────────────
class ConverterPage extends StatefulWidget {
  const ConverterPage({super.key});
  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  String? mp4Path;
  String? mp4Name;
  String? mp4Size;

  bool converting = false;
  double progress = 0;
  String statusText   = 'Ready';
  String speedText    = '—';
  String elapsedText  = '0:00';
  String etaText      = '—';
  String segmentsText = '—';
  DateTime? _startTime;

  final List<HlsVariant> variants = [
    HlsVariant(label: '240p', resolution: '426×240', bitrate: '1000k'),
    HlsVariant(label: '480p', resolution: '854×480', bitrate: '2500k'),
    HlsVariant(label: '720p', resolution: '1280×720', bitrate: '4000k'),
  ];

  String get ffmpegPath {
    final root = Directory.current.path;
    return p.join(root, 'ffmpeg', 'ffmpeg.exe');
  }

  // ── pick file ──────────────────────────────
  Future<void> pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4'],
    );
    if (result != null) {
      final file  = File(result.files.single.path!);
      final bytes = await file.length();
      setState(() {
        mp4Path = result.files.single.path!;
        mp4Name = p.basename(mp4Path!);
        mp4Size = _formatBytes(bytes);
        _resetProgress();
      });
    }
  }

  void _clearFile() => setState(() {
        mp4Path = null;
        mp4Name = null;
        mp4Size = null;
        _resetProgress();
      });

  void _resetProgress() {
    progress    = 0;
    statusText  = 'Ready';
    speedText   = '—';
    elapsedText = '0:00';
    etaText     = '—';
    segmentsText = '—';
    for (final v in variants) v.status = VariantStatus.waiting;
  }

  // ── duration ────────────────────────────────
  Future<double> _getDuration() async {
    final result = await Process.run(ffmpegPath, ['-i', mp4Path!]);
    final reg    = RegExp(r'Duration: (\d+):(\d+):(\d+\.\d+)');
    final match  = reg.firstMatch(result.stderr);
    if (match == null) return 0;
    return double.parse(match.group(1)!) * 3600 +
        double.parse(match.group(2)!) * 60 +
        double.parse(match.group(3)!);
  }

  // ── convert ─────────────────────────────────
  Future<void> convert() async {
    if (mp4Path == null || converting) return;

    final name      = p.basenameWithoutExtension(mp4Path!);
    final parentDir = p.dirname(mp4Path!);
    final outDir    = p.join(parentDir, '${name}_hls');

    Directory(outDir).createSync(recursive: true);
    final duration = await _getDuration();

    setState(() {
      converting = true;
      progress   = 0;
      statusText = 'Initializing encoder…';
      _startTime = DateTime.now();
      for (final v in variants) v.status = VariantStatus.waiting;
    });

    final process = await Process.start(
      ffmpegPath, _buildArgs(outDir), runInShell: false,
    );

    process.stderr.transform(utf8.decoder).listen((chunk) {
      for (final line in chunk.split('\n')) _parseLine(line, duration);
    });

    final code = await process.exitCode;

    setState(() {
      converting = false;
      if (code == 0) {
        progress   = 1.0;
        statusText = 'Conversion complete';
        for (final v in variants) v.status = VariantStatus.done;
      } else {
        statusText = 'Error (exit code $code)';
      }
    });
  }

  void _parseLine(String line, double duration) {
    final timeMatch = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)').firstMatch(line);
    if (timeMatch == null || duration <= 0) return;

    final t = double.parse(timeMatch.group(1)!) * 3600 +
        double.parse(timeMatch.group(2)!) * 60 +
        double.parse(timeMatch.group(3)!);

    final prog    = (t / duration).clamp(0.0, 1.0);
    final elapsed = DateTime.now().difference(_startTime!).inSeconds;
    final eta     = prog > 0.01 ? ((elapsed / prog) * (1 - prog)).round() : null;

    final speedMatch = RegExp(r'speed=\s*([\d.]+)x').firstMatch(line);
    final spd = speedMatch != null ? '${speedMatch.group(1)}x' : speedText;

    final segMatch = RegExp(r'Opening.*v(\d+)_(\d+)\.ts').firstMatch(line);
    final segNum   = segMatch != null ? int.tryParse(segMatch.group(2)!) : null;
    final totalSeg = (duration / 6).ceil();
    final segStr   = segNum != null ? '$segNum / $totalSeg' : segmentsText;

    VariantStatus v0, v1, v2;
    if (prog < 0.33) {
      v0 = VariantStatus.encoding; v1 = VariantStatus.waiting;  v2 = VariantStatus.waiting;
    } else if (prog < 0.66) {
      v0 = VariantStatus.done;     v1 = VariantStatus.encoding; v2 = VariantStatus.waiting;
    } else {
      v0 = VariantStatus.done;     v1 = VariantStatus.done;     v2 = VariantStatus.encoding;
    }

    setState(() {
      progress     = prog;
      speedText    = spd;
      elapsedText  = _formatDuration(elapsed);
      etaText      = eta != null ? _formatDuration(eta) : '—';
      segmentsText = segStr;
      statusText   = _statusLabel(prog);
      variants[0].status = v0;
      variants[1].status = v1;
      variants[2].status = v2;
    });
  }

  String _statusLabel(double p) {
    if (p < 0.05) return 'Initializing encoder…';
    if (p < 0.33) return 'Encoding 240p stream…';
    if (p < 0.66) return 'Encoding 480p stream…';
    if (p < 0.95) return 'Encoding 720p stream…';
    return 'Finalizing HLS segments…';
  }

  List<String> _buildArgs(String outDir) => [
    '-y', '-hide_banner', '-loglevel', 'info', '-nostdin',
    '-i', mp4Path!,
    '-filter_complex',
    '[0:v]split=3[v0][v1][v2];'
        '[v0]scale=426:240[v0out];'
        '[v1]scale=854:480[v1out];'
        '[v2]scale=1280:720[v2out];'
        '[0:a]asplit=3[a0][a1][a2]',
    '-map', '[v0out]', '-map', '[v1out]', '-map', '[v2out]',
    '-map', '[a0]',    '-map', '[a1]',    '-map', '[a2]',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-sc_threshold', '0',
    '-b:v:0', '4000k',  '-b:v:1', '2500k',  '-b:v:2', '1000k',
    '-maxrate:v:0', '4200k', '-maxrate:v:1', '2625k', '-maxrate:v:2', '1050k',
    '-bufsize:v:0', '6000k', '-bufsize:v:1', '3750k', '-bufsize:v:2', '1500k',
    '-c:a', 'aac', '-b:a', '96k', '-ar', '44100', '-ac', '2',
    '-f', 'hls', '-hls_time', '6', '-hls_playlist_type', 'vod',
    '-hls_flags', 'independent_segments',
    '-hls_segment_filename', p.join(outDir, 'v%v_%03d.ts'),
    '-var_stream_map', 'v:0,a:0 v:1,a:1 v:2,a:2',
    '-master_pl_name', 'master.m3u8',
    p.join(outDir, 'v%v.m3u8'),
  ];

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      body: Column(
        children: [
          const _TitleBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // File picker card
                  _SectionCard(
                    title: 'Source video',
                    child: mp4Path == null
                        ? _DropArea(onTap: pickVideo)
                        : _FileRow(name: mp4Name!, size: mp4Size!, onRemove: _clearFile),
                  ),
                  const SizedBox(height: 14),

                  // Variants card
                  _SectionCard(
                    title: 'Output variants',
                    child: Row(
                      children: variants
                          .map((v) => Expanded(child: _VariantChip(variant: v)))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Progress card
                  _SectionCard(
                    title: 'Conversion progress',
                    child: _ProgressPanel(
                      progress: progress,
                      statusText: statusText,
                      speedText: speedText,
                      elapsedText: elapsedText,
                      etaText: etaText,
                      segmentsText: segmentsText,
                      isConverting: converting,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Stats card
                  _SectionCard(
                    title: 'Encoding settings',
                    child: GridView.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 3.5,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: const [
                        _StatBox(icon: Icons.speed,      label: 'Codec',        value: 'H.264 · veryfast', bg: _C.blueLight,  iconColor: _C.blue),
                        _StatBox(icon: Icons.audiotrack, label: 'Audio',        value: 'AAC · 96k',        bg: _C.greenFill,  iconColor: _C.green),
                        _StatBox(icon: Icons.segment,    label: 'Segment time', value: '6s HLS',           bg: _C.amberFill,  iconColor: _C.amber),
                        _StatBox(icon: Icons.tune,       label: 'CRF quality',  value: 'CRF 18',           bg: _C.redFill,    iconColor: _C.red),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Action buttons
                  Row(children: [
                    _IconBtn(icon: Icons.folder_open, onTap: pickVideo),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ConvertButton(
                        enabled: mp4Path != null && !converting,
                        onTap: convert,
                      ),
                    ),
                  ]),

                  // Success banner
                  if (!converting && progress == 1.0) ...[
                    const SizedBox(height: 14),
                    const _SuccessBanner(),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TITLE BAR
// ─────────────────────────────────────────────
class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      color: _C.titleBar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _C.titleBorder)),
      ),
      child: Row(children: [
        _WinDot(color: const Color(0xFFFF5F57)),
        const SizedBox(width: 6),
        _WinDot(color: const Color(0xFFFEBC2E)),
        const SizedBox(width: 6),
        _WinDot(color: const Color(0xFF28C840)),
        const SizedBox(width: 12),
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Icon(Icons.videocam, color: Colors.white, size: 13),
        ),
        const SizedBox(width: 8),
        const Text('MP4 → HLS Converter',
            style: TextStyle(fontSize: 12, color: _C.t4, letterSpacing: 0.4)),
      ]),
    );
  }
}

class _WinDot extends StatelessWidget {
  final Color color;
  const _WinDot({required this.color});
  @override
  Widget build(BuildContext context) =>
      Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

// ─────────────────────────────────────────────
//  SECTION CARD
// ─────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        border: Border.all(color: _C.border),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 4, height: 4, decoration: const BoxDecoration(color: _C.blue, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.0, color: _C.t4)),
        ]),
        const SizedBox(height: 14),
        child,
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  DROP AREA
// ─────────────────────────────────────────────
class _DropArea extends StatefulWidget {
  final VoidCallback onTap;
  const _DropArea({required this.onTap});
  @override State<_DropArea> createState() => _DropAreaState();
}

class _DropAreaState extends State<_DropArea> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit:  (_) => setState(() => hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 30),
          decoration: BoxDecoration(
            color: hovered ? _C.blueFill : _C.surfaceLow,
            border: Border.all(
              color: hovered ? _C.blue.withOpacity(0.5) : const Color(0xFFC5CBE0),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(color: _C.blueFill, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.upload_file, color: _C.blue, size: 22),
            ),
            const SizedBox(height: 10),
            const Text('Click to browse or drop MP4 here',
                style: TextStyle(fontSize: 13, color: _C.t2, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            const Text('Supports .mp4 files', style: TextStyle(fontSize: 11, color: _C.t4)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  FILE ROW
// ─────────────────────────────────────────────
class _FileRow extends StatelessWidget {
  final String name, size;
  final VoidCallback onRemove;
  const _FileRow({required this.name, required this.size, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _C.blueFill,
        border: Border.all(color: _C.blueBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: _C.blueLight, borderRadius: BorderRadius.circular(7)),
          child: const Icon(Icons.video_file, color: _C.blue, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _C.t1), overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(size, style: const TextStyle(fontSize: 11, color: _C.t4)),
        ])),
        IconButton(icon: const Icon(Icons.close, size: 16), onPressed: onRemove, color: _C.t4, splashRadius: 16),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  VARIANT CHIP
// ─────────────────────────────────────────────
class _VariantChip extends StatelessWidget {
  final HlsVariant variant;
  const _VariantChip({required this.variant});

  @override
  Widget build(BuildContext context) {
    Color bgColor; Color textColor; String statusLabel; IconData statusIcon;
    switch (variant.status) {
      case VariantStatus.done:
        bgColor = _C.greenFill; textColor = _C.green;
        statusLabel = 'done'; statusIcon = Icons.check_circle_outline; break;
      case VariantStatus.encoding:
        bgColor = _C.blueFill; textColor = _C.blue;
        statusLabel = 'encoding'; statusIcon = Icons.circle; break;
      case VariantStatus.waiting:
        bgColor = const Color(0xFFF1F5F9); textColor = _C.t4;
        statusLabel = 'waiting'; statusIcon = Icons.radio_button_unchecked; break;
    }

    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _C.surfaceLow,
        border: Border.all(color: _C.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text(variant.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _C.t1)),
        const SizedBox(height: 2),
        Text('${variant.resolution} · ${variant.bitrate}', style: const TextStyle(fontSize: 10, color: _C.t4)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(statusIcon, size: 9, color: textColor),
            const SizedBox(width: 3),
            Text(statusLabel, style: TextStyle(fontSize: 10, color: textColor)),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  PROGRESS PANEL
// ─────────────────────────────────────────────
class _ProgressPanel extends StatelessWidget {
  final double progress;
  final String statusText, speedText, elapsedText, etaText, segmentsText;
  final bool isConverting;

  const _ProgressPanel({
    required this.progress, required this.statusText, required this.speedText,
    required this.elapsedText, required this.etaText, required this.segmentsText,
    required this.isConverting,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).toStringAsFixed(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          if (isConverting) ...[_PulseDot(), const SizedBox(width: 6)],
          Text(statusText, style: const TextStyle(fontSize: 12, color: _C.t3)),
        ]),
        Text('$pct%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _C.blue,
            fontFeatures: [FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 8,
          backgroundColor: _C.border,
          valueColor: const AlwaysStoppedAnimation<Color>(_C.blue),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        _MetaItem(label: 'Speed',    value: speedText),
        const SizedBox(width: 18),
        _MetaItem(label: 'Elapsed',  value: elapsedText),
        const SizedBox(width: 18),
        _MetaItem(label: 'ETA',      value: etaText),
        const SizedBox(width: 18),
        _MetaItem(label: 'Segments', value: segmentsText),
      ]),
    ]);
  }
}

class _PulseDot extends StatefulWidget {
  @override State<_PulseDot> createState() => _PulseDotState();
}
class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
    _anim = Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _anim,
    child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: _C.blue, shape: BoxShape.circle)),
  );
}

class _MetaItem extends StatelessWidget {
  final String label, value;
  const _MetaItem({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Row(children: [
    Text('$label ', style: const TextStyle(fontSize: 11, color: _C.t4)),
    Text(value,     style: const TextStyle(fontSize: 11, color: _C.t2, fontWeight: FontWeight.w500)),
  ]);
}

// ─────────────────────────────────────────────
//  STAT BOX
// ─────────────────────────────────────────────
class _StatBox extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color bg, iconColor;
  const _StatBox({required this.icon, required this.label, required this.value, required this.bg, required this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _C.surfaceLow,
        border: Border.all(color: _C.border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, color: iconColor, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label.toUpperCase(), style: const TextStyle(fontSize: 9, color: _C.t4, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
            const SizedBox(height: 1),
            Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _C.t1)),
          ],
        )),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  ICON BUTTON
// ─────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: _C.surface,
        border: Border.all(color: _C.border),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: Icon(icon, color: _C.t4, size: 18),
    ),
  );
}

// ─────────────────────────────────────────────
//  CONVERT BUTTON
// ─────────────────────────────────────────────
class _ConvertButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _ConvertButton({required this.enabled, required this.onTap});
  @override State<_ConvertButton> createState() => _ConvertButtonState();
}

class _ConvertButtonState extends State<_ConvertButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:  widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp:    widget.enabled ? (_) { setState(() => _pressed = false); widget.onTap(); } : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedOpacity(
          opacity: widget.enabled ? 1.0 : 0.38,
          duration: const Duration(milliseconds: 200),
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1D4ED8), Color(0xFF2563EB)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: widget.enabled
                  ? [const BoxShadow(color: Color(0x402563EB), blurRadius: 8, offset: Offset(0, 3))]
                  : null,
            ),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text('Convert to HLS', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SUCCESS BANNER
// ─────────────────────────────────────────────
class _SuccessBanner extends StatelessWidget {
  const _SuccessBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _C.greenBg,
        border: Border.all(color: _C.greenBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_outline, color: _C.green.withOpacity(0.9), size: 16),
        const SizedBox(width: 8),
        const Text('Conversion complete! HLS files saved to output folder.',
            style: TextStyle(fontSize: 13, color: _C.green)),
      ]),
    );
  }
}
