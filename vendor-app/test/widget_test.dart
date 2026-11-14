import 'dart:async';
import 'dart:convert';
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
import 'package:vendor_app/services/sound_service.dart';
import 'package:vendor_app/theme/app_theme.dart';
import 'package:vendor_app/theme/theme_controller.dart';
import 'package:vendor_app/widgets/animated_background.dart';

void main() {
  setUp(() {
    SoundService.enabled = false;
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

    // Dismiss auto-opened Counter QR modal sheet.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

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
    expect(pillAlignment().x, closeTo(currentPage() - 1.0, 0.01));

    // Complete swipe left to settle on Queue tab (index 1).
    await swipeGesture.moveBy(Offset(-pageWidth * 0.25, 0));
    await swipeGesture.up();
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(1.0, 0.01));
    expect(pillAlignment().x, closeTo(0.0, 0.01));
    expect(find.text('Live Queue'), findsOneWidget);

    // 2) Drag directly on the bottom dock bar and verify PageView follows in 1:1 lockstep.
    final dockFinder = find.byType(BackdropFilter);
    final dockCenter = tester.getCenter(dockFinder);
    final dockTrackWidth = tester.getSize(dockFinder).width - 8; // 4px padding each side
    final dockGesture = await tester.startGesture(dockCenter);
    // Drag right by half a tab width -> +0.5 page -> alignment ~ +0.5
    await dockGesture.moveBy(Offset(dockTrackWidth / 6.0, 0));
    await tester.pump();

    expect(currentPage(), closeTo(1.5, 0.06));
    expect(pillAlignment().x, closeTo(0.5, 0.06));

    // Finish drag past threshold to settle on Profile tab (index 2).
    await dockGesture.moveBy(Offset(dockTrackWidth / 6.0, 0));
    await dockGesture.up();
    await tester.pumpAndSettle();

    expect(currentPage(), closeTo(2.0, 0.01));
    expect(pillAlignment().x, closeTo(1.0, 0.01));
    expect(find.text('Kiosk Profile & Settings'), findsOneWidget);

    // 3) Tap 'Home' tab to glide smoothly back to index 0.
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

      // Dismiss auto-opened Counter QR modal sheet.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

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

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // Home tab badge displays Terminal ID with the derived email prefix.
    expect(find.text('Terminal ID: $derivedVendorId'), findsOneWidget);

    // Profile tab displays the derived vendor ID and customer shop URL.
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text(derivedVendorId), findsOneWidget);
    expect(find.text(expectedUrl), findsOneWidget);
    expect(find.text('http://192.168.1.41:8000'), findsOneWidget);
    expect(find.text('ws://192.168.1.41:8000'), findsOneWidget);

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
          shopUrl: 'http://192.168.1.41:8000/shop/abhayv175',
          testWebSocketStream: wsController.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dismiss auto-opened Counter QR sheet.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('₹0.00'), findsOneWidget);
    expect(find.text('0 jobs'), findsOneWidget);

    // 1. Incoming unpaid order -> Queue shows locked "Awaiting Payment", Session Total stays 0.00.
    wsController.add({
      'event': 'NEW_PRINT_JOB',
      'order_id': 'ord_89324',
      'vendor_id': 'abhayv175',
      'status': 'pending_payment',
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

    // Switch to Queue tab to inspect unpaid state.
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('ord_89324'), findsOneWidget);
    expect(find.text('Awaiting Payment'), findsOneWidget);
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.text('Confirm Manual Payment'), findsOneWidget);

    // 2. Payment confirmed -> Queue card unlocks with PAID badge & PRINT; Home counters increment.
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
      },
    });
    await tester.pumpAndSettle();

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
      'Startup migrates stale 192.168.1.39 or empty SharedPreferences cache to 192.168.1.41',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'vendor_id': 'abhayv175',
      'shop_url': 'http://192.168.1.39:8000/shop/abhayv175',
      'api_host': '192.168.1.39:8000',
      'host_url': '',
    });

    final prefs = await SharedPreferences.getInstance();
    final migratedShopUrl = await loadNormalizedShopUrl(prefs);

    expect(migratedShopUrl, 'http://192.168.1.41:8000/shop/abhayv175');
    expect(prefs.getString('shop_url'), 'http://192.168.1.41:8000/shop/abhayv175');
    expect(prefs.getString('api_host'), 'http://192.168.1.41:8000');
    expect(prefs.getString('host_url'), 'http://192.168.1.41:8000');

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

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('http://192.168.1.41:8000'), findsOneWidget);
    expect(find.text('ws://192.168.1.41:8000'), findsOneWidget);
    expect(find.text('http://192.168.1.41:8000/shop/abhayv175'), findsOneWidget);

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
          shopUrl: 'http://192.168.1.41:8000/shop/abhayv175',
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

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // 1. Image order with localhost URL -> normalizes to 192.168.1.41 and converts image to A4 PDF
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

    // Host must be normalized away from localhost to 192.168.1.41:8000
    expect(fetchedUri?.host, '192.168.1.41');
    expect(fetchedUri?.port, 8000);
    expect(fetchedUri?.path, '/api/documents/ord_img_77/download');
    expect(capturedFormat, PdfPageFormat.a4);
    expect(capturedDynamicLayout, isFalse);

    // Image must be wrapped in valid PDF (%PDF header)
    expect(capturedPdfBytes, isNotNull);
    final header = String.fromCharCodes(capturedPdfBytes!.take(4));
    expect(header, '%PDF');

    expect(find.text('ord_img_77'), findsNothing);

    await tester.pumpAndSettle();
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
      'download_url': 'http://192.168.1.41:8000/api/documents/ord_status_test/download',
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
}
