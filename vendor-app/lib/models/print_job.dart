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
}

class PrintJob {
  final String orderId;
  final String vendorId;
  final String timestamp;
  final double totalAmount;
  final int totalPages;
  final String status;
  final String? paidAt;
  final int explicitCopies;
  final bool explicitIsColor;
  final String pageRange;
  final String orientation;
  final String downloadUrl;
  final List<PrintDocument> documents;

  PrintJob({
    required this.orderId,
    required this.vendorId,
    required this.timestamp,
    required this.totalAmount,
    required this.totalPages,
    this.status = 'pending_payment',
    this.paidAt,
    this.explicitCopies = 1,
    this.explicitIsColor = false,
    this.pageRange = 'all',
    this.orientation = 'portrait',
    this.downloadUrl = '',
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
            : ((json['pages'] as num?)?.toInt() ?? 1));
    final String colorMode = (json['color_mode']?.toString() ?? '').toLowerCase();
    final bool parsedColor = colorMode == 'color' || json['is_color'] == true;
    final String parsedPageRange = json['page_range']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.pageRange : 'all');
    final String parsedOrientation = json['orientation']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.orientation : 'portrait');
    final String parsedDownloadUrl = json['download_url']?.toString() ??
        (docsList.isNotEmpty ? docsList.first.downloadUrl : '');

    return PrintJob(
      orderId: json['order_id']?.toString() ?? 'Unknown Order',
      vendorId: json['vendor_id']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '',
      totalAmount: parsedAmount,
      totalPages: parsedPages,
      status: json['status']?.toString() ?? 'pending_payment',
      paidAt: json['paid_at']?.toString(),
      explicitCopies: parsedCopies,
      explicitIsColor: parsedColor,
      pageRange: parsedPageRange,
      orientation: parsedOrientation,
      downloadUrl: parsedDownloadUrl,
      documents: docsList,
    );
  }

  PrintJob copyWith({
    String? status,
    String? paidAt,
    double? totalAmount,
    int? totalPages,
    String? pageRange,
    String? orientation,
    String? downloadUrl,
    List<PrintDocument>? documents,
  }) {
    return PrintJob(
      orderId: orderId,
      vendorId: vendorId,
      timestamp: timestamp,
      totalAmount: totalAmount ?? this.totalAmount,
      totalPages: totalPages ?? this.totalPages,
      status: status ?? this.status,
      paidAt: paidAt ?? this.paidAt,
      explicitCopies: explicitCopies,
      explicitIsColor: explicitIsColor,
      pageRange: pageRange ?? this.pageRange,
      orientation: orientation ?? this.orientation,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      documents: documents ?? this.documents,
    );
  }

  bool get isPaid => status == 'paid';

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
}
