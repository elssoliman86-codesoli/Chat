import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'glass/glass.dart';
import 'theme.dart';

/// A settings-style page: transparent so the midnight glass scene shows, with a frosted navigation bar
/// that the content scrolls (and blurs) underneath.
class GroupedPage extends StatelessWidget {
  const GroupedPage({super.key, required this.title, required this.children, this.actions, this.fab});

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? fab;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + 10;
    final bottom = MediaQuery.paddingOf(context).bottom + 100;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassNavigation(title: title, actions: actions),
      floatingActionButton: fab,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
        children: children,
      ),
    );
  }
}

/// A rounded block of cells with an optional header and footer.
class Group extends StatelessWidget {
  const Group({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Divider(height: 0.5, thickness: 0.5, indent: 16, color: p.separator));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(header!.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: 0.6, fontWeight: FontWeight.w600, color: p.secondary)),
          ),
        FrostedGlassCard(
          padding: EdgeInsets.zero,
          radius: GlassTokens.radiusMd,
          child: Column(children: rows),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(footer!, style: TextStyle(fontSize: 13, color: p.secondary)),
          ),
      ]),
    );
  }
}

/// The small colored square icon of settings rows. In the emerald theme it is a glass tile.
class Badge29 extends StatelessWidget {
  const Badge29(this.icon, this.color, {super.key});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GlassTile(size: 31, radius: 9, tint: color, child: Icon(icon, size: GlassTokens.iconMd - 2, color: Colors.white));
  }
}

/// A frosted, glossy tile: tinted gradient, bright rim and a soft highlight on top.
class GlassTile extends StatelessWidget {
  const GlassTile({super.key, required this.size, required this.radius, required this.tint, required this.child});

  final double size;
  final double radius;
  final Color tint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tint.withValues(alpha: 0.85), tint.withValues(alpha: 0.30)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.38), width: 0.8),
        boxShadow: [BoxShadow(color: tint.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Positioned(
          left: 2,
          right: 2,
          top: 2,
          height: size * 0.42,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(radius - 2), bottom: Radius.circular(radius)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white.withValues(alpha: 0.34), Colors.white.withValues(alpha: 0.0)],
              ),
            ),
          ),
        ),
        child,
      ]),
    );
  }
}

class Cell extends StatelessWidget {
  const Cell({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.color,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      onTap: onTap,
      highlightColor: p.accent.withValues(alpha: 0.10),
      splashColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          if (icon != null) ...[Badge29(icon!, color ?? p.accent), const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 16.5, color: destructive ? iosRed : null)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.secondary)),
                ),
            ]),
          ),
          if (trailing != null) trailing!,
          if (chevron) Icon(CupertinoIcons.chevron_forward, size: 16, color: p.secondary),
        ]),
      ),
    );
  }
}

class SwitchCell extends StatelessWidget {
  const SwitchCell({super.key, required this.title, this.subtitle, this.icon, this.color, required this.value, required this.onChanged});

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? color;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Cell(
        title: title,
        subtitle: subtitle,
        icon: icon,
        color: color,
        onTap: () => onChanged(!value),
        trailing: GlassToggle(value: value, onChanged: onChanged, semanticLabel: title),
      );
}

/// A text field that sits inside a [Group] like an iOS form row.
class FieldCell extends StatelessWidget {
  const FieldCell({
    super.key,
    required this.controller,
    required this.label,
    this.obscure = false,
    this.keyboard,
    this.lines = 1,
    this.maxLines,
    this.onChanged,
    this.suffix,
    this.hint,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final TextInputType? keyboard;
  final int lines;
  final int? maxLines;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: p.secondary)),
        Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboard ?? (lines > 1 ? TextInputType.multiline : TextInputType.text),
              minLines: lines,
              maxLines: maxLines ?? (lines > 1 ? lines + 12 : 1),
              autocorrect: !obscure,
              enableSuggestions: !obscure,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 16.5),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
          if (suffix != null) suffix!,
        ]),
      ]),
    );
  }
}

/// A glass button used for main actions inside pages (kept under its old name so every screen gets the new look).
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.icon, this.filled = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) => GlassButton(
        label: label,
        onPressed: onPressed,
        icon: icon,
        compact: true,
        style: filled ? GlassButtonStyle.primary : GlassButtonStyle.secondary,
      );
}
