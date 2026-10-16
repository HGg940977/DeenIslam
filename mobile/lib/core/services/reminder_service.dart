import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../data/models/app_location.dart';
import '../../data/models/prayer_times_model.dart';
import 'storage_service.dart';

enum ReminderStatus {
  scheduled,
  nothingEnabled,
  notificationsDenied,
  failed,
}

class ReminderResult {
  final ReminderStatus status;

  /// Number of notifications actually queued with the OS.
  final int count;

  /// False when Android 12+ exact-alarm permission is missing; reminders are
  /// then delivered inexactly (they can be a few minutes late).
  final bool exact;

  const ReminderResult(this.status, {this.count = 0, this.exact = true});

  bool get ok => status == ReminderStatus.scheduled;
}

/// Local prayer reminders built on the calculated schedule.
///
/// Architecture: one mechanism only - `flutter_local_notifications` scheduled
/// notifications (AlarmManager under the hood, restored after reboot by the
/// plugin's boot receiver). The next [horizonDays] days are scheduled with
/// stable ids and the whole set is replaced on every change, so duplicates
/// cannot accumulate. The app reschedules on start/resume, which also covers
/// date and time-zone changes.
///
/// Sound: the reminders use the system's default notification sound. No Adhan
/// audio file is bundled, so full Adhan playback is NOT implemented here.
class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const int horizonDays = 7;
  static const String _channelId = 'prayer_reminders';

  /// Alarm keys match the waqt names used by the prayer screen.
  static const List<String> waqtKeys = [
    'ফজর',
    'যোহর',
    'আসর',
    'মাগরিব (ইফতার)',
    'ইশা',
  ];
  static const List<String> _shortNames = ['ফজর', 'যোহর', 'আসর', 'মাগরিব', 'ইশা'];

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  Future<void>? _initFuture;

  Future<void> init() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings);
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        'নামাজের ওয়াক্তের রিমাইন্ডার',
        description: 'ওয়াক্ত শুরুর সময় এবং আগে থেকে সতর্কতা',
        importance: Importance.high,
      ),
    );
    _initialized = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Asks for the notification permission (Android 13+). Returns whether
  /// notifications can be shown.
  Future<bool> requestNotificationPermission() async {
    await init();
    final android = _android;
    if (android == null) return false;
    final enabled = await android.areNotificationsEnabled() ?? false;
    if (enabled) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  Future<bool> notificationsAllowed() async {
    await init();
    return await _android?.areNotificationsEnabled() ?? false;
  }

  /// Whether exact alarms may be used (Android 12+ special access).
  Future<bool> canScheduleExact() async {
    await init();
    return await _android?.canScheduleExactNotifications() ?? false;
  }

  /// Opens the system screen where the user can allow exact alarms.
  Future<void> requestExactAlarmPermission() async {
    await init();
    await _android?.requestExactAlarmsPermission();
  }

  /// Replaces every scheduled reminder using the current location and the
  /// user's per-prayer preferences. Never throws.
  Future<ReminderResult> reschedule(AppLocation location) async {
    try {
      await init();
      await _plugin.cancelAll();

      final alarms = await StorageService.getAzanAlarms();
      final preMinutes = await StorageService.getAzanPreReminderMinutes();
      final enabled = <int>[
        for (var i = 0; i < waqtKeys.length; i++)
          if (alarms[waqtKeys[i]] ?? true) i,
      ];
      if (enabled.isEmpty) {
        return const ReminderResult(ReminderStatus.nothingEnabled);
      }
      if (!await notificationsAllowed()) {
        return const ReminderResult(ReminderStatus.notificationsDenied);
      }

      final exact = await canScheduleExact();
      final mode = exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;

      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'নামাজের ওয়াক্তের রিমাইন্ডার',
          channelDescription: 'ওয়াক্ত শুরুর সময় এবং আগে থেকে সতর্কতা',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
      );

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      var count = 0;

      for (var d = 0; d < horizonDays; d++) {
        final day = today.add(Duration(days: d));
        final model = PrayerTimesModel.forLocation(day, location);
        final times = [model.fajr, model.dhuhr, model.asr, model.maghrib, model.isha];

        for (final p in enabled) {
          final at = model.toDateTime(times[p]);

          if (at.isAfter(now)) {
            await _schedule(
              id: notificationId(d, p, false),
              title: '${_shortNames[p]}-এর ওয়াক্ত হয়েছে',
              body: '${model.formatTime(times[p])} • ${location.label}',
              at: at,
              details: details,
              mode: mode,
            );
            count++;
          }

          final pre = at.subtract(Duration(minutes: preMinutes));
          if (preMinutes > 0 && pre.isAfter(now)) {
            await _schedule(
              id: notificationId(d, p, true),
              title: '${_shortNames[p]}-এর ওয়াক্ত ঘনিয়ে আসছে',
              body: 'আর $preMinutes মিনিট পর • ${model.formatTime(times[p])}',
              at: pre,
              details: details,
              mode: mode,
            );
            count++;
          }
        }
      }

      return ReminderResult(ReminderStatus.scheduled, count: count, exact: exact);
    } catch (e) {
      debugPrint('ReminderService.reschedule failed: $e');
      return const ReminderResult(ReminderStatus.failed);
    }
  }

  /// Stable id: day offset, prayer index and kind (main / pre-reminder).
  @visibleForTesting
  static int notificationId(int dayOffset, int prayerIndex, bool isPre) =>
      1000 + dayOffset * 100 + prayerIndex * 10 + (isPre ? 1 : 0);

  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    required NotificationDetails details,
    required AndroidScheduleMode mode,
  }) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(at, tz.UTC),
      details,
      androidScheduleMode: mode,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
