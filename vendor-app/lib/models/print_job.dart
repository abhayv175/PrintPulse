class PrintDocument {
  final String docId;
  final String originalFilename;
  final String stagedFile;
  final String stagedPath;
  final int pages;
  final int copies;
  final bool isColor;
  final String pageRange;
  final String orientation;
  final String downloadUrl;
  final double ratePerPage;
  final double totalAmount;
  final double sizeKb;

  PrintDocument({
    required this.docId,
    required this.originalFilename,
    required this.stagedFile,
    required this.stagedPath,
    required this.pages,
    required this.copies,
    required this.isColor,
    this.pageRange = 'all',
    this.orientation = 'portrait',
    this.downloadUrl = '',
    required this.ratePerPage,
    required this.totalAmount,
    required this.sizeKb,
  });

  factory PrintDocument.fromJson(Map<String, dynamic> json) {
    return PrintDocument(
      docId: json['doc_id']?.toString() ?? '',
      originalFilename: json['original_filename']?.toString() ?? 'Document',
      stagedFile: json['staged_file']?.toString() ?? '',
      stagedPath: json['staged_path']?.toString() ?? '',
      pages: (json['pages'] as num?)?.toInt() ?? 1,
      copies: (json['copies'] as num?)?.toInt() ?? 1,
      isColor: json['is_color'] == true,
      pageRange: json['page_range']?.toString() ?? 'all',
      orientation: json['orientation']?.toString() ?? 'portrait',
      downloadUrl: json['download_url']?.toString() ?? '',
      ratePerPage: (json['rate_per_page'] as num?)?.toDouble() ?? 2.0,
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0.0,
      sizeKb: (json['size_kb'] as num?)?.toDouble() ?? 0.0,
    );
  }

  bool get isLandscape => orientation.toLowerCase() == 'landscape';

  Map<String, dynamic> toJson() => {
        'doc_id': docId,
        'original_filename': originalFilename,
        'staged_file': stagedFile,
        'staged_path': stagedPath,
        'pages': pages,
        'copies': copies,
        'is_color': isColor,
        'page_range': pageRange,
        'orientation': orientation,
        'download_url': downloadUrl,
        'rate_per_page': ratePerPage,
        'total_amount': totalAmount,
        'size_kb': sizeKb,
      };
}

class PrintJob {
  final String orderId;
  final String vendorId;
  final String timestamp;
  final double totalAmount;
  final int totalPages;
  final String status;
  final String paymentStatus;
  final String? utrNumber;
  final String? paidAt;
  final int explicitCopies;
  final bool explicitIsColor;
  final String pageRange;
  final String orientation;
  final String downloadUrl;
  final bool autoDeleteAfterPrint;
  final String payerName;
  final String paymentMethod;
  final String? tokenCode;
  final List<PrintDocument> documents;

  PrintJob({
    required this.orderId,
    required this.vendorId,
    required this.timestamp,
    required this.totalAmount,
    required this.totalPages,
    this.status = 'pending_payment',
    this.paymentStatus = 'PENDING_PAYMENT',
    this.utrNumber,
    this.paidAt,
    this.payerName = 'UPI Customer',
    this.paymentMethod = 'upi',
    this.tokenCode,
    this.explicitCopies = 1,
    this.explicitIsColor = false,
    this.pageRange = 'all',
    this.orientation = 'portrait',
    this.downloadUrl = '',
    this.autoDeleteAfterPrint = false,
    required this.documents,
  });

  factory PrintJob.fromJson(Map<String, dynamic> json) {
    var docsList = <PrintDocument>[];
    if (json['documents'] is List) {
      docsList = (json['documents'] as List)
          .map((doc) => PrintDocument.fromJson(Map<String, dynamic>.from(doc)))
          .toList();
    }

    final double parsedAmount =
        (json['total_amount'] as num? ?? json['amount'] as num?)?.toDouble() ??
            0.0;
    final int parsedCopies = (json['copies'] as num?)?.toInt() ??
        (docsList.isNotEmpty
            ? docsList.fold(0, (acc, doc) => acc + doc.copies)
            : 1);
    final int parsedPages = (json['total_pages'] as num?)?.toInt() ??
        (docsList.isNotEmpty
            ? docsList.fold(0, (acc, doc) => acc + (doc.pages * doc.copies))
            : ((json['pages'] as num?)?.toInt() ?? (json['page_count'] as num?)?.toInt() ?? 1));
    final String colorMode = (json['color_mode']?.toString() ?? '').toLowerCase();
    final bool parsedColor = colorMode == 'color' || json['is_color'] == true;
    final String parsedPageRange = json['page_range']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.pageRange : 'all');
    final String parsedOrientation = json['orientation']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.orientation : 'portrait');
    final String parsedDownloadUrl = json['download_url']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.downloadUrl : '');
    final bool parsedAutoDelete = json['auto_delete_after_print'] == true ||
        json['autoDeleteAfterPrint'] == true ||
        json['is_private'] == true ||
        json['isPrivate'] == true ||
        json['private'] == true;
    final String parsedPayerName = (json['payer_name']?.toString() ??
            json['payerName']?.toString() ??
            json['customer_name']?.toString() ??
            'UPI Customer')
        .trim();
    final String parsedPaymentMethod = (json['payment_method']?.toString() ??
            json['paymentMethod']?.toString() ??
            'upi')
        .toLowerCase()
        .trim();
    final String? parsedTokenCode = json['token_code']?.toString() ??
        json['tokenCode']?.toString();
    final String rawStatus = json['status']?.toString() ?? 'pending_payment';
    final String rawPaymentStatus = (json['payment_status']?.toString() ??
            json['paymentStatus']?.toString() ??
            '')
        .toUpperCase()
        .trim();

    final String parsedPaymentStatus = rawPaymentStatus.isNotEmpty
        ? rawPaymentStatus
        : (rawStatus.toLowerCase() == 'paid'
            ? 'PAID'
            : (rawStatus.toUpperCase() == 'CASH_AT_COUNTER' ||
                    rawStatus.toLowerCase() == 'pending_cash'
                ? 'CASH_AT_COUNTER'
                : (rawStatus.toUpperCase() == 'UPI_CLAIMED' ||
                        rawStatus.toUpperCase() == 'PAID_QUEUED'
                    ? 'PAYMENT_CLAIMED'
                    : 'PENDING_PAYMENT')));

    final String parsedStatus = (rawStatus.toLowerCase() == 'pending_cash' ||
            rawStatus.toUpperCase() == 'CASH_AT_COUNTER' ||
            parsedPaymentStatus == 'CASH_AT_COUNTER')
        ? 'CASH_AT_COUNTER'
        : (rawStatus.toUpperCase() == 'UPI_CLAIMED' ||
                rawStatus.toUpperCase() == 'PAID_QUEUED'
            ? 'UPI_CLAIMED'
            : rawStatus);
    final String? parsedUtrNumber = json['utr_number']?.toString() ??
        json['utrNumber']?.toString() ??
        json['utr']?.toString();

    return PrintJob(
      orderId: json['order_id']?.toString() ?? json['id']?.toString() ?? 'Unknown Order',
      vendorId: json['vendor_id']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '',
      totalAmount: parsedAmount,
      totalPages: parsedPages,
      status: parsedStatus,
      paymentStatus: parsedPaymentStatus,
      utrNumber: parsedUtrNumber,
      paidAt: json['paid_at']?.toString(),
      payerName: parsedPayerName.isNotEmpty ? parsedPayerName : 'UPI Customer',
      paymentMethod:
          parsedPaymentMethod.isNotEmpty ? parsedPaymentMethod : 'upi',
      tokenCode: parsedTokenCode,
      explicitCopies: parsedCopies,
      explicitIsColor: parsedColor,
      pageRange: parsedPageRange,
      orientation: parsedOrientation,
      downloadUrl: parsedDownloadUrl,
      autoDeleteAfterPrint: parsedAutoDelete,
      documents: docsList,
    );
  }

  PrintJob copyWith({
    String? status,
    String? paymentStatus,
    String? utrNumber,
    String? paidAt,
    String? payerName,
    String? paymentMethod,
    String? tokenCode,
    double? totalAmount,
    int? totalPages,
    String? pageRange,
    String? orientation,
    String? downloadUrl,
    bool? autoDeleteAfterPrint,
    bool? isPrivate,
    List<PrintDocument>? documents,
  }) {
    return PrintJob(
      orderId: orderId,
      vendorId: vendorId,
      timestamp: timestamp,
      totalAmount: totalAmount ?? this.totalAmount,
      totalPages: totalPages ?? this.totalPages,
      status: status ?? this.status,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      utrNumber: utrNumber ?? this.utrNumber,
      paidAt: paidAt ?? this.paidAt,
      payerName: payerName ?? this.payerName,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      tokenCode: tokenCode ?? this.tokenCode,
      explicitCopies: explicitCopies,
      explicitIsColor: explicitIsColor,
      pageRange: pageRange ?? this.pageRange,
      orientation: orientation ?? this.orientation,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      autoDeleteAfterPrint:
          autoDeleteAfterPrint ?? isPrivate ?? this.autoDeleteAfterPrint,
      documents: documents ?? this.documents,
    );
  }

  bool get isPrivate => autoDeleteAfterPrint;

  bool get isPaid =>
      status.toLowerCase() == 'paid' ||
      status.toLowerCase() == 'paid_not_printed' ||
      paymentStatus.toUpperCase() == 'PAID' ||
      status.toLowerCase() == 'completed' ||
      paymentStatus.toUpperCase() == 'COMPLETED';

  bool get isNotPrinted =>
      status.toLowerCase() == 'paid_not_printed' ||
      paymentStatus.toUpperCase() == 'NOT_PRINTED';

  bool get isUpiClaimed =>
      status.toUpperCase() == 'UPI_CLAIMED' ||
      status.toUpperCase() == 'PAID_QUEUED' ||
      paymentStatus.toUpperCase() == 'PAYMENT_CLAIMED' ||
      paymentStatus.toUpperCase() == 'UPI_CLAIMED';

  bool get isPaymentClaimed => isUpiClaimed;

  bool get isPaymentRejected => paymentStatus == 'REJECTED';

  bool get isCash => paymentMethod.toLowerCase() == 'cash';

  bool get isUpi => paymentMethod.toLowerCase() == 'upi';

  bool get isCashAtCounter =>
      status.toUpperCase() == 'CASH_AT_COUNTER' ||
      status.toLowerCase() == 'pending_cash' ||
      paymentStatus.toUpperCase() == 'CASH_AT_COUNTER' ||
      (isCash && !isPaid);

  bool get isPendingCash => isCashAtCounter;

  bool get isLandscape => orientation.toLowerCase() == 'landscape';

  int get totalPhysicalPages => documents.isNotEmpty
      ? documents.fold(0, (sum, doc) => sum + (doc.pages * doc.copies))
      : (totalPages > 0 ? totalPages : 1);

  int get totalCopies => documents.isNotEmpty
      ? documents.fold(0, (sum, doc) => sum + doc.copies)
      : explicitCopies;

  bool get hasColor => documents.isNotEmpty
      ? documents.any((doc) => doc.isColor)
      : explicitIsColor;

  bool get isColor => hasColor;

  String get colorMode => hasColor ? 'color' : 'bw';

  bool get isCompleted => status.toLowerCase() == 'completed';

  String get formattedPaidAt {
    if (paidAt == null || paidAt!.isEmpty) {
      return timestamp.isNotEmpty ? timestamp : 'Recently';
    }
    try {
      final dt = DateTime.parse(paidAt!).toLocal();
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final month = months[dt.month - 1];
      final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final minute = dt.minute.toString().padLeft(2, '0');
      final period = dt.hour >= 12 ? 'PM' : 'AM';
      return '${dt.day} $month ${dt.year}, $hour:$minute $period';
    } catch (_) {
      return paidAt!;
    }
  }

  Map<String, dynamic> toJson() => {
        'order_id': orderId,
        'vendor_id': vendorId,
        'timestamp': timestamp,
        'total_amount': totalAmount,
        'total_pages': totalPages,
        'status': status,
        'payment_status': paymentStatus,
        'utr_number': utrNumber,
        'paid_at': paidAt,
        'payer_name': payerName,
        'payment_method': paymentMethod,
        'token_code': tokenCode,
        'copies': explicitCopies,
        'is_color': explicitIsColor,
        'page_range': pageRange,
        'orientation': orientation,
        'download_url': downloadUrl,
        'auto_delete_after_print': autoDeleteAfterPrint,
        'is_private': isPrivate,
        'documents': documents.map((d) => d.toJson()).toList(),
      };
}
