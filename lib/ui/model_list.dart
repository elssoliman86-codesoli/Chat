import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/model_checker.dart';
import '../data/services.dart';
import 'theme.dart';

String shortModelName(String model) {
  final i = model.lastIndexOf('/');
  return i < 0 ? model : model.substring(i + 1);
}

String modelVendor(String model) {
  final i = model.indexOf('/');
  return i < 0 ? '' : model.substring(0, i);
}

String favoriteKey(ProviderConfig p, String model) => '${p.id}|$model';

bool isFavorite(ProviderConfig p, String model) => store.settings.favorites.contains(favoriteKey(p, model));

void toggleFavorite(ProviderConfig p, String model) {
  final k = favoriteKey(p, model);
  if (!store.settings.favorites.remove(k)) store.settings.favorites.add(k);
  store.saveSettings();
}

/// All models of a provider: the default first, then the rest.
List<String> modelsOf(ProviderConfig p) {
  final set = <String>{if (p.model.isNotEmpty) p.model, ...p.models};
  return set.toList();
}

abstract class _Row {}

class _Header extends _Row {
  _Header(this.title, {this.count});
  final String title;
  final int? count;
}

class _Sub extends _Row {
  _Sub(this.title);
  final String title;
}

class _Model extends _Row {
  _Model(this.provider, this.model);
  final ProviderConfig provider;
  final String model;
}

/// A searchable, grouped list of models: favorites, then each provider, then each vendor.
class ModelList extends StatefulWidget {
  const ModelList({
    super.key,
    required this.providers,
    required this.onPick,
    this.selectedProviderId = '',
    this.selectedModel = '',
    this.controller,
  });

  final List<ProviderConfig> providers;
  final void Function(ProviderConfig provider, String model) onPick;
  final String selectedProviderId;
  final String selectedModel;
  final ScrollController? controller;

  @override
  State<ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<ModelList> {
  String _query = '';
  String _only = '';
  bool _workingOnly = false;

  bool _ok(int? status) => status != null && status >= 200 && status < 300;

  List<(ProviderConfig, String)> _visibleJobs() {
    final seen = <String>{};
    final jobs = <(ProviderConfig, String)>[];
    for (final r in _rows()) {
      if (r is _Model && seen.add(favoriteKey(r.provider, r.model))) jobs.add((r.provider, r.model));
    }
    return jobs;
  }

  List<_Row> _rows() {
    final q = _query.trim().toLowerCase();
    final rows = <_Row>[];
    bool match(String m, ProviderConfig p) {
      if (_workingOnly && !_ok(p.health[m])) return false;
      return q.isEmpty || m.toLowerCase().contains(q);
    }

    if (q.isEmpty && _only.isEmpty) {
      final fav = <_Model>[];
      for (final p in widget.providers) {
        for (final m in modelsOf(p)) {
          if (isFavorite(p, m)) fav.add(_Model(p, m));
        }
      }
      if (fav.isNotEmpty) {
        rows.add(_Header('Favorites'));
        rows.addAll(fav);
      }
    }
    for (final p in widget.providers) {
      if (_only.isNotEmpty && p.id != _only) continue;
      final all = modelsOf(p).where((m) => match(m, p)).toList()
        ..sort((a, b) => (_ok(p.health[b]) ? 1 : 0).compareTo(_ok(p.health[a]) ? 1 : 0));
      if (all.isEmpty) continue;
      rows.add(_Header(p.name, count: all.length));
      final vendors = all.map(modelVendor).toSet();
      final group = vendors.length > 1 && all.length > 12;
      if (!group) {
        for (final m in all) {
          rows.add(_Model(p, m));
        }
      } else {
        final sorted = vendors.toList()..sort();
        for (final v in sorted) {
          rows.add(_Sub(v.isEmpty ? 'Other' : v));
          final list = all.where((m) => modelVendor(m) == v).toList()
            ..sort((a, b) {
              final c = (_ok(p.health[b]) ? 1 : 0).compareTo(_ok(p.health[a]) ? 1 : 0);
              return c != 0 ? c : a.compareTo(b);
            });
          for (final m in list) {
            rows.add(_Model(p, m));
          }
        }
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: checker, builder: (context, _) => _content(context));
  }

  Widget _content(BuildContext context) {
    final pal = paletteOf(context);
    final rows = _rows();
    final jobs = _visibleJobs();
    final okCount = jobs.where((j) => _ok(j.$1.health[j.$2])).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: 'Search models',
            isDense: true,
            filled: true,
            fillColor: pal.bubble,
            prefixIcon: const Icon(CupertinoIcons.search, size: 18),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      if (widget.providers.length > 1)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _chip('All', _only.isEmpty, () => setState(() => _only = '')),
              for (final p in widget.providers) _chip(p.name, _only == p.id, () => setState(() => _only = p.id)),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
        child: Row(children: [
          if (checker.running) ...[
            Expanded(
              child: Text('Testing ${checker.done}/${checker.total}…', style: TextStyle(fontSize: 13, color: pal.secondary)),
            ),
            TextButton(onPressed: checker.cancel, child: const Text('Stop')),
          ] else ...[
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: jobs.isEmpty ? null : () => checker.run(jobs.take(150).toList()),
              icon: const Icon(CupertinoIcons.checkmark_shield, size: 17),
              label: Text('Test ${jobs.length > 150 ? 150 : jobs.length} models'),
            ),
            const Spacer(),
            Text('Working only', style: TextStyle(fontSize: 13, color: pal.secondary)),
            Transform.scale(
              scale: 0.8,
              child: Switch(value: _workingOnly, onChanged: (v) => setState(() => _workingOnly = v)),
            ),
          ],
        ]),
      ),
      if (checker.running) LinearProgressIndicator(value: checker.total == 0 ? null : checker.done / checker.total, minHeight: 2),
      if (!checker.running && okCount > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('$okCount answered with 200 (of ${jobs.length} shown)', style: TextStyle(fontSize: 12, color: pal.secondary)),
          ),
        ),
      Expanded(
        child: rows.isEmpty
            ? Center(child: Text('No models found', style: TextStyle(color: pal.secondary)))
            : ListView.builder(
                controller: widget.controller,
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final r = rows[i];
                  if (r is _Header) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                      child: Text(
                        '${r.title.toUpperCase()}${r.count == null ? '' : '  ·  ${r.count}'}',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: pal.secondary),
                      ),
                    );
                  }
                  if (r is _Sub) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
                      child: Text(r.title, style: TextStyle(fontSize: 13, color: pal.secondary)),
                    );
                  }
                  final m = r as _Model;
                  final selected = m.provider.id == widget.selectedProviderId && m.model == widget.selectedModel;
                  final fav = isFavorite(m.provider, m.model);
                  final vendor = modelVendor(m.model);
                  return InkWell(
                    onTap: () => widget.onPick(m.provider, m.model),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(shortModelName(m.model), style: const TextStyle(fontSize: 16)),
                            if (vendor.isNotEmpty || m.provider.noVision.contains(m.model))
                              Text(
                                [if (vendor.isNotEmpty) vendor, if (m.provider.noVision.contains(m.model)) 'text only'].join(' · '),
                                style: TextStyle(fontSize: 12, color: pal.secondary),
                              ),
                          ]),
                        ),
                        _badge(m.provider.health[m.model], pal),
                        if (selected) Icon(CupertinoIcons.checkmark_alt, color: pal.accent, size: 22),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(fav ? CupertinoIcons.star_fill : CupertinoIcons.star,
                              size: 19, color: fav ? iosOrange : pal.secondary),
                          onPressed: () => setState(() => toggleFavorite(m.provider, m.model)),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _badge(int? status, Palette pal) {
    if (status == null) return const SizedBox.shrink();
    final ok = _ok(status);
    final color = ok ? iosGreen : (status == 0 ? pal.secondary : iosRed);
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
      child: Text(status == 0 ? 'no reply' : '$status',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    final pal = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? pal.accent : pal.bubble, borderRadius: BorderRadius.circular(18)),
          child: Text(label, style: TextStyle(fontSize: 14, color: on ? Colors.white : null, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

/// Full-page version, used from the provider editor to choose its default model.
class ModelListPage extends StatelessWidget {
  const ModelListPage({super.key, required this.provider, required this.selected});

  final ProviderConfig provider;
  final String selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(provider.name)),
      body: SafeArea(
        child: ModelList(
          providers: [provider],
          selectedProviderId: provider.id,
          selectedModel: selected,
          onPick: (p, m) => Navigator.pop(context, m),
        ),
      ),
    );
  }
}
