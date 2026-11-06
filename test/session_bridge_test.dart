import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/method_channel_audio_service.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'seek_cancellation_test.dart' show LostSeekPlayer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real audio_service Dart bridge, mocked Android MethodChannels and player.
  // Proves which native lifecycle requests are sent, not physical media taps.
  test(
    'native decoder release during navigation must not stop the service',
    () async {
      AudioServicePlatform.instance = MethodChannelAudioService();
      const client = MethodChannel(
        'com.ryanheise.audio_service.client.methods',
      );
      const channel = MethodChannel(
        'com.ryanheise.audio_service.handler.methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requests = <MethodCall>[];
      var failPublication = false;
      messenger.setMockMethodCallHandler(client, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests.add(call);
        if (failPublication && call.method == 'setState') {
          failPublication = false;
          throw PlatformException(
            code: 'lost-session',
            message: 'session bridge unavailable',
          );
        }
        return null;
      });
      final root = await Directory.systemTemp.createTemp('dogreader-bridge-');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      final player = LostSeekPlayer();
      final handler = await AudioService.init(
        builder: () => DogreaderAudioHandler(
          player: player,
          documentsDirectory: () async => root,
        ),
      );
      Future<void> flush() =>
          Future<void>.delayed(const Duration(milliseconds: 20));
      Future<void> load(int index) => handler.loadChapter(
        path: '${root.path}/book_$index.mp3',
        title: 'Chapter',
        author: 'Author',
        bookId: 'book',
        chapterIndex: index,
        chapterCount: 2,
      );
      Future<void> external(String method) async {
        final reply = Completer<void>();
        ServicesBinding.instance.channelBuffers.push(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (data) {
            try {
              const StandardMethodCodec().decodeEnvelope(data!);
              reply.complete();
            } catch (error, stack) {
              reply.completeError(error, stack);
            }
          },
        );
        await reply.future;
        await flush();
      }

      try {
        await load(0);
        await external('play');
        requests.clear();
        final seeking = handler.seek(const Duration(seconds: 90));
        await player.seeking.future;
        await load(1).timeout(const Duration(seconds: 1));
        await seeking;
        await flush();
        expect(
          requests.where((c) => c.method == 'stopService'),
          isEmpty,
          reason: 'Releasing a seek/decoder is not an instruction to end the Android session',
        );
        expect(handler.mediaItem.value?.id, 'book:1');
        await external('play');
        expect(player.playing, isTrue);
        await external('pause');
        expect(player.playing, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
        expect(requests.where((c) => c.method == 'stopService'), isEmpty);

        failPublication = true;
        await external('play');
        expect(handler.diagnosticLastSessionError, contains('lost-session'));
        expect(handler.diagnosticLastError, isNull);
        expect(player.playing, isTrue);

        await handler.stop();
        await flush();
        expect(requests.where((c) => c.method == 'stopService'), hasLength(1));
        expect(player.playing, isFalse);
      } finally {
        if (!player.seekReply.isCompleted) player.seekReply.complete();
        await handler.dispose();
        await flush();
        messenger.setMockMethodCallHandler(client, null);
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(paths, null);
        await root.delete(recursive: true);
      }
    },
  );
}
