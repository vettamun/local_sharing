// lib/main.dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import 'server.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalShareApp());
}

class LocalShareApp extends StatelessWidget {
  const LocalShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Share (macOS)',
      theme: ThemeData.light(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _server = ServerManager();
  String? _ip;
  int? _port;
  String? _url;
  List<File> _selected = [];
  String? _uploadDir;

  @override
  void initState() {
    super.initState();
    _resolveIp();
  }

  Future<void> _resolveIp() async {
    // Prefer WiFi IP; fallback to a non-loopback IPv4
    String? ip = await NetworkInfo().getWifiIP();
    if (ip == null) {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            ip = addr.address;
            break;
          }
        }
        if (ip != null) break;
      }
    }
    setState(() => _ip = ip ?? '127.0.0.1');
  }

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (res == null || res.files.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File selection canceled')),
        );
        return;
      }
      final files = res.files
          .where((e) => e.path != null)
          .map((e) => File(e.path!))
          .toList();
      if (files.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No usable paths returned')),
        );
        return;
      }
      setState(() => _selected = files);
      await _server.setSharedFiles(files);
    } catch (e, st) {
      debugPrint('pickFiles() failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file picker: $e')),
      );
    }
  }

  Future<void> _chooseUploadDir() async {
    final dir = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose upload destination');
    if (dir != null) {
      setState(() => _uploadDir = dir);
      _server.setUploadDir(dir);
    }
  }

  Future<void> _deleteTempFile(File file) async {
    final removed = _selected.remove(file);
    if (removed) {
      setState(() {});
    }
  }

  Future<void> _start() async {
    if (_selected.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one file to share.')),
      );
      return;
    }
    try {
      // Bind to anyIPv4 so LAN devices can reach it
      final port =
          await _server.start(port: 0, bindAddress: InternetAddress.anyIPv4);

      // If you share exactly 1 file, make the QR open it directly
      bool isSingle = _selected.length == 1;
      final base = 'http://${_ip ?? 'localhost'}:$port';
      final effectiveUrl = isSingle ? '$base/download/0' : base;

      if (!mounted) return;
      setState(() {
        _port = port;
        _url = effectiveUrl;
      });
    } catch (e, st) {
      debugPrint('Server start failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start server: $e')),
      );
    }
  }

  Future<void> _stop() async {
    await _server.stop();
    if (!mounted) return;
    setState(() {
      _port = null;
      _url = null;
    });
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = _server.isRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Share (macOS)'),
        actions: [
          if (_url != null)
            IconButton(
              tooltip: 'Open in browser',
              onPressed: () => _openUrl(_url!),
              icon: const Icon(Icons.open_in_new),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text('Local IP: ${_ip ?? 'resolving...'}'),
            const SizedBox(height: 12),

            // Controls
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Pick Files'),
                  onPressed: running ? null : _pickFiles,
                ),
                ElevatedButton.icon(
                  icon: Icon(running ? Icons.stop_circle : Icons.play_circle),
                  label: Text(running ? 'Stop Server' : 'Start Server'),
                  onPressed: running ? _stop : _start,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        running ? Colors.red.shade700 : Colors.green.shade700,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: Text(_uploadDir == null
                      ? 'Enable Uploads (choose folder)'
                      : 'Uploads ➜ ${_shortDir(_uploadDir!)}'),
                  onPressed: running ? null : _chooseUploadDir,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Selected files
            Text('Selected files (${_selected.length}):',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_selected.isEmpty)
              const Text('No files selected.')
            else
              ..._selected.map((f) => Row(
                    children: [
                      Text('• ${p.basename(f.path)}'),
                      IconButton(
                          onPressed: () {
                            _deleteTempFile(f);
                          },
                          icon: Icon(
                            Icons.delete,
                            color: Colors.red,
                          ))
                    ],
                  )),

            const Divider(height: 32),

            // Share URL + QR
            if (_url != null) ...[
              SelectableText('Share URL: $_url',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Center(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      data: _url!,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                  'Tip: Scan the QR code with your phone to open the page.'),
            ],

            if (!running) ...[
              const SizedBox(height: 12),
              const Text(
                'Note: Ensure the phone is on the same Wi‑Fi. '
                'The first time, macOS may ask to allow incoming connections — choose Allow.',
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _shortDir(String path) {
    final parts = path.split(Platform.pathSeparator);
    if (parts.isEmpty) return path;
    // Show the last 2 segments if possible
    if (parts.length >= 2) {
      return '${parts[parts.length - 2]}${Platform.pathSeparator}${parts.last}';
    }
    return parts.last;
  }

  Future<void> _openUrl(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]); // macOS: open default browser
      }
    } catch (_) {
      // ignore
    }
  }
}
