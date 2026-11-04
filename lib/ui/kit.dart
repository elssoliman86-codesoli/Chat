import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Page background and padding of an iOS "inset grouped" settings page.
class GroupedPage extends StatelessWidget {
  const GroupedPage({super.key, required this.title, required this.children, this.actions, this.fab});

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? fab;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Scaffold(
      backgroundColor: p.grouped,
      appBar: AppBar(title: Text(title), backgroundColor: p.grouped, actions: actions),
      floatingActionButton: fab,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
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
            child: Text(header!.toUpperCase(), style: TextStyle(fontSize: 13, color: p.secondary)),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(color: p.cell, child: Column(children: rows)),
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
    final p = paletteOf(context);
    if (!p.glass) {
      return Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 18, color: Colors.white),
      );
    }
    return GlassTile(size: 31, radius: 9, tint: color, child: Icon(icon, size: 18, color: Colors.white));
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
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
        trailing: Switch(value: value, onChanged: onChanged),
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

/// A filled iOS-style button used for main actions inside pages.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.icon, this.filled = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Material(
      color: filled ? p.accent : p.cell,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 17, color: filled ? Colors.white : p.accent), const SizedBox(width: 6)],
            Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: filled ? Colors.white : p.accent)),
          ]),
        ),
      ),
    );
  }
}
