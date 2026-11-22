import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/services.dart';
import 'kit.dart';
import 'theme.dart';

/// Settings → Agents & Workers: how many workers the orchestrator may run, how it schedules them, and how
/// long and how often a worker may try.
class WorkersScreen extends StatefulWidget {
  const WorkersScreen({super.key});

  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<WorkersScreen> {
  void _set(VoidCallback f) {
    setState(f);
    store.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    final p = paletteOf(context);
    return GroupedPage(
      title: 'Agents & Workers',
      children: [
        Group(
          header: 'Limits',
          footer: 'When a job has independent parts, the assistant can hand them to worker agents that run side by side '
              '(the run_parallel tool). Two workers at a time is a safe default. The main assistant counts as one active agent.',
          children: [
            _SliderRow(
              icon: CupertinoIcons.square_stack_3d_up,
              title: 'Maximum concurrent workers',
              value: s.workersMax.toDouble(),
              min: 1,
              max: 8,
              label: '${s.workersMax}',
              onChanged: (v) => _set(() => s.workersMax = v.round()),
            ),
            _SliderRow(
              icon: CupertinoIcons.person_2,
              title: 'Maximum active agents',
              value: s.agentsMax.toDouble(),
              min: 1,
              max: 16,
              label: '${s.agentsMax}',
              onChanged: (v) => _set(() => s.agentsMax = v.round()),
            ),
          ],
        ),
        Group(
          header: 'Scheduling',
          footer: 'Auto sizes the number of workers to the job (small jobs use fewer). Parallel always uses the maximum. '
              'Sequential runs one task at a time. Tasks that depend on others wait for them, and two tasks never change the same file at once.',
          children: [
            _Choice(
              title: 'Execution',
              value: s.workersMode,
              options: const {'auto': 'Auto', 'parallel': 'Parallel', 'sequential': 'Sequential'},
              onChanged: (v) => _set(() => s.workersMode = v),
            ),
            _Choice(
              title: 'Default task priority',
              value: s.workersPriority,
              options: const {'low': 'Low', 'normal': 'Normal', 'high': 'High'},
              onChanged: (v) => _set(() => s.workersPriority = v),
            ),
          ],
        ),
        Group(
          header: 'Full Windows scan',
          footer: 'How many checks run on your PC at the same time during the Full Windows scan (chat menu). 10 is faster; 5 is gentler on a slow PC or connection.',
          children: [
            _Choice(
              title: 'Parallel workers',
              value: s.winScanWorkers <= 5 ? '5' : '10',
              options: const {'5': '5 workers', '10': '10 workers'},
              onChanged: (v) => _set(() => s.winScanWorkers = v == '5' ? 5 : 10),
            ),
          ],
        ),
        Group(
          header: 'Reliability',
          footer: 'A worker that takes longer than the timeout is stopped; a failed task is retried this many times before it is reported as failed.',
          children: [
            _SliderRow(
              icon: CupertinoIcons.timer,
              title: 'Worker timeout',
              value: s.workerTimeoutSec.toDouble().clamp(30, 600),
              min: 30,
              max: 600,
              divisions: 19,
              label: '${s.workerTimeoutSec}s',
              onChanged: (v) => _set(() => s.workerTimeoutSec = v.round()),
            ),
            _SliderRow(
              icon: CupertinoIcons.arrow_2_circlepath,
              title: 'Retry attempts',
              value: s.workerRetries.toDouble(),
              min: 0,
              max: 5,
              label: '${s.workerRetries}',
              onChanged: (v) => _set(() => s.workerRetries = v.round()),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Text('Watch them work in the Thinking panel: the Multi-Agent Monitor shows one card per worker.', style: TextStyle(fontSize: 12.5, color: p.secondary)),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.icon, required this.title, required this.value, required this.min, required this.max, required this.label, required this.onChanged, this.divisions});

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: p.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
          Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: p.accent)),
        ]),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions ?? (max - min).round(), onChanged: onChanged),
      ]),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.title, required this.value, required this.options, required this.onChanged});

  final String title;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [for (final e in options.entries) ButtonSegment<String>(value: e.key, label: Text(e.value))],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ),
      ]),
    );
  }
}
