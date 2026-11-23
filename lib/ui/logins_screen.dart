import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../tools/saved_logins.dart';
import 'kit.dart';
import 'theme.dart';

/// The logins the built-in browser saved, with a switch for saving them automatically.
class LoginsScreen extends StatelessWidget {
  const LoginsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final logins = SavedLogins.instance;
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: logins,
      builder: (context, _) => GroupedPage(
        title: 'Saved logins',
        children: [
          Group(children: [
            SwitchCell(
              title: 'Save logins automatically',
              subtitle: 'After you sign in, the user name and password are kept and filled in next time',
              icon: CupertinoIcons.lock_shield,
              color: iosGreen,
              value: logins.enabled,
              onChanged: logins.setEnabled,
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
            child: Text(
              'Sites also stay signed in after you close the app (${logins.cookies.length} saved). They are kept on this phone '
              'only, inside the app\'s private storage, and are never sent to any AI provider.',
              style: TextStyle(fontSize: 13.5, color: p.secondary),
            ),
          ),
          if (logins.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Icon(CupertinoIcons.person_crop_circle_badge_checkmark, size: 36, color: p.secondary.withValues(alpha: 0.5))),
            )
          else
            Group(children: [
              for (final l in List<SavedLogin>.of(logins.items)..sort((a, b) => a.host.compareTo(b.host)))
                Cell(
                  title: l.host,
                  subtitle: l.user.isEmpty ? 'No user name' : l.user,
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(CupertinoIcons.xmark_circle_fill, color: iosGray),
                    onPressed: () => logins.remove(l),
                  ),
                ),
            ]),
          const SizedBox(height: 14),
          Group(children: [
            Cell(
              title: 'Forget all sign-ins',
              subtitle: 'Deletes the saved logins and the saved cookies',
              icon: CupertinoIcons.trash,
              color: iosRed,
              destructive: true,
              onTap: () {
                logins.clearLogins();
                logins.clearCookies();
              },
            ),
          ]),
        ],
      ),
    );
  }
}
