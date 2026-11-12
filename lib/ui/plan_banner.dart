import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'theme.dart';

/// The most recent set_plan and use_skill calls in [turnMessages] (everything since the last user
/// message), the two things shown above the chat — null when the model has not called either yet
/// this turn.
({ToolCall? plan, ToolCall? skill}) latestPlanAndSkill(List<ChatMessage> turnMessages) {
  ToolCall? plan;
  ToolCall? skill;
  for (final m in turnMessages) {
    for (final call in m.toolCalls) {
      if (call.name == 'set_plan') plan = call;
      if (call.name == 'use_skill') skill = call;
    }
  }
  return (plan: plan, skill: skill);
}

List<String> _stepsOf(ToolCall call) => ((call.args['steps'] as List?) ?? const <dynamic>[]).map((e) => e.toString()).toList();

int _currentOf(ToolCall call) => (call.args['current'] as num?)?.toInt() ?? 0;

/// Pinned above the chat (not the Steps card at the bottom): a short, tappable card showing the
/// model's own stated plan for the task it is working on now, with a done/in-progress/ahead status
/// per step.
class PlanBanner extends StatefulWidget {
  const PlanBanner({super.key, required this.call});

  final ToolCall call;

  @override
  State<PlanBanner> createState() => _PlanBannerState();
}

class _PlanBannerState extends State<PlanBanner> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final steps = _stepsOf(widget.call);
    if (steps.isEmpty) return const SizedBox.shrink();
    final total = steps.length;
    final current = _currentOf(widget.call).clamp(0, total);
    final allDone = current >= total;
    final headline = allDone ? 'Plan complete — $total/$total' : 'Step ${current + 1} of $total: ${steps[current]}';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      decoration: BoxDecoration(
        color: pal.bubble,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pal.accent.withValues(alpha: 0.35), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Icon(allDone ? CupertinoIcons.check_mark_circled_solid : CupertinoIcons.list_bullet, size: 16, color: pal.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(headline, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
              Icon(_open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 14, color: pal.secondary),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < steps.length; i++) _planStep(pal, i, steps[i], i < current ? _StepState.done : (i == current && !allDone ? _StepState.doing : _StepState.ahead)),
            ]),
          ),
      ]),
    );
  }

  Widget _planStep(Palette pal, int i, String text, _StepState state) {
    final Widget icon = switch (state) {
      _StepState.done => Icon(CupertinoIcons.check_mark_circled_solid, size: 15, color: pal.accent),
      _StepState.doing => const SizedBox(width: 13, height: 13, child: CupertinoActivityIndicator(radius: 6)),
      _StepState.ahead => Icon(CupertinoIcons.circle, size: 14, color: pal.secondary),
    };
    final style = TextStyle(
      fontSize: 13,
      color: state == _StepState.ahead ? pal.secondary : null,
      fontWeight: state == _StepState.doing ? FontWeight.w600 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 20, child: icon),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: style)),
      ]),
    );
  }
}

enum _StepState { done, doing, ahead }

/// A brief pop-up above the chat the moment a skill loads: shows the model reading it, then a short
/// "loaded" confirmation that fades on its own — so it is visible that it was read and stored, not
/// just folded away into a step the person has to go find.
class SkillLoadBanner extends StatefulWidget {
  const SkillLoadBanner({super.key, required this.name, required this.result});

  final String name;

  /// What the use_skill tool returned, or null while it is still loading.
  final String? result;

  @override
  State<SkillLoadBanner> createState() => _SkillLoadBannerState();
}

class _SkillLoadBannerState extends State<SkillLoadBanner> {
  bool _dismissed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.result != null) _scheduleDismiss();
  }

  @override
  void didUpdateWidget(covariant SkillLoadBanner old) {
    super.didUpdateWidget(old);
    if (old.result == null && widget.result != null) _scheduleDismiss();
  }

  void _scheduleDismiss() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _dismissed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final pal = paletteOf(context);
    final result = widget.result;
    final loaded = result != null;
    final failed = loaded && result.startsWith('No skill named');
    final text = !loaded
        ? 'Reading skill "${widget.name}"…'
        : failed
            ? 'Could not find skill "${widget.name}"'
            : 'Loaded skill "${widget.name}" — will follow it now';
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: 1,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          if (!loaded)
            const SizedBox(width: 15, height: 15, child: CupertinoActivityIndicator(radius: 7))
          else
            Icon(failed ? CupertinoIcons.exclamationmark_circle_fill : CupertinoIcons.check_mark_circled_solid,
                size: 16, color: failed ? iosRed : pal.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

/// Pinned above the chat, above the plan/skill banners: appears when Conversation.turnInProgress is
/// still true the moment the chat opens — the app process was killed mid-turn (backgrounded and
/// reclaimed, force-closed, crashed) rather than the turn finishing cleanly. Whatever the model had
/// already done (files written, commands run, text streamed) is really saved, just cut off; tapping
/// this resumes it with ChatEngine.continueReply rather than losing it and starting over.
class InterruptedBanner extends StatelessWidget {
  const InterruptedBanner({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return InkWell(
      onTap: onContinue,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: pal.bubble,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: iosOrange.withValues(alpha: 0.45), width: 1),
        ),
        child: Row(children: [
          Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 16, color: iosOrange),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Interrupted before finishing — tap to continue',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          Icon(CupertinoIcons.arrow_turn_down_right, size: 15, color: pal.secondary),
        ]),
      ),
    );
  }
}
