import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'narration_options.dart';
import 'narration_storage.dart';

const int defaultMonthlyFreeGoogleCharacters = 1000000;
const double defaultMonthlyGoogleCreditUsd = 10.0;
const double googleChirpUsdPerMillionCharacters = 30.0;
const double googleWavenetUsdPerMillionCharacters = 16.0;

double googleVoiceUsdPerMillion(String? voice) {
  if (voice != null && voice.toLowerCase().contains('wavenet')) {
    return googleWavenetUsdPerMillionCharacters;
  }
  return googleChirpUsdPerMillionCharacters;
}

int coveredGoogleCharactersForBudget({
  int freeCharacters = defaultMonthlyFreeGoogleCharacters,
  double monthlyCreditUsd = defaultMonthlyGoogleCreditUsd,
  String? voice,
}) {
  final rate = googleVoiceUsdPerMillion(voice);
  final creditChars = rate <= 0 ? 0 : (monthlyCreditUsd * 1000000.0 / rate).floor();
  return math.max(0, freeCharacters) + math.max(0, creditChars);
}

String billingMonthKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

String formatCharacterCount(int count) {
  final negative = count < 0;
  final digits = count.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return negative ? '-$buffer' : buffer.toString();
}

String formatUsdAmount(double amount) {
  final clamped = amount.isFinite ? amount : 0.0;
  if (clamped > 0 && clamped < 0.005) return '<\$0.01';
  final sign = clamped < 0 ? '-' : '';
  return '$sign\$${clamped.abs().toStringAsFixed(2)}';
}

class NarrationMonthUsage {
  final String monthKey;
  final int googleCharacters;
  final int kokoroCharacters;
  final Set<String> recordedJobIds;

  NarrationMonthUsage({
    required this.monthKey,
    this.googleCharacters = 0,
    this.kokoroCharacters = 0,
    Set<String>? recordedJobIds,
  }) : recordedJobIds = Set<String>.from(recordedJobIds ?? const <String>{});

  factory NarrationMonthUsage.fromJson(String key, Map<String, dynamic> data) {
    final google = (data['googleCharacters'] as num?)?.toInt() ?? 0;
    final kokoro = (data['kokoroCharacters'] as num?)?.toInt() ?? 0;
    final ids = (data['jobIds'] as List? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toSet();
    return NarrationMonthUsage(
      monthKey: key,
      googleCharacters: math.max(0, google),
      kokoroCharacters: math.max(0, kokoro),
      recordedJobIds: ids,
    );
  }

  Map<String, dynamic> toJson() => {
    'googleCharacters': googleCharacters,
    'kokoroCharacters': kokoroCharacters,
    'jobIds': recordedJobIds.toList()..sort(),
  };
}

class NarrationCostEstimate {
  final String monthKey;
  final int freeCharacterLimit;
  final double monthlyCreditLimitUsd;
  final int usedGoogleCharacters;
  final int usedKokoroCharacters;
  final String selectedEngine;
  final String selectedVoice;
  final int selectionCharacters;

  const NarrationCostEstimate({
    required this.monthKey,
    required this.freeCharacterLimit,
    required this.monthlyCreditLimitUsd,
    required this.usedGoogleCharacters,
    required this.usedKokoroCharacters,
    required this.selectedEngine,
    required this.selectedVoice,
    required this.selectionCharacters,
  });

  double get voiceUsdPerMillion =>
      selectedEngine == 'google' ? googleVoiceUsdPerMillion(selectedVoice) : 0.0;

  double get googleBenchmarkUsdPerMillion =>
      selectedEngine == 'google'
          ? googleVoiceUsdPerMillion(selectedVoice)
          : googleChirpUsdPerMillionCharacters;

  int get creditCharacterAllowance =>
      googleBenchmarkUsdPerMillion <= 0
          ? 0
          : (monthlyCreditLimitUsd * 1000000.0 / googleBenchmarkUsdPerMillion)
                .floor();

  int get totalCoveredGoogleCharacters =>
      freeCharacterLimit + creditCharacterAllowance;

  int get freeCharactersUsed =>
      math.min(usedGoogleCharacters, freeCharacterLimit);

  int get freeCharactersRemaining =>
      math.max(0, freeCharacterLimit - usedGoogleCharacters);

  int get billableCharactersUsed =>
      math.max(0, usedGoogleCharacters - freeCharacterLimit);

  double get grossGoogleUsdUsed =>
      billableCharactersUsed * googleBenchmarkUsdPerMillion / 1000000.0;

  double get creditUsdUsed =>
      math.min(monthlyCreditLimitUsd, grossGoogleUsdUsed);

  double get creditUsdRemaining =>
      math.max(0.0, monthlyCreditLimitUsd - grossGoogleUsdUsed);

  double get outOfPocketUsdUsed =>
      math.max(0.0, grossGoogleUsdUsed - monthlyCreditLimitUsd);

  int get coveredCharactersRemaining =>
      math.max(0, totalCoveredGoogleCharacters - usedGoogleCharacters);

  double get allowanceUsedFraction => totalCoveredGoogleCharacters <= 0
      ? 1.0
      : (usedGoogleCharacters / totalCoveredGoogleCharacters).clamp(0.0, 1.0);

  bool get allowanceExhausted =>
      usedGoogleCharacters >= totalCoveredGoogleCharacters;

  int get projectedGoogleCharacters => selectedEngine == 'google'
      ? usedGoogleCharacters + math.max(0, selectionCharacters)
      : usedGoogleCharacters;

  int get projectedFreeCharactersRemaining =>
      math.max(0, freeCharacterLimit - projectedGoogleCharacters);

  int get projectedBillableCharacters =>
      math.max(0, projectedGoogleCharacters - freeCharacterLimit);

  double get projectedGrossGoogleUsd =>
      projectedBillableCharacters * googleBenchmarkUsdPerMillion / 1000000.0;

  double get projectedCreditUsdRemaining =>
      math.max(0.0, monthlyCreditLimitUsd - projectedGrossGoogleUsd);

  double get projectedOutOfPocketUsd =>
      math.max(0.0, projectedGrossGoogleUsd - monthlyCreditLimitUsd);

  int get projectedCoveredCharactersRemaining =>
      math.max(0, totalCoveredGoogleCharacters - projectedGoogleCharacters);

  double get projectedAllowanceUsedFraction => totalCoveredGoogleCharacters <= 0
      ? 1.0
      : (projectedGoogleCharacters / totalCoveredGoogleCharacters).clamp(
          0.0,
          1.0,
        );

  int get selectionCoveredByFreeCharacters => selectedEngine != 'google'
      ? 0
      : math.min(math.max(0, selectionCharacters), freeCharactersRemaining);

  int get selectionCoveredByCreditCharacters {
    if (selectedEngine != 'google') return 0;
    final afterFree =
        math.max(0, selectionCharacters) - selectionCoveredByFreeCharacters;
    final remainingCreditChars = math.max(
      0,
      coveredCharactersRemaining - freeCharactersRemaining,
    );
    return math.min(afterFree, remainingCreditChars);
  }

  int get selectionUncoveredCharacters => selectedEngine != 'google'
      ? 0
      : math.max(
          0,
          math.max(0, selectionCharacters) -
              selectionCoveredByFreeCharacters -
              selectionCoveredByCreditCharacters,
        );

  double get selectionGrossUsd => selectedEngine != 'google'
      ? 0.0
      : math.max(0.0, projectedGrossGoogleUsd - grossGoogleUsdUsed);

  double get selectionCreditUsedUsd => selectedEngine != 'google'
      ? 0.0
      : math.max(0.0, creditUsdRemaining - projectedCreditUsdRemaining);

  double get selectionOutOfPocketUsd => selectedEngine != 'google'
      ? 0.0
      : math.max(0.0, projectedOutOfPocketUsd - outOfPocketUsdUsed);

  bool get selectionExceedsAllowance =>
      selectedEngine == 'google' &&
      selectionCharacters > 0 &&
      projectedGoogleCharacters > totalCoveredGoogleCharacters;

  bool get shouldSwitchToKokoro =>
      allowanceExhausted || selectionExceedsAllowance;

  bool get approachingLimit =>
      !shouldSwitchToKokoro &&
      totalCoveredGoogleCharacters > 0 &&
      (projectedCoveredCharactersRemaining <= 100000 ||
          projectedGoogleCharacters >=
              (totalCoveredGoogleCharacters * 0.9).floor());

  String monthlyAllowanceSummary() {
    return 'Google allowance ($monthKey): '
        '${formatCharacterCount(usedGoogleCharacters)} / '
        '${formatCharacterCount(totalCoveredGoogleCharacters)} covered chars used '
        '(${formatCharacterCount(freeCharactersRemaining)} free + '
        '${formatUsdAmount(creditUsdRemaining)} credit left)';
  }

  String selectionImpactSummary() {
    if (selectionCharacters <= 0) {
      if (allowanceExhausted) {
        return '1M free tier + ${formatUsdAmount(monthlyCreditLimitUsd)} credit used up this month. '
            'Use Kokoro (\$0.00) to avoid charges.';
      }
      return '${formatCharacterCount(coveredCharactersRemaining)} covered Google chars remaining this month before charges.';
    }
    final charsLabel = '${formatCharacterCount(selectionCharacters)} chars';
    if (selectedEngine == 'kokoro') {
      return 'Selected ($charsLabel): \$0.00 API cost with Kokoro '
          '(${formatCharacterCount(coveredCharactersRemaining)} Google chars / '
          '${formatUsdAmount(creditUsdRemaining)} credit preserved)';
    }
    if (selectionOutOfPocketUsd > 0 || allowanceExhausted) {
      return 'Selected ($charsLabel): exceeds 1M free tier + '
          '${formatUsdAmount(monthlyCreditLimitUsd)} credit by '
          '${formatCharacterCount(selectionUncoveredCharacters)} chars '
          '(+${formatUsdAmount(selectionOutOfPocketUsd)} out of pocket). '
          'Switch to Kokoro for \$0.00.';
    }
    if (selectionCreditUsedUsd > 0) {
      return 'Selected ($charsLabel): \$0.00 out of pocket '
          '(uses ${formatUsdAmount(selectionCreditUsedUsd)} of '
          '${formatUsdAmount(monthlyCreditLimitUsd)} credit • '
          '${formatUsdAmount(projectedCreditUsdRemaining)} credit / '
          '${formatCharacterCount(projectedCoveredCharactersRemaining)} chars left after)';
    }
    return 'Selected ($charsLabel): \$0.00 '
        '(covered by 1M free tier • '
        '${formatCharacterCount(projectedFreeCharactersRemaining)} free chars + '
        '${formatUsdAmount(creditUsdRemaining)} credit left after)';
  }

  String confirmationSummary() {
    if (selectionCharacters <= 0) return '';
    final chars = formatCharacterCount(selectionCharacters);
    if (selectedEngine == 'kokoro') {
      return 'Estimated TTS cost: \$0.00 ($chars chars with Kokoro • '
          '${formatCharacterCount(coveredCharactersRemaining)} covered Google chars left this month)';
    }
    if (selectionOutOfPocketUsd > 0 || allowanceExhausted) {
      return 'Estimated TTS cost: ${formatUsdAmount(selectionOutOfPocketUsd)} out of pocket '
          '($chars chars • exceeds 1M free tier + ${formatUsdAmount(monthlyCreditLimitUsd)} credit by '
          '${formatCharacterCount(selectionUncoveredCharacters)} chars). '
          'Switch to Kokoro to generate for \$0.00.';
    }
    if (selectionCreditUsedUsd > 0) {
      return 'Estimated TTS cost: \$0.00 out of pocket '
          '($chars chars • uses ${formatUsdAmount(selectionCreditUsedUsd)} of '
          '${formatUsdAmount(monthlyCreditLimitUsd)} credit; '
          '${formatUsdAmount(projectedCreditUsdRemaining)} credit / '
          '${formatCharacterCount(projectedCoveredCharactersRemaining)} covered chars left after)';
    }
    return 'Estimated TTS cost: \$0.00 '
        '($chars chars • covered by 1M free tier; '
        '${formatCharacterCount(projectedCoveredCharactersRemaining)} covered chars / '
        '${formatUsdAmount(creditUsdRemaining)} credit left after)';
  }
}

final narrationCostTracker = NarrationCostTracker();

class NarrationCostTracker extends ChangeNotifier {
  NarrationCostTracker({
    Future<File> Function()? usageFile,
    DateTime Function()? clock,
  }) : _usageFile = usageFile ?? _defaultFile,
       clock = clock ?? DateTime.now;

  Future<File> Function() _usageFile;
  DateTime Function() clock;

  int freeCharacterLimit = defaultMonthlyFreeGoogleCharacters;
  double monthlyCreditLimitUsd = defaultMonthlyGoogleCreditUsd;
  final Map<String, NarrationMonthUsage> _months = {};
  String? _loadedPath;
  Future<void>? _loading;

  static Future<File> _defaultFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/narration_cost.json');
  }

  void configureStorage({
    Future<File> Function()? usageFile,
    DateTime Function()? clock,
  }) {
    if (usageFile != null) _usageFile = usageFile;
    if (clock != null) this.clock = clock;
  }

  String get currentMonthKey => billingMonthKey(clock());

  NarrationMonthUsage monthUsage([String? monthKey]) {
    final key = monthKey ?? currentMonthKey;
    return _months[key] ?? NarrationMonthUsage(monthKey: key);
  }

  Future<void> load() {
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final file = await _usageFile();
      if (_loadedPath == file.path) return;
      _months.clear();
      freeCharacterLimit = defaultMonthlyFreeGoogleCharacters;
      monthlyCreditLimitUsd = defaultMonthlyGoogleCreditUsd;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          final free = (raw['freeCharacterLimit'] as num?)?.toInt();
          if (free != null && free >= 0) {
            freeCharacterLimit = free;
          }
          final credit = (raw['monthlyCreditLimitUsd'] as num?)?.toDouble();
          if (credit != null && credit.isFinite && credit >= 0) {
            monthlyCreditLimitUsd = credit;
          }
          final months = raw['months'];
          if (months is Map) {
            for (final entry in months.entries) {
              if (entry.value is Map) {
                final key = entry.key.toString();
                _months[key] = NarrationMonthUsage.fromJson(
                  key,
                  Map<String, dynamic>.from(entry.value as Map),
                );
              }
            }
          }
        }
      }
      _loadedPath = file.path;
    } catch (_) {
      // Missing or unavailable storage must never block reading or narration.
    }
    notifyListeners();
  }

  Future<void> reload() async {
    _loadedPath = null;
    _loading = null;
    await load();
  }

  NarrationCostEstimate estimate({
    NarrationPreference preference = const NarrationPreference(
      'google',
      'en-US-Chirp3-HD-Achernar',
    ),
    int selectionCharacters = 0,
    String? monthKey,
  }) {
    final usage = monthUsage(monthKey);
    return NarrationCostEstimate(
      monthKey: usage.monthKey,
      freeCharacterLimit: freeCharacterLimit,
      monthlyCreditLimitUsd: monthlyCreditLimitUsd,
      usedGoogleCharacters: usage.googleCharacters,
      usedKokoroCharacters: usage.kokoroCharacters,
      selectedEngine: preference.engine,
      selectedVoice: preference.voice,
      selectionCharacters: math.max(0, selectionCharacters),
    );
  }

  Future<bool> recordSubmission({
    required String jobId,
    required String engine,
    String? voice,
    required int characters,
  }) async {
    if (jobId.isEmpty || characters <= 0) return false;
    await load();
    final key = currentMonthKey;
    final current = _months.putIfAbsent(
      key,
      () => NarrationMonthUsage(monthKey: key),
    );
    if (current.recordedJobIds.contains(jobId)) {
      return false;
    }
    final nextIds = Set<String>.from(current.recordedJobIds)..add(jobId);
    final isKokoro = engine == 'kokoro';
    _months[key] = NarrationMonthUsage(
      monthKey: key,
      googleCharacters:
          current.googleCharacters + (isKokoro ? 0 : characters),
      kokoroCharacters:
          current.kokoroCharacters + (isKokoro ? characters : 0),
      recordedJobIds: nextIds,
    );
    notifyListeners();
    await _save();
    return true;
  }

  Future<void> setMonthUsage({
    int? googleCharacters,
    int? kokoroCharacters,
    String? monthKey,
    bool clearRecordedJobs = false,
  }) async {
    await load();
    final key = monthKey ?? currentMonthKey;
    final current = monthUsage(key);
    _months[key] = NarrationMonthUsage(
      monthKey: key,
      googleCharacters: math.max(
        0,
        googleCharacters ?? current.googleCharacters,
      ),
      kokoroCharacters: math.max(
        0,
        kokoroCharacters ?? current.kokoroCharacters,
      ),
      recordedJobIds: clearRecordedJobs
          ? <String>{}
          : current.recordedJobIds,
    );
    notifyListeners();
    await _save();
  }

  Future<void> updateBudget({
    int? freeCharacterLimit,
    double? monthlyCreditLimitUsd,
  }) async {
    await load();
    if (freeCharacterLimit != null && freeCharacterLimit >= 0) {
      this.freeCharacterLimit = freeCharacterLimit;
    }
    if (monthlyCreditLimitUsd != null &&
        monthlyCreditLimitUsd.isFinite &&
        monthlyCreditLimitUsd >= 0) {
      this.monthlyCreditLimitUsd = monthlyCreditLimitUsd;
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _usageFile();
      _loadedPath = file.path;
      await updateNarrationJson(file, (data) {
        data['freeCharacterLimit'] = freeCharacterLimit;
        data['monthlyCreditLimitUsd'] = monthlyCreditLimitUsd;
        final storedMonths = Map<String, dynamic>.from(
          (data['months'] as Map?) ?? {},
        );
        for (final entry in _months.entries) {
          storedMonths[entry.key] = entry.value.toJson();
        }
        data['months'] = storedMonths;
      });
    } catch (_) {
      // Best-effort persistence when running in isolated widget tests.
    }
  }
}

Future<void> showNarrationBudgetDialog(
  BuildContext context, {
  NarrationCostTracker? tracker,
}) async {
  final costTracker = tracker ?? narrationCostTracker;
  await costTracker.load();
  if (!context.mounted) return;
  final current = costTracker.monthUsage();
  final googleController = TextEditingController(
    text: current.googleCharacters.toString(),
  );
  final freeController = TextEditingController(
    text: costTracker.freeCharacterLimit.toString(),
  );
  final creditController = TextEditingController(
    text: costTracker.monthlyCreditLimitUsd.toStringAsFixed(2),
  );
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('TTS usage & budget (${current.monthKey})'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Google Chirp 3 HD costs \$30 / 1M characters after the 1M monthly free tier. '
              'A \$10.00 monthly Google Pro credit covers an extra 333,333 characters '
              '(1,333,333 covered characters/month total).',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('budget-google-used-field'),
              controller: googleController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Google characters used this month',
                helperText: 'Sync with existing monthly usage if needed',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('budget-free-limit-field'),
              controller: freeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Monthly free Google characters',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('budget-credit-usd-field'),
              controller: creditController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Monthly Google credit (USD)',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            googleController.text = '0';
          },
          child: const Text('Zero usage'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved == true) {
    final used = int.tryParse(
      googleController.text.replaceAll(',', '').trim(),
    );
    final free = int.tryParse(
      freeController.text.replaceAll(',', '').trim(),
    );
    final credit = double.tryParse(
      creditController.text.replaceAll('\$', '').trim(),
    );
    await costTracker.updateBudget(
      freeCharacterLimit: free,
      monthlyCreditLimitUsd: credit,
    );
    if (used != null) {
      await costTracker.setMonthUsage(
        googleCharacters: used,
        clearRecordedJobs: used == 0,
      );
    }
  }
  googleController.dispose();
  freeController.dispose();
  creditController.dispose();
}

class NarrationCostBanner extends StatelessWidget {
  final NarrationCostTracker tracker;
  final NarrationPreference preference;
  final int selectionCharacters;
  final ValueChanged<NarrationPreference>? onSwitchToKokoro;
  final VoidCallback? onAdjustBudget;

  const NarrationCostBanner({
    super.key,
    required this.tracker,
    required this.preference,
    required this.selectionCharacters,
    this.onSwitchToKokoro,
    this.onAdjustBudget,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final estimate = tracker.estimate(
          preference: preference,
          selectionCharacters: selectionCharacters,
        );
        final colors = Theme.of(context).colorScheme;
        final warnSwitch = estimate.shouldSwitchToKokoro;
        final warnLow = estimate.approachingLimit;
        final containerColor = warnSwitch
            ? colors.errorContainer
            : warnLow
            ? colors.tertiaryContainer
            : colors.surfaceContainerLow;
        final textColor = warnSwitch
            ? colors.onErrorContainer
            : warnLow
            ? colors.onTertiaryContainer
            : colors.onSurface;
        final heading = warnSwitch
            ? (preference.engine == 'kokoro'
                  ? 'Google allowance used up — using Kokoro (\$0.00)'
                  : 'Google free tier + \$10 credit used up — switch to Kokoro')
            : warnLow
            ? 'Approaching Google monthly limit'
            : 'Google TTS monthly allowance (${estimate.monthKey})';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: containerColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: warnSwitch ? colors.error : colors.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        warnSwitch
                            ? Icons.warning_amber_rounded
                            : Icons.payments_outlined,
                        size: 18,
                        color: textColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          heading,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: textColor,
                          ),
                        ),
                      ),
                      if (onAdjustBudget != null)
                        TextButton(
                          onPressed: onAdjustBudget,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(48, 28),
                          ),
                          child: const Text('Usage / budget'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: estimate.projectedAllowanceUsedFraction,
                    minHeight: 5,
                    borderRadius: BorderRadius.circular(3),
                    color: warnSwitch ? colors.error : colors.primary,
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    estimate.monthlyAllowanceSummary(),
                    style: TextStyle(fontSize: 12, color: textColor),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    estimate.selectionImpactSummary(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: warnSwitch ? FontWeight.w600 : FontWeight.normal,
                      color: textColor,
                    ),
                  ),
                  if (preference.engine == 'google' &&
                      (warnSwitch || warnLow) &&
                      onSwitchToKokoro != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('switch-to-kokoro-button'),
                        onPressed: () {
                          final voices = narrationVoices['kokoro']!;
                          onSwitchToKokoro!(
                            NarrationPreference('kokoro', voices.keys.first),
                          );
                        },
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: const Text('Switch to Kokoro (\$0.00)'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
