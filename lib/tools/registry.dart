import '../core/models.dart';
import '../data/app_store.dart';
import 'tools.dart';
import '../llm/llm.dart';

/// Central registry that builds the complete list of tools available to the model
/// for a given conversation, respecting settings gates, active skills, and plugin tools.
class ToolRegistry {
  ToolRegistry._();

  /// Builds the list of [ToolSpec] to send to the LLM for [c].
  static List<ToolSpec> specsFor(Conversation c, AppStore store, ProviderConfig provider) {
    if (!provider.supportsTools) return const <ToolSpec>[];

    final st = store.settings;
    final availableIds = <String>{};

    // 1. Built-in tools - filter by settings gates
    for (final t in builtinTools) {
      final on = switch (t.group) {
        'web' => st.webTools,
        'browser' => st.pluginBrowser,
        'github' => st.pluginGithub,
        'github_write' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
        'project_push' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
        'termux' => st.termuxTools,
        'advisor' => st.assistantProviderId.isNotEmpty && st.assistantModel.isNotEmpty,
        'python' => true, // Python is always available (sandboxed)
        _ => true, // core tools always available
      };
      if (on) availableIds.add(t.id);
    }

    // 2. Memory tools - only if memory is enabled and not temporary
    if (!(st.memoryEnabled && !c.temporary)) {
      availableIds.remove('remember');
      availableIds.remove('forget');
    }

    // 2b. Self-improvement tools - only if that setting is on and not temporary
    if (!(st.selfImprove && !c.temporary)) {
      availableIds.remove('learn');
      availableIds.remove('forget_lesson');
    }

    // 3. Skill tools - add tools required by active skills (but only if their group is enabled)
    final activeSkills = store.skills.where((k) => k.enabled && (k.alwaysOn || c.activeSkillIds.contains(k.id)));
    for (final k in activeSkills) {
      for (final toolId in k.tools) {
        final def = toolById(toolId);
        if (def != null) {
          final on = switch (def.group) {
            'web' => st.webTools,
            'browser' => st.pluginBrowser,
            'github' => st.pluginGithub,
            'github_write' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
            'project_push' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
            'termux' => st.termuxTools,
            'advisor' => st.assistantProviderId.isNotEmpty && st.assistantModel.isNotEmpty,
            'python' => true,
            _ => true,
          };
          if (on) availableIds.add(toolId);
        }
      }
    }

    // 4. Build ToolSpecs from available IDs
    final specs = <ToolSpec>[];
    for (final id in availableIds) {
      final def = toolById(id);
      if (def != null) specs.add(def.spec);
    }

    // 5. Plugin tools from enabled plugins
    for (final p in store.plugins.where((p) => p.enabled)) {
      for (final t in p.tools) {
        specs.add(ToolSpec(
          name: p.specName(t),
          description: '${p.name}: ${t.description}',
          parameters: t.parameters,
        ));
      }
    }

    // 6. Always include use_skill if there are auto-use skills available
    final hasAuto = store.skills.any((k) => k.enabled && k.autoUse && !k.alwaysOn);
    if (hasAuto) specs.add(useSkillSpec);

    return specs;
  }

  /// Gets the human-readable list of tool groups that are enabled for the UI.
  static List<String> enabledGroups(AppSettings st) {
    final groups = <String>[];
    if (st.webTools) groups.add('web');
    if (st.pluginBrowser) groups.add('browser');
    if (st.pluginGithub) groups.add('github');
    if (st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty) groups.add('github_write');
    if (st.termuxTools) groups.add('termux');
    groups.add('core');
    groups.add('project');
    groups.add('python');
    return groups;
  }

  /// Checks if a tool is available for the current conversation.
  static bool isToolAvailable(String toolId, Conversation c, AppStore store, ProviderConfig provider) {
    if (!provider.supportsTools) return false;

    // Check if it's a builtin tool
    final def = toolById(toolId);
    if (def != null) {
      final st = store.settings;
      final on = switch (def.group) {
        'web' => st.webTools,
        'browser' => st.pluginBrowser,
        'github' => st.pluginGithub,
        'github_write' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
        'project_push' => st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty,
        'termux' => st.termuxTools,
        'advisor' => st.assistantProviderId.isNotEmpty && st.assistantModel.isNotEmpty,
        'python' => true,
        _ => true,
      };
      if (!on) return false;
      if ((toolId == 'remember' || toolId == 'forget') && !(st.memoryEnabled && !c.temporary)) return false;
      if ((toolId == 'learn' || toolId == 'forget_lesson') && !(st.selfImprove && !c.temporary)) return false;
      return true;
    }

    // Check if it's a plugin tool
    for (final p in store.plugins.where((p) => p.enabled)) {
      for (final t in p.tools) {
        if (p.specName(t) == toolId) return true;
      }
    }

    // Check if it's use_skill
    if (toolId == 'use_skill') {
      return store.skills.any((k) => k.enabled && k.autoUse && !k.alwaysOn);
    }

    return false;
  }
}
