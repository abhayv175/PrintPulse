import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vendor_app/config/api_config.dart';
import 'package:vendor_app/main.dart';
import 'package:vendor_app/models/print_job.dart';
import 'package:vendor_app/screens/auth_screen.dart';
import 'package:vendor_app/screens/dashboard_screen.dart';
import 'package:vendor_app/screens/home_screen.dart';
import 'package:vendor_app/screens/profile_screen.dart';
import 'package:vendor_app/screens/queue_screen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vendor_app/services/google_auth_service.dart';
import 'package:vendor_app/services/notification_service.dart';
import 'package:vendor_app/services/sound_service.dart';
import 'package:vendor_app/theme/app_theme.dart';
import 'package:vendor_app/theme/theme_controller.dart';
import 'package:vendor_app/widgets/animated_background.dart';
import 'package:vendor_app/widgets/onboarding_dialog.dart';

void main() {
  setUp(() {
    SoundService.enabled = false;
    try {
      final tempDir = Directory.systemTemp;
      final ordersDir = Directory('${tempDir.path}/PrintPulse_Orders');
      if (ordersDir.existsSync()) {
        ordersDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  testWidgets('PrintPulse Vendor App clean AuthScreen & static background test',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PrintPulseVendorApp());

    // Ensures all staggered entrance animations settle with no infinite background Ticker.
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text('PrintPulse'), findsOneWidget);
    expect(find.text('Kiosk & Live Order Terminal'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Host: ${ApiConfig.baseHost}'), findsOneWidget);
    expect(find.text('Vendor Sign-In'), findsNothing);
  });

  testWidgets('Animated Light to Dark mode transition interpolates smoothly',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await globalThemeController.setThemeMode(ThemeMode.light);

    await tester.pumpWidget(const PrintPulseVendorApp());
    await tester.pumpAndSettle();

    final bgPositioned = find.descendant(
      of: find.byType(AnimatedBackground),
      matching: find.byType(Positioned),
    );

    Color currentStartColor() {
      final decoratedBox = tester.widget<DecoratedBox>(
        find.descendant(
          of: bgPositioned,
          matching: find.byType(DecoratedBox),
        ),
      );
      final gradient =
          (decoratedBox.decoration as BoxDecoration).gradient! as LinearGradient;
      return gradient.colors.first;
    }

    expect(currentStartColor(), AppColors.lightBg1);

    // Trigger switch to dark mode without awaiting SharedPreferences disk flush.
    globalThemeController.setThemeMode(ThemeMode.dark);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    // Mid-transition color built via PrintPulsePalette.lerp is strictly between light and dark.
    final midStartColor = currentStartColor();
    expect(midStartColor, isNot(equals(AppColors.lightBg1)));
    expect(midStartColor, isNot(equals(AppColors.darkBg1)));

    // Settle completely into Dark Mode with no lingering tickers.
    await tester.pumpAndSettle();
    expect(currentStartColor(), AppColors.darkBg1);

    await globalThemeController.setThemeMode(ThemeMode.system);
  });

  testWidgets(
      'PageView swipe and Apple Music bottom dock pill track 1:1 bi-directionally',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.light,
        home: const DashboardScreen(
          vendorId: 'test_kiosk_01',
          shopUrl: 'https://printpulse.test/shop/test_kiosk_01',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dismiss auto-opened Counter QR modal sheet if present.
    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    final pillAlignFinder = find.descendant(
      of: find.byType(ValueListenableBuilder<double>),
      matching: find.byWidgetPredicate(
        (w) => w is Align && w.child is FractionallySizedBox,
      ),
    );

    Alignment pillAlignment() =>
        tester.widget<Align>(pillAlignFinder).alignment as Alignment;
    double currentPage() =>
        tester.widget<PageView>(find.byType(PageView)).controller!.page!;

    expect(pillAlignment().x, closeTo(-1.0, 0.01));
    expect(currentPage(), closeTo(0.0, 0.01));

    // 1) Swipe PageView horizontally and verify pill follows in real time mid-drag.
    final pageCenter = tester.getCenter(find.byType(PageView));
    final pageWidth = tester.getSize(find.byType(PageView)).width;
    final swipeGesture = await tester.startGesture(pageCenter);
    await swipeGesture.moveBy(Offset(-pageWidth * 0.5, 0));
    await tester.pump();

    expect(currentPage(), inExclusiveRange(0.2, 0.8));
    expect(pillAlignment().x, closeTo((currentPage() / 3.0) * 2.0 - 1.0, 0.01));

    // Complete swipe left to settle on Queue tab (index 1).
    await swipeGesture.moveBy(Offset(-pageWidth * 0.25, 0));
    await swipeGesture.up();
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(1.0, 0.01));
    expect(pillAlignment().x, closeTo(-1.0 / 3.0, 0.01));
    expect(find.text('Live Queue'), findsOneWidget);

    // 2) Drag directly on the bottom dock bar and verify PageView follows in 1:1 lockstep.
    final dockFinder = find.byType(BackdropFilter);
    final dockCenter = tester.getCenter(dockFinder);
    final dockTrackWidth = tester.getSize(dockFinder).width - 8; // 4px padding each side
    final dockGesture = await tester.startGesture(dockCenter);
    // Drag right by half a tab width (dockTrackWidth / 8.0) -> +0.5 page -> page ~ 1.5
    await dockGesture.moveBy(Offset(dockTrackWidth / 8.0, 0));
    await tester.pump();

    expect(currentPage(), closeTo(1.5, 0.06));
    expect(pillAlignment().x, closeTo(0.0, 0.06));

    // Finish drag past threshold to settle on History tab (index 2).
    await dockGesture.moveBy(Offset(dockTrackWidth / 8.0, 0));
    await dockGesture.up();
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(2.0, 0.01));
    expect(pillAlignment().x, closeTo(1.0 / 3.0, 0.01));
    expect(find.text('Order History'), findsOneWidget);

    // 3) Tap 'Profile' tab to glide to index 3.
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(3.0, 0.01));
    expect(pillAlignment().x, closeTo(1.0, 0.01));
    expect(find.text('Kiosk Profile & Settings'), findsOneWidget);

    // 4) Tap 'Home' tab to glide smoothly back to index 0.
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(0.0, 0.01));
    expect(pillAlignment().x, closeTo(-1.0, 0.01));

    // Unmount DashboardScreen so any pending WebSocket reconnect timer is canceled.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Disconnect Kiosk dialog uses opaque light/dark surface, dark scrim, and balanced iOS buttons',
      (WidgetTester tester) async {
    Future<void> verifyForTheme(ThemeMode mode, Color expectedBg) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          home: const DashboardScreen(
            vendorId: 'test_kiosk_01',
            shopUrl: 'https://printpulse.test/shop/test_kiosk_01',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Dismiss auto-opened Counter QR modal sheet if present.
      if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pumpAndSettle();
      }

      // Navigate to Profile tab and open Disconnect Kiosk dialog.
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      final disconnectBtn = find.text('Disconnect Kiosk');
      await tester.ensureVisible(disconnectBtn);
      await tester.pumpAndSettle();
      await tester.tap(disconnectBtn);
      await tester.pumpAndSettle();

      expect(find.text('Disconnect Kiosk?'), findsOneWidget);
      expect(
        find.text(
          'Are you sure you want to sign out? Live queue monitoring and walk-in print reception will pause.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);

      // Verify opaque container surface inside Dialog.
      final dialogContainer = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).borderRadius ==
                        BorderRadius.circular(24),
              ),
            )
            .first,
      );
      final decoration = dialogContainer.decoration! as BoxDecoration;
      expect(decoration.color, expectedBg);
      expect(decoration.color!.a, closeTo(1.0, 0.001));

      // Cancel closes dialog while keeping DashboardScreen mounted.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect Kiosk?'), findsNothing);
      expect(find.byType(DashboardScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await verifyForTheme(ThemeMode.light, Colors.white);
    await verifyForTheme(ThemeMode.dark, const Color(0xFF1E1735));
  });

  testWidgets(
      'Dashboard displays email-derived vendor ID on Home, QR sheet, Profile, and Portal URL',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    const derivedVendorId = 'abhayv175';
    final expectedUrl = ApiConfig.customerShopUrl(derivedVendorId);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: DashboardScreen(
          vendorId: derivedVendorId,
          shopUrl: expectedUrl,
          showQrOnLoad: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Auto-opened Counter QR modal displays the email-derived terminal ID.
    final qrSheetFinder = find.byType(BottomSheet);
    expect(qrSheetFinder, findsOneWidget);
    expect(
      find.descendant(
        of: qrSheetFinder,
        matching: find.text('Counter QR Code'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: qrSheetFinder,
        matching: find.text(derivedVendorId),
      ),
      findsOneWidget,
    );

    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    // Home tab badge displays Terminal ID with the derived email prefix.
    expect(find.text('Terminal ID: $derivedVendorId'), findsOneWidget);

    // Profile tab displays the derived vendor ID and customer shop URL.
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text(derivedVendorId), findsOneWidget);
    expect(find.text(expectedUrl), findsOneWidget);
    expect(find.text('https://jh0yc.aiccloud.online'), findsOneWidget);
    expect(find.text('wss://jh0yc.aiccloud.online'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'UPI order_paid WebSocket event updates Session Total, Printed Today, and unlocks PAID badge',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final wsController = StreamController<dynamic>.broadcast();
    addTearDown(wsController.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: DashboardScreen(
          vendorId: 'abhayv175',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/abhayv175',
          testWebSocketStream: wsController.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dismiss auto-opened Counter QR sheet if present.
    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    expect(find.text('₹0.00'), findsOneWidget);
    expect(find.text('0 jobs'), findsOneWidget);

    // 1. Incoming draft upload (awaiting_payment / pending_payment) -> Gated!
    // Draft must NOT chime, Session Total stays 0.00, and does NOT appear in Queue.
    wsController.add({
      'event': 'NEW_PRINT_JOB',
      'order_id': 'ord_89324',
      'vendor_id': 'abhayv175',
      'status': 'awaiting_payment',
      'total_amount': 14.0,
      'total_pages': 7,
      'documents': [
        {
          'doc_id': 'doc_1',
          'original_filename': 'notes.pdf',
          'staged_file': 'ord_89324_doc_1.pdf',
          'staged_path': '/uploads/abhayv175/ord_89324_doc_1.pdf',
          'pages': 7,
          'copies': 1,
          'is_color': false,
          'rate_per_page': 2.0,
          'total_amount': 14.0,
          'size_kb': 42.0,
        },
      ],
    });
    await tester.pumpAndSettle();

    expect(find.text('₹0.00'), findsOneWidget);
    expect(find.text('0 jobs'), findsOneWidget);

    // Switch to Queue tab to verify draft is NOT present.
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('ord_89324'), findsNothing);
    expect(find.text('Queue is Empty'), findsOneWidget);

    // 2. Payment confirmed -> Queue card appears with PAID badge & single primary PRINT button; Home counters increment.
    wsController.add({
      'event': 'order_paid',
      'order': {
        'order_id': 'ord_89324',
        'amount': 14.0,
        'pages': 7,
        'copies': 1,
        'color_mode': 'bw',
        'status': 'paid',
        'paid_at': '2026-11-11T14:45:00',
        'documents': [
          {
            'doc_id': 'doc_1',
            'original_filename': 'notes.pdf',
            'staged_file': 'ord_89324_doc_1.pdf',
            'staged_path': '/uploads/abhayv175/ord_89324_doc_1.pdf',
            'pages': 7,
            'copies': 1,
            'is_color': false,
            'rate_per_page': 2.0,
            'total_amount': 14.0,
            'size_kb': 42.0,
          },
        ],
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('ord_89324'), findsOneWidget);
    expect(find.text('PAID • ₹14.00'), findsOneWidget);
    expect(find.text('PRINT'), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(find.text('₹14.00'), findsOneWidget);
    expect(find.text('1 jobs'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Startup migrates stale 192.168.1.39 or empty SharedPreferences cache to jh0yc.aiccloud.online',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'vendor_id': 'abhayv175',
      'shop_url': 'http://192.168.1.39:8000/shop/abhayv175',
      'api_host': '192.168.1.39:8000',
      'host_url': '',
    });

    final prefs = await SharedPreferences.getInstance();
    final migratedShopUrl = await loadNormalizedShopUrl(prefs);

    expect(migratedShopUrl, 'https://jh0yc.aiccloud.online/shop/abhayv175');
    expect(prefs.getString('shop_url'), 'https://jh0yc.aiccloud.online/shop/abhayv175');
    expect(prefs.getString('api_host'), 'https://jh0yc.aiccloud.online');
    expect(prefs.getString('host_url'), 'https://jh0yc.aiccloud.online');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: DashboardScreen(
          vendorId: 'abhayv175',
          shopUrl: migratedShopUrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('https://jh0yc.aiccloud.online'), findsOneWidget);
    expect(find.text('wss://jh0yc.aiccloud.online'), findsOneWidget);
    expect(find.text('https://jh0yc.aiccloud.online/shop/abhayv175'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Tapping PRINT normalizes localhost download URL, converts images to A4 PDF, and catches errors',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final wsController = StreamController<dynamic>.broadcast();
    addTearDown(wsController.close);

    Uri? fetchedUri;
    PdfPageFormat? capturedFormat;
    bool? capturedDynamicLayout;
    Uint8List? capturedPdfBytes;

    // Minimal valid A4 PDF bytes
    final kMinimalPdf = Uint8List.fromList(
      '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n3 0 obj<</Type/Page/MediaBox[0 0 595 842]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n150\n%%EOF'
          .codeUnits,
    );

    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/api/orders/vendor')) {
        return http.Response('{"orders": []}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/status')) {
        return http.Response('{"success": true}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/pricing')) {
        return http.Response('{"vendor_id": "abhayv175", "bw_price": 2.0, "color_price": 10.0}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/stats')) {
        return http.Response('{"vendor_id": "abhayv175", "session_revenue": 0.0, "bw_pages_printed": 0, "color_pages_printed": 0, "completed_orders": 0}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/history')) {
        return http.Response('{"vendor_id": "abhayv175", "orders": []}', 200, headers: {'content-type': 'application/json'});
      }
      fetchedUri = request.url;
      if (request.url.path.contains('ord_404')) {
        return http.Response('Not Found', 404);
      }
      return http.Response.bytes(
        kMinimalPdf,
        200,
        headers: {'content-type': 'application/pdf'},
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: DashboardScreen(
          vendorId: 'abhayv175',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/abhayv175',
          testWebSocketStream: wsController.stream,
          testHttpClient: mockClient,
          testPrintExecutor: ({
            required Uint8List pdfBytes,
            required String name,
            required PdfPageFormat format,
            required bool dynamicLayout,
          }) async {
            capturedPdfBytes = pdfBytes;
            capturedFormat = format;
            capturedDynamicLayout = dynamicLayout;
            await Future.delayed(const Duration(milliseconds: 150));
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    // 1. Image order with localhost URL -> normalizes to jh0yc.aiccloud.online and converts image to A4 PDF
    wsController.add({
      'event': 'NEW_PRINT_JOB',
      'order_id': 'ord_img_77',
      'vendor_id': 'abhayv175',
      'status': 'paid',
      'total_amount': 2.0,
      'total_pages': 1,
      'copies': 1,
      'color_mode': 'bw',
      'download_url': 'http://localhost:8000/api/documents/ord_img_77/download',
      'documents': [
        {
          'doc_id': 'doc_img_1',
          'original_filename': 'receipt.png',
          'staged_file': 'ord_img_77_receipt.png',
          'staged_path': '/uploads/abhayv175/ord_img_77_receipt.png',
          'download_url': 'http://localhost:8000/api/documents/ord_img_77/download?doc_id=doc_img_1',
          'pages': 1,
          'copies': 1,
          'is_color': false,
          'rate_per_page': 2.0,
          'total_amount': 2.0,
          'size_kb': 1.0,
        },
      ],
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    // Clear any prior snackbars (e.g. Payment Received notification) so the diagnostic loading bar displays cleanly
    ScaffoldMessenger.of(tester.element(find.byType(DashboardScreen))).clearSnackBars();
    await tester.pumpAndSettle();

    expect(find.text('PRINT'), findsOneWidget);
    await tester.tap(find.text('PRINT'));

    // Verify immediate diagnostic feedback
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Preparing document for Android Print Spooler'), findsOneWidget);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Host must be normalized away from localhost to jh0yc.aiccloud.online:8000
    expect(fetchedUri?.host, 'jh0yc.aiccloud.online');
    expect(fetchedUri?.port, 443);
    expect(fetchedUri?.path, '/api/documents/ord_img_77/download');
    expect(capturedFormat, PdfPageFormat.a4);
    expect(capturedDynamicLayout, isFalse);

    // Image must be wrapped in valid PDF (%PDF header)
    expect(capturedPdfBytes, isNotNull);
    final header = String.fromCharCodes(capturedPdfBytes!.take(4));
    expect(header, '%PDF');

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('dashboard_queue_tab')),
        matching: find.text('ord_img_77'),
      ),
      findsNothing,
    );
    expect(find.textContaining('Sent to printer'), findsOneWidget);

    // 2. Landscape orientation order -> passes PdfPageFormat.a4.landscape to print spooler
    wsController.add({
      'event': 'NEW_PRINT_JOB',
      'order_id': 'ord_landscape_99',
      'vendor_id': 'abhayv175',
      'status': 'paid',
      'total_amount': 2.0,
      'total_pages': 1,
      'copies': 1,
      'color_mode': 'bw',
      'orientation': 'landscape',
      'download_url': 'http://localhost:8000/api/documents/ord_landscape_99/download',
      'documents': [
        {
          'doc_id': 'doc_land_1',
          'original_filename': 'screenshot_wide.png',
          'staged_file': 'ord_landscape_99_wide.png',
          'staged_path': '/uploads/abhayv175/ord_landscape_99_wide.png',
          'download_url': 'http://localhost:8000/api/documents/ord_landscape_99/download?doc_id=doc_land_1',
          'pages': 1,
          'copies': 1,
          'is_color': false,
          'orientation': 'landscape',
          'rate_per_page': 2.0,
          'total_amount': 2.0,
          'size_kb': 1.0,
        },
      ],
    });
    await tester.pumpAndSettle();

    expect(find.text('Landscape'), findsWidgets);
    ScaffoldMessenger.of(tester.element(find.byType(DashboardScreen))).clearSnackBars();
    await tester.pumpAndSettle();

    expect(find.text('PRINT'), findsOneWidget);
    await tester.tap(find.text('PRINT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(capturedFormat, PdfPageFormat.a4.landscape);

    await tester.pumpAndSettle();

    // 3. HTTP 404 error order -> surfaces clear red SnackBar with error message
    wsController.add({
      'event': 'NEW_PRINT_JOB',
      'order_id': 'ord_404',
      'vendor_id': 'abhayv175',
      'status': 'paid',
      'total_amount': 2.0,
      'total_pages': 1,
      'copies': 1,
      'color_mode': 'bw',
      'download_url': 'http://127.0.0.1:8000/api/documents/ord_404/download',
      'documents': [],
    });
    await tester.pumpAndSettle();

    ScaffoldMessenger.of(tester.element(find.byType(DashboardScreen))).clearSnackBars();
    await tester.pumpAndSettle();

    expect(find.text('PRINT'), findsOneWidget);
    await tester.tap(find.text('PRINT'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Print Error: Exception: HTTP 404'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('SoundService synthesizes valid 16-bit PCM RIFF/WAVE audio chime in memory', () {
    final wavBytes = SoundService.generateChimeWav();
    expect(wavBytes.length, greaterThan(44));

    // 'RIFF' header
    final riffTag = String.fromCharCodes(wavBytes.sublist(0, 4));
    expect(riffTag, 'RIFF');

    // 'WAVE' format
    final waveTag = String.fromCharCodes(wavBytes.sublist(8, 12));
    expect(waveTag, 'WAVE');

    // 'fmt ' chunk
    final fmtTag = String.fromCharCodes(wavBytes.sublist(12, 16));
    expect(fmtTag, 'fmt ');

    // 'data' chunk
    final dataTag = String.fromCharCodes(wavBytes.sublist(36, 40));
    expect(dataTag, 'data');
  });

  testWidgets(
      'handlePrintOrder dispatches printing and completed lifecycle statuses to backend',
      (WidgetTester tester) async {
    final dispatchedStatuses = <String>[];
    final testOrder = PrintJob.fromJson({
      'order_id': 'ord_status_test',
      'vendor_id': 'test_kiosk',
      'status': 'paid',
      'total_amount': 14.0,
      'total_pages': 7,
      'copies': 1,
      'color_mode': 'bw',
      'download_url': 'https://jh0yc.aiccloud.online/api/documents/ord_status_test/download',
      'documents': [],
    });

    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/status') && request.method == 'POST') {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        dispatchedStatuses.add(decoded['status'].toString());
        return http.Response('{"success": true}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(
        Uint8List.fromList('%PDF-1.4\n%%EOF'.codeUnits),
        200,
        headers: {'content-type': 'application/pdf'},
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await handlePrintOrder(
                    context,
                    testOrder,
                    httpClient: mockClient,
                    printExecutor: ({
                      required Uint8List pdfBytes,
                      required String name,
                      required PdfPageFormat format,
                      required bool dynamicLayout,
                    }) async {
                      return true;
                    },
                  );
                },
                child: const Text('Execute Print'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Execute Print'));
    await tester.pumpAndSettle();

    expect(dispatchedStatuses, contains('printing'));
    expect(dispatchedStatuses, contains('completed'));
    expect(dispatchedStatuses.indexOf('printing'),
        lessThan(dispatchedStatuses.indexOf('completed')));
  });

  testWidgets(
      'PrintPricingCard displays rates, allows updating, and shows confirmation SnackBar',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'bw_price': 2.5, 'color_price': 12.0});

    String? updatedRequestBody;
    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/pricing')) {
        if (request.method == 'POST') {
          updatedRequestBody = request.body;
          return http.Response(
            '{"vendor_id": "test_kiosk", "bw_price": 3.0, "color_price": 14.0}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"vendor_id": "test_kiosk", "bw_price": 2.5, "color_price": 12.0}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('Not Found', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: PrintPricingCard(
            vendorId: 'test_kiosk',
            httpClient: mockClient,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Print Pricing (INR)'), findsOneWidget);
    expect(find.text('2.50'), findsOneWidget);
    expect(find.text('12.00'), findsOneWidget);

    // Update B&W price to 3.00
    final textFields = find.byType(TextField);
    await tester.enterText(textFields.first, '3.00');
    await tester.enterText(textFields.last, '14.00');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save Rates'));
    await tester.pumpAndSettle();

    expect(updatedRequestBody, isNotNull);
    final decoded = jsonDecode(updatedRequestBody!) as Map<String, dynamic>;
    expect(decoded['bw_price'], 3.0);
    expect(decoded['color_price'], 14.0);

    expect(find.textContaining('Print rates updated'), findsOneWidget);
  });

  testWidgets('PageBreakdownRow displays B&W and Color metric pills accurately',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PageBreakdownRow(
            bwPages: 42,
            colorPages: 18,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('B&W Pages'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Color Pages'), findsOneWidget);
    expect(find.text('18'), findsOneWidget);
  });

  testWidgets(
      'ApiConfig dynamically reconfigures endpoints and Profile screen provides auto-detect & edit UI',
      (WidgetTester tester) async {
    // 1. Dynamic IP reconfiguration test
    final originalIp = ApiConfig.hostIp;
    addTearDown(() => ApiConfig.hostIp = originalIp);

    ApiConfig.hostIp = '192.168.1.99';
    expect(ApiConfig.hostIp, '192.168.1.99');
    expect(ApiConfig.baseHost, '192.168.1.99:8000');
    expect(ApiConfig.restBaseUrl, 'http://192.168.1.99:8000');
    expect(ApiConfig.webSocketUrl, 'ws://192.168.1.99:8000');
    expect(ApiConfig.customerShopUrl('demo'), 'http://192.168.1.99:8000/shop/demo');

    // Reset back for UI test
    ApiConfig.hostIp = 'jh0yc.aiccloud.online';

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: const DashboardScreen(
          vendorId: 'test_vendor',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/test_vendor',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dismiss initial QR bottom sheet
    if (find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    }

    // Navigate to Profile tab
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    // Verify auto-detect button exists and scroll it into view
    final autoDetectFinder = find.byIcon(Icons.wifi_find_rounded);
    expect(autoDetectFinder, findsOneWidget);
    await tester.ensureVisible(autoDetectFinder);
    await tester.pumpAndSettle();

    expect(find.text('https://jh0yc.aiccloud.online'), findsOneWidget);

    // Tap Auto-Detect button (it completes gracefully even if no beacon on loopback)
    await tester.tap(autoDetectFinder, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'QR code modal does NOT show on regular dashboard startup, and opens on Show QR Code tap',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'has_seen_initial_qr': true});

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(
          vendorId: 'shopkeeper',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/shopkeeper',
          showQrOnLoad: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. QR code modal is NOT open on regular startup
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    // 2. Home screen is cleanly visible
    expect(find.text('Good day, Vendor 👋'), findsOneWidget);
    expect(find.text('Session Total'), findsOneWidget);

    // 3. Tap "View QR" button on Home screen
    final showQrButton = find.text('View QR');
    expect(showQrButton, findsOneWidget);
    await tester.tap(showQrButton);
    await tester.pumpAndSettle();

    // 4. Modal is now cleanly open
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    // Close modal
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
      'Auto-Delete Document After Print privacy badge and conditional deletion test',
      (WidgetTester tester) async {
    // 1. Model parsing verification
    final jobWithoutAutoDelete = PrintJob.fromJson({
      'order_id': 'ORD-STANDARD',
      'vendor_id': 'kiosk_1',
      'total_amount': 2.0,
      'status': 'paid',
      'auto_delete_after_print': false,
    });
    expect(jobWithoutAutoDelete.autoDeleteAfterPrint, false);

    final jobWithAutoDelete = PrintJob.fromJson({
      'order_id': 'ORD-CONFIDENTIAL',
      'vendor_id': 'kiosk_1',
      'total_amount': 2.0,
      'status': 'paid',
      'auto_delete_after_print': true,
    });
    expect(jobWithAutoDelete.autoDeleteAfterPrint, true);

    // 2. UI Badge verification in Queue
    SharedPreferences.setMockInitialValues({'has_seen_initial_qr': true});
    final client = MockClient((request) async {
      if (request.url.path.contains('/api/orders/vendor/')) {
        return http.Response(
          jsonEncode({
            'orders': [
              {
                'order_id': 'ORD-CONFIDENTIAL',
                'vendor_id': 'kiosk_1',
                'status': 'paid',
                'total_amount': 10.0,
                'total_pages': 1,
                'copies': 1,
                'color_mode': 'bw',
                'orientation': 'portrait',
                'auto_delete_after_print': true,
                'download_url':
                    'https://jh0yc.aiccloud.online/api/documents/ORD-CONFIDENTIAL/download',
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'kiosk_1',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/kiosk_1',
          showQrOnLoad: false,
          testHttpClient: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to Queue tab
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    // Verify "Auto-Delete After Print" privacy badge is displayed
    expect(find.text('Auto-Delete After Print'), findsOneWidget);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);

    // 3. Conditional file persistence & deletion test with handlePrintOrder
    final mockPdfBytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]); // %PDF
    final printHttpClient = MockClient((request) async {
      if (request.url.path.contains('/download')) {
        return http.Response.bytes(mockPdfBytes, 200);
      }
      return http.Response(jsonEncode({'status': 'completed'}), 200);
    });

    final ordersDir = await getOrdersDirectory();
    final retainedFile = File('${ordersDir.path}/ORD-RETAIN.pdf');
    final deletedFile = File('${ordersDir.path}/ORD-DELETE.pdf');

    // Case A: autoDeleteAfterPrint = false (File must remain saved)
    final retainJob = PrintJob(
      orderId: 'ORD-RETAIN',
      vendorId: 'kiosk_1',
      timestamp: '12:00 PM',
      totalAmount: 2.0,
      totalPages: 1,
      status: 'paid',
      downloadUrl:
          'https://jh0yc.aiccloud.online/api/documents/ORD-RETAIN/download',
      autoDeleteAfterPrint: false,
      documents: const [],
    );

    final printedRetain = await handlePrintOrder(
      tester.element(find.byType(DashboardScreen)),
      retainJob,
      httpClient: printHttpClient,
      printExecutor: ({
        required dynamicLayout,
        required format,
        required name,
        required pdfBytes,
      }) async =>
          true,
    );
    expect(printedRetain, true);
    expect(retainedFile.existsSync(), true);
    if (retainedFile.existsSync()) {
      retainedFile.deleteSync(); // cleanup
    }

    // Case B: autoDeleteAfterPrint = true (File must be deleted immediately)
    final autoDeleteJob = PrintJob(
      orderId: 'ORD-DELETE',
      vendorId: 'kiosk_1',
      timestamp: '12:01 PM',
      totalAmount: 2.0,
      totalPages: 1,
      status: 'paid',
      downloadUrl:
          'https://jh0yc.aiccloud.online/api/documents/ORD-DELETE/download',
      autoDeleteAfterPrint: true,
      documents: const [],
    );

    final printedDelete = await handlePrintOrder(
      tester.element(find.byType(DashboardScreen)),
      autoDeleteJob,
      httpClient: printHttpClient,
      printExecutor: ({
        required dynamicLayout,
        required format,
        required name,
        required pdfBytes,
      }) async =>
          true,
    );
    expect(printedDelete, true);
    expect(deletedFile.existsSync(), false);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'HistoryScreen loads completed orders, displays UPI payer names, filters search, and shows Order Details modal',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    final mockPdfBytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
    final ordersDir = await getOrdersDirectory();
    final savedFile = File('${ordersDir.path}/ORD-HIST-01.pdf');
    savedFile.writeAsBytesSync(mockPdfBytes);

    final mockCompletedJobs = [
      {
        'order_id': 'ORD-HIST-01',
        'vendor_id': 'kiosk_history_test',
        'payer_name': 'Rahul Sharma',
        'paid_at': '2026-11-15T17:20:00',
        'page_count': 6,
        'total_pages': 6,
        'copies': 2,
        'is_color': false,
        'total_amount': 12.0,
        'status': 'completed',
        'auto_delete_after_print': false,
        'documents': [],
      },
      {
        'order_id': 'ORD-HIST-02',
        'vendor_id': 'kiosk_history_test',
        'payer_name': 'Priya Verma',
        'paid_at': '2026-11-15T17:25:00',
        'page_count': 1,
        'total_pages': 1,
        'copies': 1,
        'is_color': true,
        'total_amount': 10.0,
        'status': 'completed',
        'auto_delete_after_print': true,
        'documents': [],
      },
    ];

    final testHttpClient = MockClient((request) async {
      if (request.url.path.contains('/history') ||
          (request.url.path == '/api/orders' &&
              request.url.queryParameters['status'] == 'completed')) {
        return http.Response(
          jsonEncode({'orders': mockCompletedJobs}),
          200,
        );
      }
      if (request.url.path.contains('/stats')) {
        return http.Response(
          jsonEncode({
            'bw_pages_printed': 6,
            'color_pages_printed': 1,
            'session_revenue': 22.0,
            'completed_orders': 2,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'orders': []}), 200);
    });

    bool printPreviewCalled = false;
    Future<bool> mockPrintExecutor({
      required Uint8List pdfBytes,
      required String name,
      required PdfPageFormat format,
      required bool dynamicLayout,
    }) async {
      printPreviewCalled = true;
      return true;
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'kiosk_history_test',
          shopUrl: 'https://printpulse.test/shop/kiosk_history_test',
          testHttpClient: testHttpClient,
          testPrintExecutor: mockPrintExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify 4 tabs exist in navigation dock: Home, Queue, History, Profile
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);

    // 2. Navigate to History tab
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.text('Order History'), findsOneWidget);
    expect(find.text('Rahul Sharma'), findsOneWidget);
    expect(find.text('Priya Verma'), findsOneWidget);
    expect(find.text('ORD-HIST-01'), findsOneWidget);
    expect(find.text('ORD-HIST-02'), findsOneWidget);
    expect(find.text('₹12.00'), findsOneWidget);
    expect(find.text('₹10.00'), findsOneWidget);

    // Check Badges: Rahul Sharma has Saved Locally, Priya has Auto-Deleted
    expect(find.text('Saved Locally'), findsOneWidget);
    expect(find.text('Auto-Deleted'), findsOneWidget);

    // 3. Test Search filtering
    await tester.enterText(
        find.byKey(const Key('history_search_field')), 'Rahul');
    await tester.pumpAndSettle();
    expect(find.text('Rahul Sharma'), findsOneWidget);
    expect(find.text('Priya Verma'), findsNothing);

    // Clear search
    await tester.tap(find.byKey(const Key('history_clear_search')));
    await tester.pumpAndSettle();
    expect(find.text('Rahul Sharma'), findsOneWidget);
    expect(find.text('Priya Verma'), findsOneWidget);

    // 4. Tap on Rahul Sharma's order to open Order Details modal
    await tester.tap(find.text('Rahul Sharma'));
    await tester.pumpAndSettle();

    expect(find.text('Order Details'), findsOneWidget);
    expect(find.text('Customer (UPI Name)'), findsOneWidget);
    expect(find.text('Print Specs'), findsOneWidget);
    expect(find.text('Open Document'), findsOneWidget);

    // Tap "Open Document" and verify print preview executor triggered (modal is dismissed)
    await tester.tap(find.text('Open Document'));
    await tester.pumpAndSettle();
    expect(printPreviewCalled, isTrue);

    // 5. Tap on Priya Verma's order (auto-delete = true)
    await tester.tap(find.text('Priya Verma'));
    await tester.pumpAndSettle();

    expect(find.text('Order Details'), findsOneWidget);
    expect(find.text('Document deleted after print (Customer Privacy)'),
        findsOneWidget);
    // Ensure "Open Document" button is NOT present
    expect(find.text('Open Document'), findsNothing);

    // Close details sheet
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // Clean up created mock file
    if (savedFile.existsSync()) {
      savedFile.deleteSync();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Cash at counter order triggers alert, displays Verify & Print and Cancel, and one-tap confirms & prints',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'has_seen_initial_qr': true,
      'upi_id': 'test@okaxis',
    });

    final wsController = StreamController<dynamic>.broadcast();
    bool confirmCashCalled = false;
    bool printPreviewCalled = false;

    final testHttpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.contains('/api/orders/vendor/kiosk_cash_test')) {
        return http.Response(jsonEncode({'orders': []}), 200);
      }
      if (path.contains('/confirm-cash')) {
        confirmCashCalled = true;
        return http.Response(
          jsonEncode({
            'status': 'success',
            'order': {
              'order_id': 'ORD-CASH-77',
              'vendor_id': 'kiosk_cash_test',
              'total_amount': 28.0,
              'total_pages': 4,
              'copies': 2,
              'status': 'paid',
              'payment_method': 'cash',
              'paid_at': '2026-11-15T18:40:00',
              'token_code': '5921',
              'download_url': '/api/documents/ORD-CASH-77/download',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.contains('/download')) {
        return http.Response.bytes(
          Uint8List.fromList('%PDF-1.4 Mock PDF'.codeUnits),
          200,
          headers: {'content-type': 'application/pdf'},
        );
      }
      if (path.contains('/status')) {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response(jsonEncode({'stats': {}}), 200);
    });

    Future<bool> mockPrintExecutor({
      required Uint8List pdfBytes,
      required String name,
      required PdfPageFormat format,
      required bool dynamicLayout,
    }) async {
      printPreviewCalled = true;
      return true;
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'kiosk_cash_test',
          shopUrl: 'https://printpulse.test/shop/kiosk_cash_test',
          testWebSocketStream: wsController.stream,
          testHttpClient: testHttpClient,
          testPrintExecutor: mockPrintExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Send draft upload awaiting_payment: Must be ignored
    wsController.add({
      'event': 'new_order',
      'order_id': 'ORD-DRAFT-99',
      'status': 'awaiting_payment',
      'total_amount': 50.0,
      'total_pages': 5,
    });
    await tester.pumpAndSettle();

    // Navigate to Queue
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('ORD-DRAFT-99'), findsNothing);
    expect(find.text('Queue is Empty'), findsOneWidget);

    // 2. Customer selects cash at counter ("Pay Cash at Counter")
    wsController.add({
      'event': 'new_order',
      'order_id': 'ORD-CASH-77',
      'vendor_id': 'kiosk_cash_test',
      'status': 'pending_cash',
      'payment_method': 'cash',
      'token_code': '5921',
      'total_amount': 28.0,
      'total_pages': 4,
      'copies': 2,
      'documents': [
        {
          'doc_id': 'doc_cash_1',
          'original_filename': 'resume.pdf',
          'staged_file': 'ORD-CASH-77_resume.pdf',
          'staged_path': '/uploads/ORD-CASH-77_resume.pdf',
          'pages': 2,
          'copies': 2,
          'is_color': false,
          'rate_per_page': 7.0,
          'total_amount': 28.0,
          'size_kb': 55.0,
        }
      ],
      'download_url': '/api/documents/ORD-CASH-77/download',
    });
    await tester.pumpAndSettle();

    // Verify cash order rendered with Token badge and action buttons Cancel and Verify & Print
    expect(find.text('ORD-CASH-77'), findsOneWidget);
    expect(find.text('Cash at Counter • ₹28.00 (#5921)'), findsOneWidget);
    expect(find.text('Verify & Print'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('PRINT'), findsNothing);
    expect(find.text('Confirm Manual Payment'), findsNothing);

    // 3. Vendor taps "Verify & Print" in ONE TAP:
    // Confirms cash with backend, updates earnings, and directly invokes print spooler
    await tester.tap(find.text('Verify & Print'));
    await tester.pumpAndSettle();

    expect(confirmCashCalled, isTrue);
    expect(printPreviewCalled, isTrue);

    // Clean up temporary files created in mock test run
    final tempDir = Directory.systemTemp;
    final cachedPdf = File('${tempDir.path}/PrintPulse_Orders/ORD-CASH-77.pdf');
    if (cachedPdf.existsSync()) {
      cachedPdf.deleteSync();
    }

    await wsController.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'GoogleAuthService authenticates vendor, persists profile in SharedPreferences, and handles cancellation gracefully',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    GoogleAuthService.resetForTesting();

    bool authEndpointCalled = false;
    final testHttpClient = MockClient((request) async {
      if (request.url.path.contains('/api/auth/google') ||
          request.url.path.contains('/api/vendor/auth/google')) {
        authEndpointCalled = true;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['id_token'], 'mock_google_id_token_123');

        return http.Response(
          jsonEncode({
            'status': 'authenticated',
            'vendor_id': 'kiosk_vendor_99',
            'email': 'vendor99@gmail.com',
            'name': 'Kiosk Vendor 99',
            'shop_name': "Kiosk 99's Print Shop",
            'upi_id': 'vendor99@okaxis',
            'session_token': 'pp_sess_mock_token_99',
            'shop_url': 'https://jh0yc.aiccloud.online/shop/kiosk_vendor_99',
            'onboarded': true,
            'onboarding_completed': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({}), 404);
    });

    // 1. Test Cancellation: When user cancels Google picker, UI does not crash
    GoogleAuthService.testAccountProvider = () async {
      throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'User canceled sign-in.',
      );
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AuthScreen(testHttpClient: testHttpClient),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);

    // Tap "Sign in with Google" when canceled
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    // Still on AuthScreen, button is active, no crash
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(authEndpointCalled, isFalse);

    // 2. Test Successful Sign-In
    GoogleAuthService.testAccountProvider = null;
    GoogleAuthService.testIdToken = 'mock_google_id_token_123';

    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    expect(authEndpointCalled, isTrue);

    // Verify vendor credentials were saved in SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vendor_id'), 'kiosk_vendor_99');
    expect(prefs.getString('email'), 'vendor99@gmail.com');
    expect(prefs.getString('name'), 'Kiosk Vendor 99');
    expect(prefs.getString('shop_name'), "Kiosk 99's Print Shop");
    expect(prefs.getString('session_token'), 'pp_sess_mock_token_99');

    // Verify navigated to DashboardScreen
    expect(find.byType(DashboardScreen), findsOneWidget);

    GoogleAuthService.resetForTesting();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Post-Google Sign-In onboarding wizard prompts new vendors, validates inputs, and updates backend & prefs',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    GoogleAuthService.resetForTesting();
    GoogleAuthService.testIdToken = 'mock_google_id_token_new';

    bool onboardEndpointCalled = false;
    final testHttpClient = MockClient((request) async {
      if (request.url.path.contains('/api/auth/google') ||
          request.url.path.contains('/api/vendor/auth/google')) {
        return http.Response(
          jsonEncode({
            'status': 'authenticated',
            'vendor_id': 'new_kiosk_vendor',
            'email': 'newvendor@gmail.com',
            'name': 'New Vendor',
            'shop_name': '',
            'upi_id': '',
            'session_token': 'pp_sess_new',
            'shop_url': 'https://jh0yc.aiccloud.online/shop/new_kiosk_vendor',
            'onboarded': false,
            'onboarding_completed': false,
            'bw_price': 2.0,
            'color_price': 10.0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.contains('/onboard')) {
        onboardEndpointCalled = true;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['shop_name'], "Abhay's Print & Xerox");
        expect(body['upi_id'], 'abhay@okicici');
        expect(body['bw_price'], 2.5);
        expect(body['color_price'], 12.0);
        return http.Response(
          jsonEncode({
            'status': 'onboarded',
            'vendor_id': 'new_kiosk_vendor',
            'shop_name': "Abhay's Print & Xerox",
            'upi_id': 'abhay@okicici',
            'bw_price': 2.5,
            'color_price': 12.0,
            'onboarded': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({}), 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        home: AuthScreen(testHttpClient: testHttpClient),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    // Verify OnboardingDialog is shown
    expect(find.byType(OnboardingDialog), findsOneWidget);
    expect(find.text('Shop Setup'), findsOneWidget);

    // Enter valid shop name, prices, UPI ID
    final shopField = find.widgetWithText(TextFormField, "e.g. Abhay's Xerox & Print");
    await tester.enterText(shopField, "Abhay's Print & Xerox");

    final bwField = find.widgetWithText(TextFormField, 'B&W Rate');
    await tester.enterText(bwField, '2.50');

    final colorField = find.widgetWithText(TextFormField, 'Color Rate');
    await tester.enterText(colorField, '12.00');

    final upiField = find.widgetWithText(TextFormField, 'e.g. shopkeeper@okicici');
    await tester.enterText(upiField, 'abhay@okicici');

    // Tap Save & Launch Kiosk
    await tester.tap(find.text('Save & Launch Kiosk'));
    await tester.pumpAndSettle();

    expect(onboardEndpointCalled, isTrue);
    expect(find.byType(OnboardingDialog), findsNothing);
    expect(find.byType(DashboardScreen), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_completed'), isTrue);
    expect(prefs.getString('shop_name'), "Abhay's Print & Xerox");
    expect(prefs.getString('upi_id'), 'abhay@okicici');

    GoogleAuthService.resetForTesting();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Zero-fee UPI claimed payment displays UTR badge, allows VERIFY & PRINT, and updates status',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'vendor_id': 'kiosk_vendor_99'});
    final wsController = StreamController<dynamic>.broadcast();
    addTearDown(wsController.close);

    bool verifyPaymentCalled = false;
    bool printedCalled = false;

    final kMinimalPdf = Uint8List.fromList(
      '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n3 0 obj<</Type/Page/MediaBox[0 0 595 842]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n150\n%%EOF'
          .codeUnits,
    );

    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/api/orders/vendor')) {
        return http.Response('{"orders": []}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/pricing')) {
        return http.Response(
            '{"vendor_id": "kiosk_vendor_99", "bw_price": 2.0, "color_price": 10.0}',
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/stats')) {
        return http.Response(
            '{"vendor_id": "kiosk_vendor_99", "session_revenue": 0.0, "bw_pages_printed": 0, "color_pages_printed": 0, "completed_orders": 0}',
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/verify-payment')) {
        verifyPaymentCalled = true;
        return http.Response(
          jsonEncode({
            'status': 'paid',
            'payment_status': 'PAID',
            'order_id': 'ORD-CLAIM-123',
            'order': {
              'order_id': 'ORD-CLAIM-123',
              'status': 'paid',
              'payment_status': 'PAID',
              'total_amount': 35.0,
              'amount': 35.0,
              'pages': 7,
              'copies': 1,
              'is_color': false,
              'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-CLAIM-123/download',
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.contains('/status')) {
        return http.Response('{"success": true}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(kMinimalPdf, 200,
          headers: {'content-type': 'application/pdf'});
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'kiosk_vendor_99',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/kiosk_vendor_99',
          testWebSocketStream: wsController.stream,
          testHttpClient: mockClient,
          testPrintExecutor: ({
            required Uint8List pdfBytes,
            required String name,
            required PdfPageFormat format,
            required bool dynamicLayout,
          }) async {
            printedCalled = true;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Navigate to Queue tab
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    // Simulate WebSocket event for zero-fee claimed UPI payment with 12-digit UTR
    wsController.add({
      'event': 'payment-claimed',
      'order_id': 'ORD-CLAIM-123',
      'vendor_id': 'kiosk_vendor_99',
      'payment_status': 'PAYMENT_CLAIMED',
      'status': 'pending_payment',
      'utr_number': '987654321012',
      'total_amount': 35.0,
      'order': {
        'order_id': 'ORD-CLAIM-123',
        'vendor_id': 'kiosk_vendor_99',
        'status': 'pending_payment',
        'payment_status': 'PAYMENT_CLAIMED',
        'payment_method': 'upi',
        'utr_number': '987654321012',
        'amount': 35.0,
        'total_amount': 35.0,
        'pages': 7,
        'copies': 1,
        'is_color': false,
        'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-CLAIM-123/download',
      }
    });
    await tester.pumpAndSettle();

    // Verify claimed order badge and UTR reference
    expect(find.text('PAYMENT CLAIMED • ₹35.00 (#987654321012)'), findsOneWidget);
    expect(find.text('VERIFY & PRINT'), findsOneWidget);
    expect(find.text('REJECT'), findsOneWidget);

    // Tap "VERIFY & PRINT"
    await tester.tap(find.text('VERIFY & PRINT'));
    await tester.pumpAndSettle();

    expect(verifyPaymentCalled, isTrue);
    expect(printedCalled, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('NotificationService channel, event contracts, and audio chime verification', () async {
    // 1. Verify fresh high-importance notification channel contract
    expect(NotificationService.channelId, equals('printpulse_urgent_jobs_v2'));
    expect(
        NotificationService.urgentJobsChannel.id, equals('printpulse_urgent_jobs_v2'));
    expect(NotificationService.urgentJobsChannel.importance,
        equals(Importance.max));
    expect(NotificationService.urgentJobsChannel.enableVibration, isTrue);
    expect(
      NotificationService.urgentJobsChannel.sound,
      equals(const RawResourceAndroidNotificationSound('new_job')),
    );

    // 2. Verify vendor channel and event contract names
    const vendorId = 'shopkeeper';
    const expectedChannel = 'vendor-$vendorId';
    final List<String> expectedEvents = [
      'new-job',
      'payment-claimed',
      'payment-verified',
    ];

    expect(expectedChannel, equals('vendor-shopkeeper'));
    expect(expectedEvents, contains('new-job'));
    expect(expectedEvents, contains('payment-claimed'));
    expect(expectedEvents, contains('payment-verified'));

    // 3. Verify audio chime invocation executes safely without throwing
    expect(
      () async => await NotificationService.playForegroundChime(),
      returnsNormally,
    );
  });

  testWidgets(
      'Clean Sign-Out and Sign-In transition lifecycle with zero assertion errors',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'vendor_id': 'kiosk_vendor_99',
      'shop_url': 'https://jh0yc.aiccloud.online/shop/kiosk_vendor_99',
    });

    activeVendorIdNotifier.value = 'kiosk_vendor_99';
    activeShopUrlNotifier.value = 'https://jh0yc.aiccloud.online/shop/kiosk_vendor_99';

    await tester.pumpWidget(const PrintPulseVendorApp(
      initialVendorId: 'kiosk_vendor_99',
      initialShopUrl: 'https://jh0yc.aiccloud.online/shop/kiosk_vendor_99',
    ));
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);

    // Navigate to Profile tab
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    // Trigger Disconnect Kiosk
    final disconnectBtn = find.text('Disconnect Kiosk');
    await tester.ensureVisible(disconnectBtn);
    await tester.pumpAndSettle();
    await tester.tap(disconnectBtn);
    await tester.pumpAndSettle();

    expect(find.text('Disconnect Kiosk?'), findsOneWidget);

    // Confirm Disconnect inside dialog
    await tester.tap(find.text('Disconnect'));
    // Pump frames to allow dialog reverse animation & route transition
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pumpAndSettle();

    // Verify clean transition to AuthScreen with zero assertion failures
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(activeVendorIdNotifier.value, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Decoupled print flow: Print dialog cancellation retains order in Queue with PAID • Ready to Print badge, Retry Print, and Mark Completed',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'has_seen_initial_qr': true,
      'upi_id': 'test@okaxis',
    });

    final wsController = StreamController<dynamic>.broadcast();
    addTearDown(wsController.close);

    bool printExecutorReturnedTrue = false;
    int printExecutorInvocations = 0;
    bool confirmCashCalled = false;
    bool completeStatusCalled = false;

    final kMinimalPdf = Uint8List.fromList(
      '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n3 0 obj<</Type/Page/MediaBox[0 0 595 842]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n150\n%%EOF'
          .codeUnits,
    );

    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/api/orders/vendor')) {
        return http.Response('{"orders": []}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/confirm-cash')) {
        confirmCashCalled = true;
        return http.Response(
          jsonEncode({
            'success': true,
            'order_id': 'ORD-CANCEL-1',
            'status': 'paid',
            'order': {
              'order_id': 'ORD-CANCEL-1',
              'status': 'paid',
              'payment_status': 'PAID',
              'payment_method': 'cash',
              'total_amount': 25.0,
              'pages': 5,
              'copies': 1,
              'is_color': false,
              'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-CANCEL-1/download',
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.contains('/status')) {
        final body = jsonDecode(request.body);
        if (body['status'] == 'completed') {
          completeStatusCalled = true;
        }
        return http.Response('{"success": true}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/stats')) {
        return http.Response('{"vendor_id": "test_vendor", "session_revenue": 0.0, "bw_pages_printed": 0, "color_pages_printed": 0, "completed_orders": 0}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/download')) {
        return http.Response.bytes(kMinimalPdf, 200, headers: {'content-type': 'application/pdf'});
      }
      return http.Response('{"orders": []}', 200, headers: {'content-type': 'application/json'});
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'test_vendor',
          shopUrl: 'https://jh0yc.aiccloud.online/shop/test_vendor',
          testWebSocketStream: wsController.stream,
          testHttpClient: mockClient,
          testPrintExecutor: ({
            required Uint8List pdfBytes,
            required String name,
            required PdfPageFormat format,
            required bool dynamicLayout,
          }) async {
            printExecutorInvocations++;
            return printExecutorReturnedTrue;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Receive Cash order in Queue
    wsController.add({
      'event': 'new_order',
      'order_id': 'ORD-CANCEL-1',
      'vendor_id': 'test_vendor',
      'status': 'pending_cash',
      'payment_method': 'cash',
      'payment_status': 'CASH_AT_COUNTER',
      'token_code': '4321',
      'total_amount': 25.0,
      'total_pages': 5,
      'copies': 1,
      'documents': [
        {
          'doc_id': 'doc_1',
          'original_filename': 'report.pdf',
          'pages': 5,
          'copies': 1,
          'is_color': false,
          'total_amount': 25.0,
          'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-CANCEL-1/download',
        }
      ],
      'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-CANCEL-1/download',
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('ORD-CANCEL-1'), findsOneWidget);
    expect(find.text('Cash at Counter • ₹25.00 (#4321)'), findsOneWidget);
    expect(find.text('Verify & Print'), findsOneWidget);

    // 2. Tap "Verify & Print" while print executor returns false (simulating vendor cancelling print dialog)
    printExecutorReturnedTrue = false;
    await tester.tap(find.text('Verify & Print'));
    await tester.pumpAndSettle();

    expect(confirmCashCalled, isTrue);
    expect(printExecutorInvocations, equals(1));
    expect(completeStatusCalled, isFalse);

    // Order MUST stay in Queue tab with "PAID • Ready to Print" badge, "Retry Print", and "Mark Completed"
    expect(find.text('ORD-CANCEL-1'), findsOneWidget);
    expect(find.text('PAID • Ready to Print'), findsOneWidget);
    expect(find.text('Retry Print'), findsOneWidget);
    expect(find.text('Mark Completed'), findsOneWidget);

    // 3. Vendor taps "Retry Print" with print dialog confirmed (returns true)
    printExecutorReturnedTrue = true;
    await tester.tap(find.text('Retry Print'));
    await tester.pumpAndSettle();

    expect(printExecutorInvocations, equals(2));
    expect(completeStatusCalled, isTrue);

    // Order should now be completed and removed from Queue
    expect(find.text('Queue is Empty'), findsOneWidget);
    expect(find.text('ORD-CANCEL-1'), findsNothing);

    // Clean up temporary files created in mock test run
    final tempDir = Directory.systemTemp;
    final cachedPdf = File('${tempDir.path}/PrintPulse_Orders/ORD-CANCEL-1.pdf');
    if (cachedPdf.existsSync()) {
      cachedPdf.deleteSync();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'Order History cards display compact Reprint button and invoke print preview directly',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    final mockCompletedJobs = [
      {
        'order_id': 'ORD-REPRINT-1',
        'vendor_id': 'kiosk_reprint_test',
        'payer_name': 'Amit Kumar',
        'paid_at': '2026-11-16T12:00:00',
        'page_count': 3,
        'total_pages': 3,
        'copies': 1,
        'is_color': false,
        'total_amount': 6.0,
        'status': 'completed',
        'auto_delete_after_print': false,
        'download_url': 'https://jh0yc.aiccloud.online/api/documents/ORD-REPRINT-1/download',
        'documents': [],
      },
    ];

    final kMinimalPdf = Uint8List.fromList(
      '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n3 0 obj<</Type/Page/MediaBox[0 0 595 842]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n150\n%%EOF'
          .codeUnits,
    );

    final testHttpClient = MockClient((request) async {
      if (request.url.path.contains('/history') ||
          (request.url.path == '/api/orders' &&
              request.url.queryParameters['status'] == 'completed')) {
        return http.Response(jsonEncode({'orders': mockCompletedJobs}), 200);
      }
      if (request.url.path.contains('/stats')) {
        return http.Response(jsonEncode({'session_revenue': 6.0, 'completed_orders': 1}), 200);
      }
      if (request.url.path.contains('/download')) {
        return http.Response.bytes(kMinimalPdf, 200, headers: {'content-type': 'application/pdf'});
      }
      return http.Response('{"orders": []}', 200);
    });

    bool reprintExecutorCalled = false;
    Future<bool> mockPrintExecutor({
      required Uint8List pdfBytes,
      required String name,
      required PdfPageFormat format,
      required bool dynamicLayout,
    }) async {
      reprintExecutorCalled = true;
      return true;
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DashboardScreen(
          vendorId: 'kiosk_reprint_test',
          shopUrl: 'https://printpulse.test/shop/kiosk_reprint_test',
          testHttpClient: testHttpClient,
          testPrintExecutor: mockPrintExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Navigate to History tab
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.text('Amit Kumar'), findsOneWidget);
    expect(find.text('ORD-REPRINT-1'), findsOneWidget);

    // Verify compact Reprint button is present on the card
    expect(find.text('Reprint'), findsOneWidget);

    // Tap Reprint directly on the history card
    await tester.tap(find.text('Reprint'));
    await tester.pumpAndSettle();

    expect(reprintExecutorCalled, isTrue);

    // Clean up temporary files created in mock test run
    final tempDir = Directory.systemTemp;
    final cachedPdf = File('${tempDir.path}/PrintPulse_Orders/ORD-REPRINT-1.pdf');
    if (cachedPdf.existsSync()) {
      cachedPdf.deleteSync();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
