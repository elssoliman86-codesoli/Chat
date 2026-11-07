import '../agent/agent_models.dart';

/// Metadata for a capability discovered on the device or provided by an app integration.
/// Registry entries describe tools; they do not install or execute them.
class RegisteredTool {
  RegisteredTool({
    required this.id,
    required this.name,
    required this.source,
    this.version = '',
    this.executablePath = '',
    this.description = '',
    this.capabilities = const <String>[],
    this.installCommandHint = '',
    this.status = ToolInstallStatus.discovered,
    this.verifiedAt,
  });

  final String id;
  final String name;
  final String source;
  String version;
  String executablePath;
  String description;
  final List<String> capabilities;
  String installCommandHint;
  ToolInstallStatus status;
  int? verifiedAt;

  bool get isUsable => status == ToolInstallStatus.verified;

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'source': source, 'version': version,
    'executablePath': executablePath, 'description': description,
    'capabilities': capabilities, 'installCommandHint': installCommandHint,
    'status': status.name, 'verifiedAt': verifiedAt,
  };

  factory RegisteredTool.fromJson(Map<String, dynamic> json) => RegisteredTool(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    source: json['source'] as String? ?? '',
    version: json['version'] as String? ?? '',
    executablePath: json['executablePath'] as String? ?? '',
    description: json['description'] as String? ?? '',
    capabilities: (json['capabilities'] as List?)?.whereType<String>().toList() ?? const [],
    installCommandHint: json['installCommandHint'] as String? ?? '',
    status: ToolInstallStatus.values.firstWhere(
      (value) => value.name == json['status'], orElse: () => ToolInstallStatus.discovered),
    verifiedAt: (json['verifiedAt'] as num?)?.toInt(),
  );
}

class ToolRegistry {
  final Map<String, RegisteredTool> _tools = <String, RegisteredTool>{};

  List<RegisteredTool> get all => List<RegisteredTool>.unmodifiable(_tools.values);

  void register(RegisteredTool tool) {
    final key = tool.id.trim().toLowerCase();
    if (key.isEmpty) throw ArgumentError.value(tool.id, 'id', 'Tool id cannot be empty.');
    _tools[key] = tool;
  }

  RegisteredTool? find(String id) => _tools[id.trim().toLowerCase()];

  List<RegisteredTool> findByCapability(String capability, {bool verifiedOnly = true}) {
    final matches = _tools.values.where((tool) =>
      tool.capabilities.any((item) => item.toLowerCase() == capability.toLowerCase()) &&
      (!verifiedOnly || tool.isUsable));
    return List<RegisteredTool>.unmodifiable(matches);
  }

  List<RegisteredTool> get missing => _tools.values
    .where((tool) => tool.status == ToolInstallStatus.missing ||
      tool.status == ToolInstallStatus.proposed || tool.status == ToolInstallStatus.rejected)
    .toList(growable: false);

  Map<String, dynamic> toJson() => {'tools': _tools.values.map((tool) => tool.toJson()).toList()};

  factory ToolRegistry.fromJson(Map<String, dynamic> json) {
    final registry = ToolRegistry();
    for (final item in (json['tools'] as List?)?.whereType<Map>() ?? const []) {
      registry.register(RegisteredTool.fromJson(item.cast<String, dynamic>()));
    }
    return registry;
  }
}
