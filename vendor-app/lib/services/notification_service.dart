import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'sound_service.dart';

/// NotificationService coordinates high-priority Android notification banners
/// and foreground audio chimes for incoming print jobs and payment claims.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static AudioPlayer? _foregroundPlayer;
  static bool _initialized = false;
  static int _notificationCounter = 1000;

  static const String channelId = 'printpulse_urgent_jobs_v2';
  static const String channelName = 'PrintPulse Urgent Jobs & Payments';
  static const String channelDescription =
      'Immediate alerts for incoming customer print jobs and payment claims.';

  static const AndroidNotificationChannel urgentJobsChannel =
      AndroidNotificationChannel(
    channelId,
    channelName,
    description: channelDescription,
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('new_job'),
    enableVibration: true,
  );

  /// Initializes the local notifications plugin, registers the Android 13+ channel,
  /// and requests POST_NOTIFICATIONS runtime permissions.
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notificationsPlugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint(
              'Notification clicked with payload: ${response.payload}');
        },
      );

      // Create high-importance Android notification channel and request Android 13+ permission
      if (!kIsWeb && Platform.isAndroid) {
        try {
          final androidImplementation = _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>();

          if (androidImplementation != null) {
            await androidImplementation
                .createNotificationChannel(urgentJobsChannel);

            final granted =
                await androidImplementation.requestNotificationsPermission();
            debugPrint('Android Notification Permission Granted: $granted');
          }
        } catch (platformErr) {
          debugPrint('Android notification platform setup note: $platformErr');
        }
      }

      _initialized = true;
      debugPrint('NotificationService initialized with channel $channelId');
    } catch (e) {
      debugPrint('NotificationService initialize error: $e');
    }
  }

  /// Displays a heads-up system notification banner and triggers vibration / native sound.
  static Future<void> showJobNotification({
    required String title,
    required String body,
    String? payload,
    int? notificationId,
  }) async {
    try {
      final id = notificationId ?? ++_notificationCounter;

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('new_job'),
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
        category: AndroidNotificationCategory.call,
        visibility: NotificationVisibility.public,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'new_job.mp3',
      );

      const NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notificationsPlugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Error showing local notification: $e');
    }
  }

  /// Triggers an explicit foreground audio chime so sound plays reliably
  /// even while the vendor app is open in the foreground.
  static Future<void> playForegroundChime() async {
    try {
      // Immediate tactile & system alert feedback
      try {
        HapticFeedback.heavyImpact().catchError((_) {});
        SystemSound.play(SystemSoundType.alert).catchError((_) {});
      } catch (_) {}

      // Play via AudioPlayer with asset source fallback to synthesized SoundService WAV
      _foregroundPlayer ??= AudioPlayer();
      await _foregroundPlayer!.stop();

      try {
        await _foregroundPlayer!.play(AssetSource('sounds/new_job.mp3'));
      } catch (assetErr) {
        debugPrint('NotificationService asset audio fallback: $assetErr');
        await SoundService.playOrderChime();
      }
    } catch (e) {
      debugPrint('NotificationService playForegroundChime error: $e');
      try {
        await SoundService.playOrderChime();
      } catch (_) {}
    }
  }

  /// Combined helper: fires both heads-up banner and immediate foreground chime.
  static Future<void> alertNewJob({
    required String title,
    required String body,
    String? payload,
    int? notificationId,
  }) async {
    await Future.wait([
      showJobNotification(
        title: title,
        body: body,
        payload: payload,
        notificationId: notificationId,
      ),
      playForegroundChime(),
    ]);
  }

  static void dispose() {
    try {
      _foregroundPlayer?.dispose();
      _foregroundPlayer = null;
    } catch (_) {}
  }
}
