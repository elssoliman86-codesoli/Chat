import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/services.dart';
import '../files/code_export.dart';
import '../projects/project_store.dart';
import '../projects/projects.dart';
import 'theme.dart';

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

String _kb(int bytes) => bytes < 1024 ? '$bytes B' : (bytes < 1048576 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB');

/// Packs the project and lets the person save the ZIP.
Future<void> saveProjectZip(BuildContext context, String projectId) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    messenger.showSnackBar(const SnackBar(content: Text('Packing the project…'), duration: Duration(seconds: 2)));
    final path = await projects.exportZip(projectId);
    final name = path.split('/').last;
    final bytes = await File(path).readAsBytes();
    final saved = await FilePicker.platform.saveFile(dialogTitle: 'Save $name', fileName: name, bytes: bytes);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(saved == null ? 'Not saved' : 'Saved $name')));
  } catch (e) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not make the ZIP')));
  }
}

void openProjectPreview(BuildContext context, String projectId, [String page = '']) {
  Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => ProjectPreviewScreen(projectId: projectId, page: page)));
}

/// The strip above the message box while a chat has a project: preview, files and ZIP in one tap.
class ProjectBar extends StatefulWidget {
  const ProjectBar({super.key, required this.projectId});

  final String projectId;

  @override
  State<ProjectBar> createState() => _ProjectBarState();
}

class _ProjectBarState extends State<ProjectBar> {
  int _count = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    projects.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    projects.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      await projects.load();
      final n = (await projects.list(widget.projectId)).length;
      if (mounted && n != _count) setState(() => _count = n);
    } catch (_) {}
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final p = projects.byId(widget.projectId);
    if (p == null) return const SizedBox.shrink();
    final pal = paletteOf(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(CupertinoIcons.folder_fill, size: 17, color: pal.accent),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => ProjectDetailScreen(projectId: p.id))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('${p.name} · $_count files', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => openProjectPreview(context, p.id),
          icon: const Icon(CupertinoIcons.play_rectangle, size: 16),
          label: const Text('Preview'),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Save as ZIP',
          icon: Icon(CupertinoIcons.arrow_down_to_line, size: 18, color: pal.secondary),
          onPressed: () => saveProjectZip(context, p.id),
        ),
      ]),
    );
  }
}

/// Runs the whole project on the local server in its own browser view.
class ProjectPreviewScreen extends StatefulWidget {
  const ProjectPreviewScreen({super.key, required this.projectId, this.page = ''});

  final String projectId;
  final String page;

  @override
  State<ProjectPreviewScreen> createState() => _ProjectPreviewScreenState();
}

class _ProjectPreviewScreenState extends State<ProjectPreviewScreen> {
  WebViewController? _web;
  List<String> _pages = <String>[];
  String _current = '';
  String _error = '';
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await projects.load();
      final files = await projects.list(widget.projectId);
      _pages = files.where((f) => f.path.toLowerCase().endsWith('.html')).map((f) => f.path).toList();
      var page = widget.page;
      if (page.isEmpty) page = _pages.contains('index.html') ? 'index.html' : (_pages.isEmpty ? '' : _pages.first);
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        }));
      if (page.isNotEmpty) {
        final url = await projectServer.urlFor(widget.projectId, page);
        await c.loadRequest(Uri.parse(url));
      } else {
        // Source-only projects can still be previewed without manufacturing an index.html.
        final candidates = files.where((f) {
          final ext = f.path.split('.').last.toLowerCase();
          return const {'py','python','md','markdown','json','csv','css','js','javascript','jsx','tsx','react','svg'}.contains(ext);
        }).toList();
        if (candidates.isEmpty) {
          setState(() => _error = 'No runnable HTML page or supported source file was found. Add index.html for a full web-app preview.');
          return;
        }
        final chosen = candidates.first;
        final source = await projects.readText(widget.projectId, chosen.path);
        if (source == null) throw Exception('Could not read ${chosen.path}');
        final ext = chosen.path.split('.').last.toLowerCase();
        await c.loadHtmlString(previewDocument(ext, source));
        page = chosen.path;
      }
      if (!mounted) return;
      setState(() {
        _web = c;
        _current = page;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the local server: $e');
    }
  }

  Future<void> _open(String page) async {
    final c = _web;
    if (c == null) return;
    final url = await projectServer.urlFor(widget.projectId, page);
    await c.loadRequest(Uri.parse(url));
    setState(() => _current = page);
  }

  @override
  Widget build(BuildContext context) {
    final p = projects.byId(widget.projectId);
    return Scaffold(
      appBar: AppBar(
        title: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(p?.name ?? 'Preview', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600)),
          Text('local server · $_current', style: TextStyle(fontSize: 11.5, color: paletteOf(context).secondary)),
        ]),
        actions: [
          if (_pages.length > 1)
            PopupMenuButton<String>(
              icon: const Icon(CupertinoIcons.doc_on_doc),
              tooltip: 'Pages',
              onSelected: _open,
              itemBuilder: (_) => [for (final pg in _pages) PopupMenuItem(value: pg, child: Text(pg))],
            ),
          IconButton(icon: const Icon(CupertinoIcons.arrow_clockwise), onPressed: () => _web?.reload()),
        ],
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress / 100, minHeight: 2))
            : null,
      ),
      body: _error.isNotEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error, textAlign: TextAlign.center)))
          : (_web == null ? const Center(child: CupertinoActivityIndicator()) : WebViewWidget(controller: _web!)),
    );
  }
}

/// All projects on the phone, with import from a ZIP or a GitHub repository.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  @override
  void initState() {
    super.initState();
    projects.load();
  }

  Future<void> _work(String label, Future<(Project, String)> Function() job) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [const CupertinoActivityIndicator(), const SizedBox(width: 16), Expanded(child: Text(label))]),
      ),
    );
    String message;
    try {
      final (p, summary) = await job();
      message = '${p.name}: $summary';
    } catch (e) {
      message = e.toString().replaceFirst('Exception: ', '');
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _toast(context, message);
  }

  Future<void> _importZip() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: <String>['zip']);
    final f = r?.files.single;
    if (f == null || f.path == null) return;
    await _work('Unpacking ${f.name}…', () => projects.importZip(f.path!, f.name));
  }

  Future<void> _importGithub() async {
    final c = TextEditingController();
    final repo = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Download a GitHub repo'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'owner/name or github.com link'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Download')),
        ],
      ),
    );
    c.dispose();
    if (repo == null || repo.isEmpty) return;
    await _work('Downloading $repo…', () => projects.importGithub(repo, '', store.settings.githubToken));
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Projects')),
      body: ListenableBuilder(
        listenable: projects,
        builder: (context, _) {
          final list = projects.projects;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(onPressed: _importZip, icon: const Icon(CupertinoIcons.archivebox, size: 18), label: const Text('Open a ZIP')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(onPressed: _importGithub, icon: const Icon(CupertinoIcons.cloud_download, size: 18), label: const Text('GitHub repo')),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              'Ask in a chat to build a project and the files appear here. You can also open a ZIP or a repo, then ask the assistant to analyze or change it.',
              style: TextStyle(color: pal.secondary, fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('No projects yet', style: TextStyle(color: pal.secondary))),
              ),
            for (final p in list)
              Dismissible(
                key: ValueKey(p.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: iosRed,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(CupertinoIcons.delete, color: Colors.white),
                ),
                confirmDismiss: (_) async =>
                    await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: Text('Delete "${p.name}"?'),
                        content: const Text('All its files are removed from the phone.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                        ],
                      ),
                    ) ??
                    false,
                onDismissed: (_) => projects.delete(p.id),
                child: ListTile(
                  leading: Icon(CupertinoIcons.folder_fill, color: pal.accent),
                  title: Text(p.name),
                  subtitle: Text(p.repo.isEmpty ? 'On this phone' : 'GitHub ${p.repo}'),
                  trailing: const Icon(CupertinoIcons.chevron_forward, size: 16),
                  onTap: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => ProjectDetailScreen(projectId: p.id))),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Browse the files of one project like a file manager.
class ProjectDetailScreen extends StatefulWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  List<ProjectFile> _files = <ProjectFile>[];
  String _dir = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await projects.list(widget.projectId);
    if (mounted) {
      setState(() {
        _files = f;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final p = projects.byId(widget.projectId);
    final prefix = _dir.isEmpty ? '' : '$_dir/';
    final dirs = <String, int>{};
    final here = <ProjectFile>[];
    for (final f in _files) {
      if (!f.path.startsWith(prefix)) continue;
      final rest = f.path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        here.add(f);
      } else {
        final d = rest.substring(0, slash);
        dirs[d] = (dirs[d] ?? 0) + 1;
      }
    }
    final dirNames = dirs.keys.toList()..sort();
    return PopScope(
      canPop: _dir.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _dir = _dir.contains('/') ? _dir.substring(0, _dir.lastIndexOf('/')) : '');
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(p?.name ?? 'Project', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600)),
            Text('${_files.length} files${_dir.isEmpty ? '' : ' · /$_dir'}', style: TextStyle(fontSize: 11.5, color: pal.secondary)),
          ]),
          actions: [
            IconButton(tooltip: 'Run', icon: const Icon(CupertinoIcons.play_rectangle), onPressed: () => openProjectPreview(context, widget.projectId)),
            IconButton(tooltip: 'Save as ZIP', icon: const Icon(CupertinoIcons.arrow_down_to_line), onPressed: () => saveProjectZip(context, widget.projectId)),
          ],
        ),
        body: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(children: [
                  if (_dir.isNotEmpty)
                    ListTile(
                      leading: const Icon(CupertinoIcons.arrow_up_left),
                      title: const Text('..'),
                      onTap: () => setState(() => _dir = _dir.contains('/') ? _dir.substring(0, _dir.lastIndexOf('/')) : ''),
                    ),
                  for (final d in dirNames)
                    ListTile(
                      dense: true,
                      leading: Icon(CupertinoIcons.folder_fill, color: pal.accent),
                      title: Text(d),
                      subtitle: Text('${dirs[d]} files'),
                      onTap: () => setState(() => _dir = '$prefix$d'),
                    ),
                  for (final f in here)
                    ListTile(
                      dense: true,
                      leading: Icon(CupertinoIcons.doc_text, color: pal.secondary),
                      title: Text(f.path.substring(prefix.length)),
                      subtitle: Text(_kb(f.size)),
                      onTap: () => Navigator.push(
                        context,
                        CupertinoPageRoute<void>(builder: (_) => ProjectFileScreen(projectId: widget.projectId, path: f.path)),
                      ).then((_) => _load()),
                    ),
                  if (_files.isEmpty)
                    Padding(padding: const EdgeInsets.all(40), child: Center(child: Text('Empty', style: TextStyle(color: pal.secondary)))),
                ]),
              ),
      ),
    );
  }
}

const Set<String> _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

/// View and edit one file by hand.
class ProjectFileScreen extends StatefulWidget {
  const ProjectFileScreen({super.key, required this.projectId, required this.path});

  final String projectId;
  final String path;

  @override
  State<ProjectFileScreen> createState() => _ProjectFileScreenState();
}

class _ProjectFileScreenState extends State<ProjectFileScreen> {
  final TextEditingController _text = TextEditingController();
  bool _loading = true;
  bool _image = false;
  bool _binary = false;
  String? _imagePath;
  String _original = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dot = widget.path.lastIndexOf('.');
    final ext = dot < 0 ? '' : widget.path.substring(dot + 1).toLowerCase();
    if (_imageExt.contains(ext)) {
      _imagePath = '${await projects.dirOf(widget.projectId)}/${widget.path}';
      _image = true;
    } else {
      final t = await projects.readText(widget.projectId, widget.path) ?? '';
      if (t.startsWith('[binary file')) {
        _binary = true;
      } else {
        _original = t;
        _text.text = t;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    await projects.write(widget.projectId, <(String, String)>[(widget.path, _text.text)]);
    _original = _text.text;
    if (mounted) {
      setState(() {});
      _toast(context, 'Saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dirty = !_image && !_binary && _text.text != _original;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path.split('/').last, style: const TextStyle(fontSize: 16.5)),
        actions: [
          if (!_image && !_binary)
            IconButton(
              icon: const Icon(CupertinoIcons.doc_on_doc),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _text.text));
                _toast(context, 'Copied');
              },
            ),
          if (dirty) TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _image
              ? InteractiveViewer(child: Center(child: Image.file(File(_imagePath!))))
              : _binary
                  ? const Center(child: Text('Binary file'))
                  : SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: MediaQuery.of(context).size.width * 2.2,
                          child: TextField(
                            controller: _text,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            onChanged: (_) => setState(() {}),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
                            decoration: const InputDecoration(border: InputBorder.none, filled: false, contentPadding: EdgeInsets.all(12)),
                          ),
                        ),
                      ),
                    ),
    );
  }
}
