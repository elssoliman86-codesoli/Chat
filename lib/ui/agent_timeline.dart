import 'package:flutter/material.dart';

import '../agent/agent_models.dart';
import '../tools/tool_registry.dart';

class AgentTimelinePanel extends StatelessWidget {
  const AgentTimelinePanel({super.key, required this.task, required this.registry});

  final AgentTask task;
  final ToolRegistry registry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = task.steps.where((step) => step.status == AgentStepStatus.completed).length;
    final total = task.steps.length;
    final progress = total == 0 ? 0.0 : completed / total;
    final requirements = task.toolRequirements;
    final verified = registry.all.where((tool) => tool.isUsable).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        initiallyExpanded: task.status == AgentTaskStatus.awaitingApproval,
        title: Row(children: [
          const Icon(Icons.account_tree_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('Agent · ${task.goal}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
          Text(task.status.name, style: theme.textTheme.labelSmall),
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: total == 0 ? null : progress, minHeight: 3),
            const SizedBox(height: 5),
            Text('${completed}/${total} steps · $verified verified tools',
              style: theme.textTheme.labelSmall),
          ]),
        ),
        children: [
          if (task.target.isNotEmpty)
            Align(alignment: Alignment.centerLeft, child: Text('Target: ${task.target}', style: theme.textTheme.bodySmall)),
          for (var i = 0; i < task.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_stepIcon(task.steps[i].status), size: 16),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${i + 1}. ${task.steps[i].title}', style: theme.textTheme.bodySmall),
                  if (task.steps[i].description.isNotEmpty)
                    Text(task.steps[i].description, style: theme.textTheme.labelSmall),
                  if (task.steps[i].output.isNotEmpty)
                    Text(task.steps[i].output, maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ])),
                Text(task.steps[i].status.name, style: theme.textTheme.labelSmall),
              ]),
            ),
          if (requirements.isNotEmpty) ...[
            const Divider(height: 18),
            Align(alignment: Alignment.centerLeft,
              child: Text('Tool installation batch', style: theme.textTheme.labelMedium)),
            for (final item in requirements)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(children: [
                  const Icon(Icons.terminal, size: 15),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item.name, style: theme.textTheme.bodySmall)),
                  Text(item.status.name, style: theme.textTheme.labelSmall),
                ]),
              ),
          ],
        ],
      ),
    );
  }

  IconData _stepIcon(AgentStepStatus status) => switch (status) {
    AgentStepStatus.completed => Icons.check_circle_outline,
    AgentStepStatus.running => Icons.play_circle_outline,
    AgentStepStatus.awaitingApproval => Icons.pending_outlined,
    AgentStepStatus.failed => Icons.error_outline,
    AgentStepStatus.skipped => Icons.skip_next_outlined,
    AgentStepStatus.pending => Icons.circle_outlined,
  };
}
