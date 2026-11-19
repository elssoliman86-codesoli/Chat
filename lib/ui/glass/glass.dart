import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'tokens.dart';

export 'tokens.dart';

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// A control's interaction state (pressed / focused), shared by buttons and icon buttons.
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A light haptic tick; never lets a missing platform channel (tests, desktop) raise an error.
void _tick() {
  HapticFeedback.selectionClick().catchError((Object _) {});
}

class _Control extends StatefulWidget {
  const _Control({required this.builder, required this.onTap, required this.enabled, this.label, this.tooltip});

  final Widget Function(BuildContext context, bool pressed, bool focused) builder;
  final VoidCallback? onTap;
  final bool enabled;
  final String? label;
  final String? tooltip;

  @override
  State<_Control> createState() => _ControlState();
}

class _ControlState extends State<_Control> {
  bool _pressed = false;
  bool _focused = false;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled && widget.onTap != null;
    Widget w = FocusableActionDetector(
      enabled: on,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: on ? (_) => _set(true) : null,
        onTapUp: on ? (_) => _set(false) : null,
        onTapCancel: on ? () => _set(false) : null,
        onTap: on
            ? () {
                _tick();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1,
          duration: GlassTokens.fast,
          curve: Curves.easeOut,
          child: widget.builder(context, _pressed, _focused),
        ),
      ),
    );
    w = Semantics(button: true, enabled: on, label: widget.label, child: w);
    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) w = Tooltip(message: widget.tooltip!, child: w);
    return w;
  }
}

BoxShadow _soft(Palette p, {double a = 0.35, double blur = 16, double dy = 6}) =>
    BoxShadow(color: p.shadow.withValues(alpha: (p.shadow.a * a / 0.35).clamp(0.0, 1.0)), blurRadius: blur, offset: Offset(0, dy));

Widget _sheen(Palette p, double radius) => Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(begin: Alignment.topLeft, end: const Alignment(0.3, 0.5), colors: [p.sheen, p.sheen.withValues(alpha: 0)]),
          ),
        ),
      ),
    );

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// FrostedGlassCard
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A translucent frosted panel: thin bright rim, soft top-left sheen, gentle directional shadow.
/// [blur] adds a real backdrop blur (use it on a few large panels, not on every list row).
class FrostedGlassCard extends StatelessWidget {
  const FrostedGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.radius = GlassTokens.radiusMd,
    this.blur = false,
    this.strong = false,
    this.glow = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool blur;

  /// The denser fill used by dialogs and sheets.
  final bool strong;

  /// A faint cyan halo for the one panel that should draw the eye.
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    Widget body = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: strong ? p.surface : p.fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.rim, width: GlassTokens.stroke),
        boxShadow: [_soft(p), if (glow) BoxShadow(color: p.glow.withValues(alpha: 0.16), blurRadius: 18)],
      ),
      child: Stack(children: [_sheen(p, radius), Padding(padding: padding, child: child)]),
    );
    if (blur) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: GlassTokens.blurSoft, sigmaY: GlassTokens.blurSoft), child: body),
      );
    }
    if (onTap != null) {
      final inner = body;
      body = _Control(enabled: true, onTap: onTap, builder: (_, __, ___) => inner);
    }
    return margin == null ? body : Padding(padding: margin!, child: body);
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassButton
// ─────────────────────────────────────────────────────────────────────────────────────────────────

enum GlassButtonStyle { primary, secondary, ghost, danger }

/// A tactile glass button with pressed, disabled, loading, selected (active) and focus states.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = GlassButtonStyle.secondary,
    this.loading = false,
    this.selected = false,
    this.expanded = false,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final GlassButtonStyle style;
  final bool loading;
  final bool selected;
  final bool expanded;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final fg = Theme.of(context).colorScheme.onSurface;
    final enabled = onPressed != null && !loading;
    final h = compact ? GlassTokens.controlHeightCompact : GlassTokens.controlHeight;
    final primaryFill = Color.lerp(p.accent, Colors.black, 0.18)!;
    final (Color fill, Color border, Color text) = switch (style) {
      GlassButtonStyle.primary => (primaryFill, Colors.white.withValues(alpha: 0.30), Colors.white),
      GlassButtonStyle.secondary => (selected ? p.accent.withValues(alpha: 0.18) : p.fill, selected ? p.accent : p.rim, selected ? p.accent : fg),
      GlassButtonStyle.ghost => (Colors.transparent, Colors.transparent, p.accent),
      GlassButtonStyle.danger => (iosRed.withValues(alpha: 0.14), iosRed.withValues(alpha: 0.45), iosRed),
    };
    return _Control(
      enabled: enabled,
      onTap: onPressed,
      label: label,
      builder: (context, pressed, focused) {
        final glow = style == GlassButtonStyle.primary || selected;
        return AnimatedOpacity(
          opacity: onPressed == null ? 0.45 : 1,
          duration: GlassTokens.fast,
          child: AnimatedContainer(
            duration: GlassTokens.fast,
            height: h,
            width: expanded ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18),
            decoration: BoxDecoration(
              color: pressed ? Color.lerp(fill, Colors.black, 0.18) : fill,
              borderRadius: BorderRadius.circular(GlassTokens.radiusSm + 2),
              border: Border.all(color: focused ? p.glow : border, width: focused ? 1.6 : GlassTokens.stroke),
              boxShadow: [
                if (style != GlassButtonStyle.ghost && !pressed) _soft(p, a: 0.28, blur: 12, dy: 4),
                if (glow && !pressed) BoxShadow(color: p.accent.withValues(alpha: 0.30), blurRadius: 14),
                if (focused) BoxShadow(color: p.glow.withValues(alpha: 0.35), blurRadius: 10),
              ],
            ),
            child: Row(mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (loading)
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: text))
              else if (icon != null)
                Icon(icon, size: GlassTokens.iconSm + 1, color: style == GlassButtonStyle.secondary && !selected ? p.accent : text),
              if (loading || icon != null) const SizedBox(width: 8),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 14 : 15, fontWeight: FontWeight.w600, color: text))),
            ]),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassIconButton
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A round glass icon button. [active] lights it electric blue; [loading] swaps the icon for a spinner.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
    this.loading = false,
    this.size = 40,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;
  final bool loading;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final fg = color ?? (active ? p.accent : Theme.of(context).colorScheme.onSurface);
    final enabled = onPressed != null && !loading;
    return _Control(
      enabled: enabled,
      onTap: onPressed,
      label: tooltip,
      tooltip: tooltip,
      builder: (context, pressed, focused) => AnimatedOpacity(
        opacity: onPressed == null ? 0.45 : 1,
        duration: GlassTokens.fast,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pressed ? Color.lerp(active ? p.accent.withValues(alpha: 0.28) : p.fill, Colors.black, 0.2) : (active ? p.accent.withValues(alpha: 0.18) : p.fill),
            border: Border.all(color: focused ? p.glow : (active ? p.accent : p.rim), width: focused ? 1.6 : GlassTokens.stroke),
            boxShadow: [
              if (!pressed) _soft(p, a: 0.25, blur: 10, dy: 3),
              if (active) BoxShadow(color: p.accent.withValues(alpha: 0.35), blurRadius: 12),
              if (focused) BoxShadow(color: p.glow.withValues(alpha: 0.35), blurRadius: 10),
            ],
          ),
          child: Center(
            child: loading
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Icon(icon, size: GlassTokens.iconMd, color: fg),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassInput
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A glass text field: a thin rim that turns electric blue (with a faint glow) on focus, red on error.
class GlassInput extends StatefulWidget {
  const GlassInput({
    super.key,
    this.controller,
    this.hint,
    this.label,
    this.icon,
    this.obscure = false,
    this.errorText,
    this.enabled = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.suffix,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController? controller;
  final String? hint;
  final String? label;
  final IconData? icon;
  final bool obscure;
  final String? errorText;
  final bool enabled;
  final int minLines;
  final int maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;

  void _listen() {
    if (_node.hasFocus != _focused && mounted) setState(() => _focused = _node.hasFocus);
  }

  @override
  void initState() {
    super.initState();
    _node.addListener(_listen);
  }

  @override
  void dispose() {
    _node.removeListener(_listen);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final error = widget.errorText != null && widget.errorText!.isNotEmpty;
    final edge = error ? iosRed : (_focused ? p.accent : p.rim);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.label != null)
        Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(widget.label!, style: TextStyle(fontSize: 12.5, color: p.secondary))),
      AnimatedContainer(
        duration: GlassTokens.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: widget.enabled ? p.field : p.field.withValues(alpha: p.field.a * 0.5),
          borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
          border: Border.all(color: edge, width: _focused || error ? 1.3 : GlassTokens.stroke),
          boxShadow: [if (_focused && !error) BoxShadow(color: p.glow.withValues(alpha: 0.20), blurRadius: 12)],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (widget.icon != null) ...[Icon(widget.icon, size: GlassTokens.iconMd - 2, color: _focused ? p.accent : p.secondary), const SizedBox(width: 10)],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _node,
              enabled: widget.enabled,
              obscureText: widget.obscure,
              minLines: widget.minLines,
              maxLines: widget.obscure ? 1 : widget.maxLines,
              keyboardType: widget.keyboardType,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              style: const TextStyle(fontSize: 16),
              cursorColor: p.accent,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                hintText: widget.hint,
                hintStyle: TextStyle(color: p.secondary),
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          if (widget.suffix != null) widget.suffix!,
        ]),
      ),
      if (error) Padding(padding: const EdgeInsets.only(left: 4, top: 5), child: Text(widget.errorText!, style: const TextStyle(fontSize: 12.5, color: iosRed))),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassNavigation
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A frosted top bar: the page content scrolls underneath and is blurred by it. Use it as a Scaffold
/// appBar together with `extendBodyBehindAppBar: true`.
class GlassNavigation extends StatelessWidget implements PreferredSizeWidget {
  const GlassNavigation({super.key, this.title, this.titleWidget, this.leading, this.actions, this.automaticallyImplyLeading = true});

  final String? title;
  final Widget? titleWidget;
  final Widget? leading;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final canPop = Navigator.of(context).canPop();
    Widget? lead = leading;
    if (lead == null && automaticallyImplyLeading && canPop) {
      lead = Center(child: GlassIconButton(icon: CupertinoIcons.chevron_back, tooltip: 'Back', size: 36, onPressed: () => Navigator.maybePop(context)));
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GlassTokens.blurStrong, sigmaY: GlassTokens.blurStrong),
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.surface.withValues(alpha: p.surface.a * 0.55), border: Border(bottom: BorderSide(color: p.rim, width: GlassTokens.stroke))),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: kToolbarHeight,
              child: NavigationToolbar(
                leading: lead == null ? null : Padding(padding: const EdgeInsets.only(left: 12), child: lead),
                middle: titleWidget ?? (title == null ? null : Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                trailing: actions == null ? null : Row(mainAxisSize: MainAxisSize.min, children: [...actions!, const SizedBox(width: 8)]),
                centerMiddle: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassDialog + GlassBottomSheet
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A drop-in for AlertDialog with a blurred frosted surface.
class GlassDialog extends StatelessWidget {
  const GlassDialog({super.key, this.title, this.content, this.actions, this.icon, this.scrollable = false});

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final IconData? icon;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final theme = Theme.of(context);
    Widget? body = content;
    if (body != null) {
      body = DefaultTextStyle(style: theme.textTheme.bodyMedium!.copyWith(fontSize: 15, height: 1.35), child: body);
      if (scrollable) body = SingleChildScrollView(child: body);
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(GlassTokens.radiusLg),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: GlassTokens.blurStrong, sigmaY: GlassTokens.blurStrong),
            child: Container(
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(GlassTokens.radiusLg),
                border: Border.all(color: p.rim, width: GlassTokens.stroke),
                boxShadow: [_soft(p, a: 0.5, blur: 30, dy: 12)],
              ),
              child: Stack(children: [
                _sheen(p, GlassTokens.radiusLg),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
                  child: IntrinsicWidth(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (icon != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Icon(icon, size: 26, color: p.accent)),
                      if (title != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: DefaultTextStyle(style: theme.textTheme.titleLarge!.copyWith(fontSize: 18, fontWeight: FontWeight.w600), child: title!),
                        ),
                      if (body != null) Flexible(child: body),
                      if (actions != null && actions!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, overflowSpacing: 4, children: actions!),
                        ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The frosted surface of a bottom sheet (drag handle, blur, rim).
class GlassBottomSheet extends StatelessWidget {
  const GlassBottomSheet({super.key, required this.child, this.showHandle = true});

  final Widget child;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const r = Radius.circular(GlassTokens.radiusLg);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: r),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GlassTokens.blurStrong, sigmaY: GlassTokens.blurStrong),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: const BorderRadius.vertical(top: r),
            border: Border(top: BorderSide(color: p.rim, width: GlassTokens.stroke)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (showHandle)
                Padding(
                  padding: const EdgeInsets.only(top: 9, bottom: 4),
                  child: Container(width: 38, height: 4, decoration: BoxDecoration(color: p.secondary.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(2))),
                ),
              Flexible(child: child),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Opens [builder] in a frosted bottom sheet. Same shape as showModalBottomSheet.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  bool useSafeArea = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (c) => GlassBottomSheet(showHandle: showDragHandle, child: builder(c)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassStatusIndicator
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A small glowing status dot, optionally with a label pill. Running pulses softly.
class GlassStatusIndicator extends StatefulWidget {
  const GlassStatusIndicator({super.key, required this.status, this.label, this.size = 9, this.showLabel = false});

  final GlassStatus status;
  final String? label;
  final double size;
  final bool showLabel;

  @override
  State<GlassStatusIndicator> createState() => _GlassStatusIndicatorState();
}

class _GlassStatusIndicatorState extends State<GlassStatusIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void initState() {
    super.initState();
    if (widget.status == GlassStatus.running) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(GlassStatusIndicator old) {
    super.didUpdateWidget(old);
    if (widget.status == GlassStatus.running && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (widget.status != GlassStatus.running && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final color = glassStatusColor(widget.status, p.accent, p.secondary);
    final text = widget.label ?? glassStatusLabel(widget.status);
    final dot = AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: widget.status == GlassStatus.idle || widget.status == GlassStatus.cancelled
              ? null
              : [BoxShadow(color: color.withValues(alpha: 0.35 + 0.4 * _c.value), blurRadius: 6 + 4 * _c.value)],
        ),
      ),
    );
    final Widget core = widget.showLabel
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.4), width: GlassTokens.stroke),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              dot,
              const SizedBox(width: 6),
              Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ]),
          )
        : dot;
    return Semantics(label: text, child: core);
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// GlassToggle
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// A tactile switch: a recessed glass track and a raised thumb; lit electric blue when on.
class GlassToggle extends StatelessWidget {
  const GlassToggle({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final enabled = onChanged != null;
    final onFill = Color.lerp(p.accent, Colors.black, 0.12)!;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                _tick();
                onChanged!(!value);
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: AnimatedContainer(
              duration: GlassTokens.base,
              curve: Curves.easeOutCubic,
              width: 52,
              height: 30,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: value ? onFill : p.field,
                border: Border.all(color: value ? Colors.white.withValues(alpha: 0.28) : p.rim, width: GlassTokens.stroke),
                boxShadow: [if (value) BoxShadow(color: p.accent.withValues(alpha: 0.38), blurRadius: 12)],
              ),
              child: AnimatedAlign(
                duration: GlassTokens.base,
                curve: Curves.easeOutCubic,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 4, offset: const Offset(0, 2))],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
