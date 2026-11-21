import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
  static final Map<String, int> _recentAlertTimestamps = <String, int>{};

  static int _generateNotificationId(String? payload, int? explicitId) {
    if (explicitId != null) return explicitId;
    if (payload != null && payload.trim().isNotEmpty) {
      return payload.trim().hashCode.abs() % 2147483647;
    }
    return ++_notificationCounter;
  }

  static bool shouldDeduplicate(String? payload) {
    if (payload == null || payload.trim().isEmpty) return false;
    final cleanId = payload.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentAlertTimestamps.removeWhere((_, time) => now - time > 60000);

    if (_recentAlertTimestamps.containsKey(cleanId)) {
      final lastTime = _recentAlertTimestamps[cleanId]!;
      if (now - lastTime < 4000) {
        return true;
      }
    }
    _recentAlertTimestamps[cleanId] = now;
    return false;
  }

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
          AndroidInitializationSettings('ic_notification');

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

      // Initialize Firebase & FCM listeners safely
      try {
        await Firebase.initializeApp();
        await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          debugPrint('FCM Foreground onMessage: ${message.data}');
          final title = message.notification?.title ?? message.data['title'] ?? 'New Print Job';
          final body = message.notification?.body ?? message.data['body'] ?? 'New order received';
          final payload = message.data['order_id'] ?? message.data['payload'];
          alertNewJob(
            title: title,
            body: body,
            payload: payload,
          );
        });
      } catch (fcmErr) {
        debugPrint('FCM initialization note: $fcmErr');
      }
    } catch (e) {
      debugPrint('NotificationService initialize error: $e');
    }
  }

  /// Subscribes to vendor-specific FCM topic so background pushes wake up the device
  static Future<void> subscribeToVendorTopic(String vendorId) async {
    try {
      final clean = vendorId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      if (clean.isNotEmpty) {
        await FirebaseMessaging.instance.subscribeToTopic('vendor-$clean');
        await FirebaseMessaging.instance.subscribeToTopic('all_vendors');
        debugPrint('Subscribed to FCM topic: vendor-$clean');
        try {
          final token = await FirebaseMessaging.instance.getToken();
          debugPrint('FCM_DEVICE_TOKEN: $token');
        } catch (e) {
          debugPrint('Error getting FCM token: $e');
        }
      }
    } catch (e) {
      debugPrint('FCM subscribe topic note: $e');
    }
  }

  /// Explicitly requests notification permissions from the host platform (Android 13+ / iOS).
  /// Calls [initialize] first if not already initialized.
  static Future<bool?> requestPermission() async {
    if (!_initialized) {
      await initialize();
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final androidImplementation = _notificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        if (androidImplementation != null) {
          final granted =
              await androidImplementation.requestNotificationsPermission();
          debugPrint('Android Notification Permission Granted: $granted');
          return granted;
        }
      } catch (platformErr) {
        debugPrint('Error requesting Android notification permission: $platformErr');
      }
    } else if (!kIsWeb && Platform.isIOS) {
      try {
        final iosImplementation = _notificationsPlugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
        if (iosImplementation != null) {
          final granted = await iosImplementation.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
          debugPrint('iOS Notification Permission Granted: $granted');
          return granted;
        }
      } catch (platformErr) {
        debugPrint('Error requesting iOS notification permission: $platformErr');
      }
    }
    return null;
  }

  /// Displays a heads-up system notification banner and triggers vibration / native sound.
  static Future<void> showJobNotification({
    required String title,
    required String body,
    String? payload,
    int? notificationId,
  }) async {
    try {
      if (!_initialized) {
        await initialize();
      }

      final id = _generateNotificationId(payload, notificationId);
      final tag = (payload != null && payload.trim().isNotEmpty)
          ? 'order_${payload.trim()}'
          : null;

      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('new_job'),
        enableVibration: true,
        icon: 'ic_notification',
        largeIcon: const DrawableResourceAndroidBitmap('app_icon'),
        category: AndroidNotificationCategory.event,
        visibility: NotificationVisibility.public,
        channelShowBadge: true,
        tag: tag,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'new_job.mp3',
      );

      final NotificationDetails platformDetails = NotificationDetails(
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

      // Route audio via notification/sonification stream so sound is audible even when media volume is muted
      try {
        await _foregroundPlayer!.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: true,
              stayAwake: true,
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.notification,
              audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.ambient,
              options: const {
                AVAudioSessionOptions.mixWithOthers,
                AVAudioSessionOptions.duckOthers,
              },
            ),
          ),
        );
      } catch (_) {}

      // Seek to beginning if already playing to avoid stopping sound during rapid event bursts
      if (_foregroundPlayer!.state == PlayerState.playing) {
        await _foregroundPlayer!.seek(Duration.zero);
      } else {
        await _foregroundPlayer!.stop();
      }

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
  /// Automatically deduplicates event bursts for the same order across WebSocket and FCM.
  static Future<void> alertNewJob({
    required String title,
    required String body,
    String? payload,
    int? notificationId,
  }) async {
    if (shouldDeduplicate(payload)) {
      debugPrint('NotificationService: deduplicated burst alert for order: $payload');
      return;
    }

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
