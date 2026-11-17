import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_identity.dart';

/// Native browser owns the complete login flow; no URL or session data returns.
Future<void> openFreePressLoginCheck(BuildContext context) async {
  if (!dogreaderExperimental) return;
  try {
    await const MethodChannel('dogreader/freepress').invokeMethod<void>(
      'openLoginCheck',
    );
  } on PlatformException catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The device login check could not open.')),
      );
    }
  } on MissingPluginException catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The login check requires Android.')),
      );
    }
  }
}

class FreePressLoginTile extends StatelessWidget {
  const FreePressLoginTile({super.key});

  @override
  Widget build(BuildContext context) => dogreaderExperimental
      ? ListTile(
          leading: const Icon(Icons.login),
          title: const Text('The Free Press: test sign-in'),
          subtitle: const Text(
            'Sign in on this device and check a paid article. '
            'Chrome login is separate. Article importing is pending this test.',
          ),
          onTap: () => openFreePressLoginCheck(context),
        )
      : const SizedBox.shrink();
}
