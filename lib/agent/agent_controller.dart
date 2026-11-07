import '../security/scope_policy.dart';
import '../tools/tool_registry.dart';
import 'agent_models.dart';

typedef BatchApproval = Future<bool> Function(List<ToolRequirement> requirements);

/// Coordinates the state transitions of one agent task. Installation and execution remain
/// separate adapters so this controller cannot silently install or run a device command.
class AgentController {
  AgentController({
    required this.registry,
    required this.requestBatchApproval,
    this.initialTask,
    this.onChanged,
  }) : _task = initialTask;

  final ToolRegistry registry;
  final BatchApproval requestBatchApproval;
  final AgentTask? initialTask;
  final void Function(AgentTask? task)? onChanged;
  AgentTask? _task;

  void _emit() => onChanged?.call(_task);
  ScopePolicy? _policy;

  AgentTask? get currentTask => _task;

  AgentTask createTask({required String conversationId, required String goal, String target = ''}) {
    final cleanGoal = goal.trim();
    if (cleanGoal.isEmpty) throw ArgumentError.value(goal, 'goal', 'Task goal cannot be empty.');
    final task = AgentTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      conversationId: conversationId,
      goal: cleanGoal,
      target: target.trim(),
      status: AgentTaskStatus.planning,
    );
    _task = task;
    _policy = null;
    _emit();
    return task;
  }

  void setPolicy(ScopePolicy policy) {
    _requireTask();
    _policy = policy;
    _task!.policyReference = policy.source;
    _task!.touch();
    _emit();
  }

  void replacePlan(Iterable<AgentStep> steps) {
    final task = _requireTask();
    task.steps
      ..clear()
      ..addAll(steps);
    task.status = AgentTaskStatus.planning;
    task.touch();
    _emit();
  }

  void proposeTools(Iterable<ToolRequirement> requirements) {
    final task = _requireTask();
    for (final requirement in requirements) {
      final index = task.toolRequirements.indexWhere((item) => item.id == requirement.id);
      if (index < 0) {
        requirement.status = ToolInstallStatus.proposed;
        task.toolRequirements.add(requirement);
      } else {
        task.toolRequirements[index].status = ToolInstallStatus.proposed;
      }
    }
    task.touch();
    _emit();
  }

  /// One approval covers only this proposed batch. It does not authorize installation itself.
  Future<bool> approveToolBatch() async {
    final task = _requireTask();
    final batch = task.toolRequirements
      .where((item) => item.status == ToolInstallStatus.proposed)
      .toList(growable: false);
    if (batch.isEmpty) return false;
    task.status = AgentTaskStatus.awaitingApproval;
    task.touch();
    _emit();
    final approved = await requestBatchApproval(List<ToolRequirement>.unmodifiable(batch));
    for (final item in batch) {
      item.status = approved ? ToolInstallStatus.approved : ToolInstallStatus.rejected;
    }
    task.status = approved ? AgentTaskStatus.paused : AgentTaskStatus.planning;
    task.touch();
    _emit();
    return approved;
  }

  ScopeEvaluation authorizeOperation({
    required String target,
    required AgentOperationRisk risk,
  }) {
    if (risk == AgentOperationRisk.destructive) {
      return const ScopeEvaluation(ScopeDecision.deny, 'Destructive testing is not permitted by this agent.');
    }
    if (risk == AgentOperationRisk.readOnly) {
      return const ScopeEvaluation(ScopeDecision.allow, 'This operation does not contact a target.');
    }
    final policy = _policy;
    if (policy == null) {
      return const ScopeEvaluation(ScopeDecision.needsReview, 'Load and review the program policy before target interaction.');
    }
    return policy.evaluate(target, activeOperation: risk == AgentOperationRisk.active);
  }

  void startStep(String stepId, {required String target, required AgentOperationRisk risk}) {
    final task = _requireTask();
    final decision = authorizeOperation(target: target, risk: risk);
    if (decision.decision != ScopeDecision.allow) {
      throw StateError(decision.reason);
    }
    final step = _findStep(task, stepId);
    if (step == null) throw ArgumentError.value(stepId, 'stepId', 'Unknown agent step.');
    step.status = AgentStepStatus.running;
    task.status = AgentTaskStatus.running;
    task.touch();
    _emit();
  }

  void finishStep(String stepId, {String output = '', bool failed = false}) {
    final task = _requireTask();
    final step = _findStep(task, stepId);
    if (step == null) throw ArgumentError.value(stepId, 'stepId', 'Unknown agent step.');
    step
      ..status = failed ? AgentStepStatus.failed : AgentStepStatus.completed
      ..output = output;
    task.status = failed ? AgentTaskStatus.failed : AgentTaskStatus.paused;
    task.touch();
    _emit();
  }

  void completeTask() {
    final task = _requireTask();
    task.status = AgentTaskStatus.completed;
    task.touch();
    _emit();
  }

  AgentStep? _findStep(AgentTask task, String id) {
    for (final step in task.steps) {
      if (step.id == id) return step;
    }
    return null;
  }

  AgentTask _requireTask() {
    final task = _task;
    if (task == null) throw StateError('Create an agent task first.');
    return task;
  }
}
