// iOS 26 lets a task the user started keep running after the app leaves the screen. The native
// side has to ask while the app is in front, so it needs to know as soon as a local turn starts
// (ios/Runner/ContinuedRun.swift). HarmonyOS and older iOS have nothing to ask for.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/read_list_cache.dart';
import '../state/read_list_identity.dart';
import '../state/sessions_state.dart';
import 'runtime_state.dart';

/// Whether the on-device engine has a running turn or a foreground submission
/// that is about to start one.
final localTurnRunningProvider = Provider<bool>((ref) {
  if (!ref.watch(activeHostProvider).isLocal) return false;
  final sessions = ref.watch(sessionsProvider.select((state) => state.value));
  final connection = ref.watch(readListLiveConnectionProvider);
  final identity = ref.watch(readListIdentityProvider);
  final cache = ref.watch(readListCacheProvider);
  // AsyncValue may retain another host's rows while loading or after a failed
  // read. Keep same-source refreshes, but never treat display carryover as a
  // running turn on the current local client.
  final listed =
      sessions != null &&
      connection != null &&
      connection.isLocal &&
      cache.current(sessions, identity, connection.client) &&
      sessions.any((session) => session.running);
  if (listed) return true;
  final open = ref.watch(currentSessionProvider);
  if (open == null) return false;
  return ref.watch(
    chatProvider(open).select(
      (chat) =>
          chat.running ||
          chat.pending.any(
            (prompt) => prompt.mode == SendMode.now && prompt.inboxId == null && !prompt.failed && !prompt.isAutomatic,
          ),
    ),
  );
});

/// Keep this watched while the shell is up. Draws nothing and holds nothing.
final continuedRunProvider = Provider<void>((ref) {
  if (ref.watch(operatingSystemProvider) != 'ios') return;
  ref.listen(localTurnRunningProvider, (was, now) {
    if (was == now) return;
    unawaited(_tell(ref, now));
  }, fireImmediately: true);
});

Future<void> _tell(Ref ref, bool running) async {
  try {
    await ref.read(runtimeBridgeProvider).setTurnRunning(running);
  } on MissingPluginException {
    // A build without the engine.
  } on PlatformException {
    // The engine's channel refused. Nothing depends on this: it would pause, as it does anyway.
  }
}
