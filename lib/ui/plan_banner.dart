import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'theme.dart';

/// The most recent use_skill call in [turnMessages] (everything since the last user message) — what
/// the skill-load pop-up above the chat is driven by. null when no skill was loaded this turn.
ToolCall? latestSkillCall(List<ChatMessage> turnMessages) {
  ToolCall? skill;
  for (final m in turnMessages) {
    for (final call in m.toolCalls) {
      if (call.name == 'use_skill') skill = call;
    }
  }
  return skill;
}

/// A small circular badge for the conversation's plan (Conversation.planSteps/planCurrent, enforced by
/// ChatEngine.setPlan): shows progress as a ring with "done/total" inside, and opens the full
/// step-by-step list in a popup when tapped. Deliberately small — it used to be a full-width bar that
/// ate the top of the screen — and positioned in a corner so it never covers the browser's controls.
class PlanBadge extends StatelessWidget {
  const PlanBadge({super.key, required this.steps, required this.current});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    final pal = paletteOf(context);
    final total = steps.length;
    final done = current.clamp(0, total);
    final allDone = done >= total;
    return GestureDetector(
      onTap: () => showPlanDialog(context, steps, current),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: pal.bubble,
          shape: BoxShape.circle,
          border: Border.all(color: pal.accent.withValues(alpha: 0.45), width: 1),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 38,
            height: 38,
            child: CircularProgressIndicator(
              value: total == 0 ? 0 : done / total,
              strokeWidth: 3,
              backgroundColor: pal.secondary.withValues(alpha: 0.25),
              valueColor: AlwaysStoppedAnimation<Color>(pal.accent),
            ),
          ),
          allDone
              ? Icon(CupertinoIcons.check_mark, size: 16, color: pal.accent)
              : Text('$done/$total', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// The full plan as a popup: each step marked done, in progress, or still ahead.
Future<void> showPlanDialog(BuildContext context, List<String> steps, int current) {
  final pal = paletteOf(context);
  final total = steps.length;
  final done = current.clamp(0, total);
  final allDone = done >= total;
  return showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(allDone ? 'Plan complete — $total/$total' : 'Plan — step ${done + 1} of $total'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < steps.length; i++)
              _planStep(pal, steps[i], i < done ? _StepState.done : (i == done && !allDone ? _StepState.doing : _StepState.ahead)),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
    ),
  );
}

Widget _planStep(Palette pal, String text, _StepState state) {
  final Widget icon = switch (state) {
    _StepState.done => Icon(CupertinoIcons.check_mark_circled_solid, size: 16, color: pal.accent),
    _StepState.doing => const SizedBox(width: 14, height: 14, child: CupertinoActivityIndicator(radius: 6.5)),
    _StepState.ahead => Icon(CupertinoIcons.circle, size: 15, color: pal.secondary),
  };
  final style = TextStyle(
    fontSize: 14,
    color: state == _StepState.ahead ? pal.secondary : null,
    fontWeight: state == _StepState.doing ? FontWeight.w600 : FontWeight.w400,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 22, child: icon),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: style)),
    ]),
  );
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
