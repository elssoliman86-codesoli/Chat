import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/agent/agent_controller.dart';
import 'package:omni_chat/agent/agent_models.dart';
import 'package:omni_chat/security/scope_policy.dart';
import 'package:omni_chat/tools/tool_registry.dart';

void main() {
  group('ScopePolicy', () {
    test('explicit wildcard scope matches subdomains but not the apex domain', () {
      final policy = ScopePolicy(
        source: 'program policy',
        inScope: {'*.example.com'},
        reviewed: true,
        userConfirmed: true,
      );
      expect(policy.evaluate('https://api.example.com/v1', activeOperation: true).allowed, isTrue);
      expect(policy.evaluate('example.com', activeOperation: true).decision, ScopeDecision.deny);
    });

    test('out-of-scope entries override broader in-scope entries', () {
      final policy = ScopePolicy(
        source: 'program policy',
        inScope: {'*.example.com'},
        outOfScope: {'admin.example.com'},
        reviewed: true,
        userConfirmed: true,
      );
      expect(policy.evaluate('admin.example.com', activeOperation: true).decision, ScopeDecision.deny);
      expect(policy.evaluate('shop.example.com', activeOperation: true).allowed, isTrue);
    });

    test('active testing needs review and explicit user confirmation', () {
      final policy = ScopePolicy(source: 'policy', inScope: {'app.example.com'});
      expect(policy.evaluate('app.example.com', activeOperation: true).decision, ScopeDecision.needsReview);
      policy
        ..reviewed = true
        ..userConfirmed = true;
      expect(policy.evaluate('app.example.com', activeOperation: true).allowed, isTrue);
    });

    test('parser only extracts explicit host entries and preserves exclusions', () {
      final policy = ScopePolicy.parse('''
In Scope
- app.example.com
- *.api.example.com

Out of Scope
- admin.example.com
''', source: 'HackerOne');
      expect(policy.inScope, containsAll({'app.example.com', '*.api.example.com'}));
      expect(policy.outOfScope, contains('admin.example.com'));
      expect(policy.evaluate('admin.example.com', activeOperation: false).decision, ScopeDecision.deny);
    });

    test('policy JSON round trip preserves confirmation state', () {
      final policy = ScopePolicy(
        source: 'url',
        inScope: {'app.example.com'},
        outOfScope: {'admin.example.com'},
        reviewed: true,
        userConfirmed: true,
      );
      final restored = ScopePolicy.fromJson(policy.toJson());
      expect(restored.inScope, policy.inScope);
      expect(restored.outOfScope, policy.outOfScope);
      expect(restored.reviewed, isTrue);
      expect(restored.userConfirmed, isTrue);
    });
  });

  group('ToolRegistry', () {
    test('only verified tools are returned by default', () {
      final registry = ToolRegistry()
        ..register(RegisteredTool(
          id: 'nmap', name: 'Nmap', source: 'Termux pkg',
          capabilities: ['network-recon'], status: ToolInstallStatus.verified,
        ))
        ..register(RegisteredTool(
          id: 'httpx', name: 'httpx', source: 'Termux pkg',
          capabilities: ['network-recon'], status: ToolInstallStatus.missing,
        ));
      expect(registry.findByCapability('network-recon').map((tool) => tool.id), ['nmap']);
      expect(registry.findByCapability('network-recon', verifiedOnly: false), hasLength(2));
    });

    test('registry survives JSON round trip', () {
      final registry = ToolRegistry()
        ..register(RegisteredTool(
          id: 'mitmproxy', name: 'mitmproxy', source: 'Termux',
          version: '10.0', capabilities: ['http-proxy'], status: ToolInstallStatus.verified,
          verifiedAt: 123,
        ));
      final restored = ToolRegistry.fromJson(registry.toJson());
      expect(restored.find('mitmproxy')?.version, '10.0');
      expect(restored.find('mitmproxy')?.isUsable, isTrue);
    });
  });

  group('AgentController', () {
    test('batch approval is grouped and changes only proposed entries', () async {
      var calls = 0;
      final controller = AgentController(
        registry: ToolRegistry(),
        requestBatchApproval: (batch) async {
          calls++;
          expect(batch, hasLength(2));
          return true;
        },
      );
      final task = controller.createTask(conversationId: 'c1', goal: 'Recon');
      controller.proposeTools([
        ToolRequirement(id: 'a', name: 'Tool A'),
        ToolRequirement(id: 'b', name: 'Tool B'),
      ]);
      expect(await controller.approveToolBatch(), isTrue);
      expect(calls, 1);
      expect(task.toolRequirements.every((item) => item.status == ToolInstallStatus.approved), isTrue);
    });

    test('active operations are blocked until scope is reviewed and confirmed', () {
      final controller = AgentController(
        registry: ToolRegistry(),
        requestBatchApproval: (_) async => false,
      );
      controller.createTask(conversationId: 'c1', goal: 'Test target');
      controller.setPolicy(ScopePolicy(source: 'policy', inScope: {'app.example.com'}));
      expect(
        controller.authorizeOperation(target: 'app.example.com', risk: AgentOperationRisk.active).decision,
        ScopeDecision.needsReview,
      );
      expect(
        controller.authorizeOperation(target: 'app.example.com', risk: AgentOperationRisk.destructive).decision,
        ScopeDecision.deny,
      );
    });

    test('task and step state survive JSON round trip', () {
      final task = AgentTask(
        id: 'task-1',
        conversationId: 'c1',
        goal: 'Inspect app',
        steps: [AgentStep(id: 's1', title: 'Read policy', status: AgentStepStatus.completed)],
        toolRequirements: [ToolRequirement(id: 'curl', name: 'curl', status: ToolInstallStatus.verified)],
      );
      final restored = AgentTask.fromJson(task.toJson());
      expect(restored.steps.single.status, AgentStepStatus.completed);
      expect(restored.toolRequirements.single.status, ToolInstallStatus.verified);
    });
  });
}
