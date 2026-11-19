import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'dogreader_audio_handler.dart';
import 'narration_delivery.dart';

enum ChapterAudioAction {
  generate,
  retryGeneration,
  download,
  retryDownload,
  play,
  pause,
}

class ChapterAudioPresentation {
  const ChapterAudioPresentation(this.label, this.hasRecording, this.action);

  factory ChapterAudioPresentation.from(
    Map<String, dynamic>? job, {
    required bool hasFile,
    required bool playing,
    required bool downloading,
  }) {
    final status = job?['status'];
    final delivery = job?['delivery'];
    final hasRecording = hasFile || playing;
    final action = hasRecording
        ? playing
              ? ChapterAudioAction.pause
              : ChapterAudioAction.play
        : null;
    if (downloading) {
      return ChapterAudioPresentation('Downloading…', hasRecording, action);
    }
    if (status == 'waiting' || status == 'queued' || status == 'generating') {
      final completed = job?['progress'];
      final total = job?['chunks'];
      final progress =
          completed is int &&
              total is int &&
              total > 0 &&
              completed >= 0 &&
              completed <= total
          ? ' · $completed/$total'
          : '';
      final label = switch (status) {
        'generating' => 'Generating…$progress',
        'waiting' => 'Waiting to submit',
        _ => 'Queued',
      };
      return ChapterAudioPresentation(label, hasRecording, action);
    }
    if (status == 'error' || job?['failureStage'] == 'generation') {
      return ChapterAudioPresentation(
        hasRecording
            ? 'Generation failed · Previous recording available'
            : 'Generation failed',
        hasRecording,
        action ?? ChapterAudioAction.retryGeneration,
      );
    }
    if (delivery == 'failed' && canRetryNarrationDownload(job)) {
      return ChapterAudioPresentation(
        hasRecording
            ? 'Download failed · Previous recording available'
            : 'Download failed',
        hasRecording,
        action ?? ChapterAudioAction.retryDownload,
      );
    }
    if (hasRecording &&
        job?['previousRecording'] is Map &&
        canRetryNarrationDownload(job)) {
      return ChapterAudioPresentation(
        'New recording ready to download',
        true,
        action,
      );
    }
    if (hasRecording) {
      return ChapterAudioPresentation(
        playing ? 'Playing' : 'Downloaded',
        true,
        action,
      );
    }
    if (canRetryNarrationDownload(job)) {
      return const ChapterAudioPresentation(
        'Ready to download',
        false,
        ChapterAudioAction.download,
      );
    }
    return const ChapterAudioPresentation(
      'No narration',
      false,
      ChapterAudioAction.generate,
    );
  }

  final String label;
  final bool hasRecording;
  final ChapterAudioAction? action;
}

extension ChapterAudioActionLabel on ChapterAudioAction {
  String get label => switch (this) {
    ChapterAudioAction.generate => 'Generate',
    ChapterAudioAction.retryGeneration => 'Retry generation',
    ChapterAudioAction.download => 'Download',
    ChapterAudioAction.retryDownload => 'Retry download',
    ChapterAudioAction.play => 'Play',
    ChapterAudioAction.pause => 'Pause',
  };
}

/// Supplies playback state to presentation widgets throughout the navigator.
class NarrationPlaybackScope extends InheritedWidget {
  const NarrationPlaybackScope({
    super.key,
    required this.handler,
    required super.child,
  });

  final DogreaderAudioHandler handler;

  static DogreaderAudioHandler? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NarrationPlaybackScope>()
      ?.handler;

  @override
  bool updateShouldNotify(NarrationPlaybackScope oldWidget) =>
      handler != oldWidget.handler;
}

/// Snapshots local files once per entry and observes the existing delivery and
/// playback streams. Includes imported MP3s that have no cloud job.
class BookNarrationStatus extends StatefulWidget {
  const BookNarrationStatus({
    super.key,
    required this.bookId,
    required this.delivery,
    required this.builder,
  });

  final String bookId;
  final NarrationDelivery delivery;
  final Widget Function(
    BuildContext context,
    ChapterAudioPresentation Function(int index) chapter,
  )
  builder;

  @override
  State<BookNarrationStatus> createState() => _BookNarrationStatusState();
}

class _BookNarrationStatusState extends State<BookNarrationStatus> {
  Set<int> _local = const {};
  int _scan = 0;
  bool _visible = false;
  DogreaderAudioHandler? _handler;
  StreamSubscription<MediaItem?>? _itemSubscription;
  StreamSubscription<PlaybackState>? _playbackSubscription;
  int? _playingChapter;

  @override
  void initState() {
    super.initState();
    widget.delivery.addListener(_deliveryChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final handler = NarrationPlaybackScope.maybeOf(context);
    if (_handler != handler) {
      _itemSubscription?.cancel();
      _playbackSubscription?.cancel();
      _handler = handler;
      _itemSubscription = handler?.mediaItem.listen((_) => _playbackChanged());
      _playbackSubscription = handler?.playbackState.listen(
        (_) => _playbackChanged(),
      );
    }
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible && !_visible) unawaited(_refresh());
    _visible = visible;
  }

  Future<void> _refresh() async {
    final scan = ++_scan;
    final found = <int>{};
    try {
      await widget.delivery.load();
      final root = await widget.delivery.documentsDirectory();
      final folder = Directory('${root.path}/narration');
      final prefix = '${widget.bookId}_';
      if (await folder.exists()) {
        await for (final entry in folder.list(followLinks: false)) {
          if (scan != _scan || !mounted) return;
          final name = entry.uri.pathSegments.last;
          if (entry is! File ||
              !name.startsWith(prefix) ||
              !name.endsWith('.mp3')) {
            continue;
          }
          final index = int.tryParse(
            name.substring(prefix.length, name.length - 4),
          );
          if (index != null && (await entry.stat()).size >= 1000) {
            found.add(index);
          }
        }
      }
    } catch (_) {
      // Delivery metadata can still report recordings if disk discovery fails.
      return;
    }
    if (mounted && scan == _scan) setState(() => _local = found);
  }

  void _deliveryChanged() {
    if (!mounted) return;
    setState(() {});
    if (_visible) unawaited(_refresh());
  }

  void _playbackChanged() {
    final item = _handler?.mediaItem.value?.id;
    final prefix = '${widget.bookId}:';
    final index =
        item != null &&
            item.startsWith(prefix) &&
            _handler?.playbackState.value.playing == true
        ? int.tryParse(item.substring(prefix.length))
        : null;
    if (mounted && index != _playingChapter) {
      setState(() => _playingChapter = index);
    }
  }

  @override
  void dispose() {
    widget.delivery.removeListener(_deliveryChanged);
    _itemSubscription?.cancel();
    _playbackSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, (index) {
    final job = widget.delivery.books[widget.bookId]?[index];
    return ChapterAudioPresentation.from(
      job,
      hasFile: _local.contains(index) || job?['localAvailable'] == true,
      playing: index == _playingChapter,
      downloading: widget.delivery.downloading(widget.bookId, index),
    );
  });
}
