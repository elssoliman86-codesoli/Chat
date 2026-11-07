import '../core/models.dart';

enum AgentTaskStatus { queued, planning, awaitingApproval, running, paused, completed, failed, cancelled }
enum AgentStepStatus { pending, running, awaitingApproval, completed, skipped, failed }
enum ToolInstallStatus { discovered, missing, proposed, approved, installing, installed, verified, failed, rejected }
enum AgentOperationRisk { readOnly, passive, active, destructive }

class AgentStep {
  AgentStep({
    required this.id,
    required this.title,
    this.description = '',
    this.status = AgentStepStatus.pending,
    this.toolIds = const <String>[],
    this.output = '',
  });

  final String id;
  final String title;
  final String description;
  AgentStepStatus status;
  final List<String> toolIds;
  String output;

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'description': description,
    'status': status.name, 'toolIds': toolIds, 'output': output,
  };

  factory AgentStep.fromJson(Map<String, dynamic> json) => AgentStep(
    id: json['id'] as String? ?? newId(),
    title: json['title'] as String? ?? '',
    description: json['description'] as String? ?? '',
    status: AgentStepStatus.values.firstWhere(
      (value) => value.name == json['status'], orElse: () => AgentStepStatus.pending),
    toolIds: (json['toolIds'] as List?)?.whereType<String>().toList() ?? const [],
    output: json['output'] as String? ?? '',
  );
}

class ToolRequirement {
  ToolRequirement({
    required this.id,
    required this.name,
    this.reason = '',
    this.installHint = '',
    this.status = ToolInstallStatus.discovered,
    this.capabilities = const <String>[],
  });

  final String id;
  final String name;
  final String reason;
  final String installHint;
  ToolInstallStatus status;
  final List<String> capabilities;

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'reason': reason, 'installHint': installHint,
    'status': status.name, 'capabilities': capabilities,
  };

  factory ToolRequirement.fromJson(Map<String, dynamic> json) => ToolRequirement(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    installHint: json['installHint'] as String? ?? '',
    status: ToolInstallStatus.values.firstWhere(
      (value) => value.name == json['status'], orElse: () => ToolInstallStatus.discovered),
    capabilities: (json['capabilities'] as List?)?.whereType<String>().toList() ?? const [],
  );
}

class AgentTask {
  AgentTask({
    required this.id,
    required this.conversationId,
    required this.goal,
    this.status = AgentTaskStatus.queued,
    List<AgentStep>? steps,
    List<ToolRequirement>? toolRequirements,
    this.target = '',
    this.policyReference = '',
    int? createdAt,
    int? updatedAt,
  }) : steps = steps ?? <AgentStep>[],
       toolRequirements = toolRequirements ?? <ToolRequirement>[],
       createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
       updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String conversationId;
  final String goal;
  AgentTaskStatus status;
  final List<AgentStep> steps;
  final List<ToolRequirement> toolRequirements;
  String target;
  String policyReference;
  final int createdAt;
  int updatedAt;

  void touch() => updatedAt = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'id': id, 'conversationId': conversationId, 'goal': goal,
    'status': status.name, 'steps': steps.map((step) => step.toJson()).toList(),
    'toolRequirements': toolRequirements.map((tool) => tool.toJson()).toList(),
    'target': target, 'policyReference': policyReference,
    'createdAt': createdAt, 'updatedAt': updatedAt,
  };

  factory AgentTask.fromJson(Map<String, dynamic> json) => AgentTask(
    id: json['id'] as String? ?? newId(),
    conversationId: json['conversationId'] as String? ?? '',
    goal: json['goal'] as String? ?? '',
    status: AgentTaskStatus.values.firstWhere(
      (value) => value.name == json['status'], orElse: () => AgentTaskStatus.queued),
    steps: (json['steps'] as List?)?.whereType<Map>()
      .map((item) => AgentStep.fromJson(item.cast<String, dynamic>())).toList(),
    toolRequirements: (json['toolRequirements'] as List?)?.whereType<Map>()
      .map((item) => ToolRequirement.fromJson(item.cast<String, dynamic>())).toList(),
    target: json['target'] as String? ?? '',
    policyReference: json['policyReference'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt(),
    updatedAt: (json['updatedAt'] as num?)?.toInt(),
  );
}
