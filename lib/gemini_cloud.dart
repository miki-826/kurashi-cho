import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const geminiCloudModels = <String, String>{
  'gemini-3.5-flash-lite': 'Gemini 3.5 Flash-Lite（速度・料金優先）',
  'gemini-3.6-flash': 'Gemini 3.6 Flash（精度優先）',
  'gemini-2.5-flash': 'Gemini 2.5 Flash（互換性優先）',
};

class GeminiCloudSettings extends ChangeNotifier {
  GeminiCloudSettings._(
    this._prefs,
    this._storage,
    this.enabled,
    this.model,
    this._apiKey,
  );

  static const _enabledKey = 'gemini_cloud_enabled_v1';
  static const _modelKey = 'gemini_cloud_model_v1';
  static const _apiKeyStorageKey = 'gemini_cloud_api_key_v1';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _storage;
  bool enabled;
  String model;
  String? _apiKey;

  bool get hasApiKey => _apiKey?.trim().isNotEmpty == true;
  String? get apiKey => _apiKey;

  static Future<GeminiCloudSettings> open() async {
    final prefs = await SharedPreferences.getInstance();
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(storageNamespace: 'kurashi_gemini'),
    );
    String? apiKey;
    try {
      apiKey = await storage.read(key: _apiKeyStorageKey);
    } catch (_) {
      apiKey = null;
    }
    final storedModel =
        prefs.getString(_modelKey) ?? geminiCloudModels.keys.first;
    final enabled =
        (prefs.getBool(_enabledKey) ?? false) &&
        apiKey?.trim().isNotEmpty == true;
    if (!enabled && (prefs.getBool(_enabledKey) ?? false)) {
      await prefs.setBool(_enabledKey, false);
    }
    return GeminiCloudSettings._(
      prefs,
      storage,
      enabled,
      geminiCloudModels.containsKey(storedModel)
          ? storedModel
          : geminiCloudModels.keys.first,
      apiKey,
    );
  }

  Future<void> saveApiKey(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    await _storage.write(key: _apiKeyStorageKey, value: normalized);
    _apiKey = normalized;
    notifyListeners();
  }

  Future<void> clearApiKey() async {
    await _storage.delete(key: _apiKeyStorageKey);
    _apiKey = null;
    enabled = false;
    await _prefs.setBool(_enabledKey, false);
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value && hasApiKey;
    await _prefs.setBool(_enabledKey, enabled);
    notifyListeners();
  }

  Future<void> setModel(String value) async {
    if (!geminiCloudModels.containsKey(value)) return;
    model = value;
    await _prefs.setString(_modelKey, value);
    notifyListeners();
  }
}

class GeminiCloudException implements Exception {
  const GeminiCloudException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CloudExpenseItemCandidate {
  const CloudExpenseItemCandidate({
    required this.name,
    required this.quantity,
    required this.amount,
    required this.categoryCode,
  });

  final String name;
  final int quantity;
  final int amount;
  final String categoryCode;

  factory CloudExpenseItemCandidate.fromJson(Map<String, dynamic> json) {
    return CloudExpenseItemCandidate(
      name: (json['name'] as String?)?.trim() ?? '',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      categoryCode: (json['categoryCode'] as String?) ?? 'other',
    );
  }
}

class CloudExpenseCandidate {
  const CloudExpenseCandidate({
    this.merchant,
    this.purchasedAt,
    required this.totalAmount,
    this.paymentMethod,
    required this.categoryCode,
    required this.items,
    required this.confidence,
    required this.warnings,
  });

  final String? merchant;
  final DateTime? purchasedAt;
  final int totalAmount;
  final String? paymentMethod;
  final String categoryCode;
  final List<CloudExpenseItemCandidate> items;
  final double confidence;
  final List<String> warnings;

  factory CloudExpenseCandidate.fromJson(Map<String, dynamic> json) {
    return CloudExpenseCandidate(
      merchant: (json['merchant'] as String?)?.trim(),
      purchasedAt: DateTime.tryParse((json['purchasedAt'] as String?) ?? ''),
      totalAmount: (json['totalAmount'] as num?)?.toInt() ?? 0,
      paymentMethod: (json['paymentMethod'] as String?)?.trim(),
      categoryCode: (json['categoryCode'] as String?) ?? 'other',
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CloudExpenseItemCandidate.fromJson)
          .toList(),
      confidence: ((json['confidence'] as num?)?.toDouble() ?? 0)
          .clamp(0.0, 1.0)
          .toDouble(),
      warnings: (json['warnings'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
    );
  }
}

class GeminiCloudClient {
  GeminiCloudClient(this.settings, {http.Client? client})
    : _client = client ?? http.Client();

  final GeminiCloudSettings settings;
  final http.Client _client;

  void close() => _client.close();

  Future<void> testConnection() async {
    final key = _requiredKey();
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/${settings.model}',
    );
    final response = await _client
        .get(uri, headers: {'x-goog-api-key': key})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw _responseException(response);
    }
  }

  Future<List<CloudExpenseCandidate>> analyzeImage({
    required String imagePath,
    required String ocrText,
    required Map<String, String> categories,
  }) async {
    final key = _requiredKey();
    final file = File(imagePath);
    if (!await file.exists()) {
      throw const GeminiCloudException('画像ファイルを読み込めませんでした。');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 19 * 1024 * 1024) {
      throw const GeminiCloudException('画像が大きすぎます。20MB未満の画像を選んでください。');
    }
    final mimeType = _mimeType(imagePath);
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/${settings.model}:generateContent',
    );
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': _prompt(ocrText, categories)},
                  {
                    'inline_data': {
                      'mime_type': mimeType,
                      'data': base64Encode(bytes),
                    },
                  },
                ],
              },
            ],
            'generationConfig': {
              'responseFormat': {
                'text': {
                  'mimeType': 'application/json',
                  'schema': _responseSchema(categories.keys.toList()),
                },
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 120));
    if (response.statusCode != 200) {
      throw _responseException(response);
    }
    return parseGeminiExpenseResponse(response.body);
  }

  static List<CloudExpenseCandidate> parseGeminiExpenseResponse(
    String responseBody,
  ) {
    final envelope = jsonDecode(responseBody) as Map<String, dynamic>;
    final candidates = envelope['candidates'] as List<dynamic>? ?? const [];
    if (candidates.isEmpty) {
      throw const GeminiCloudException('Geminiから解析結果が返りませんでした。');
    }
    final first = candidates.first as Map<String, dynamic>;
    final content = first['content'] as Map<String, dynamic>? ?? const {};
    final parts = content['parts'] as List<dynamic>? ?? const [];
    final text = parts
        .whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join();
    if (text.trim().isEmpty) {
      throw const GeminiCloudException('Geminiの解析結果が空でした。');
    }
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final purchases = (decoded['purchases'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CloudExpenseCandidate.fromJson)
        .where((purchase) => purchase.totalAmount > 0)
        .toList();
    if (purchases.isEmpty) {
      throw const GeminiCloudException('保存できる費用候補を検出できませんでした。');
    }
    return List<CloudExpenseCandidate>.unmodifiable(purchases);
  }

  String _requiredKey() {
    final key = settings.apiKey?.trim();
    if (key == null || key.isEmpty) {
      throw const GeminiCloudException('Gemini APIキーが設定されていません。');
    }
    return key;
  }

  GeminiCloudException _responseException(http.Response response) {
    var message = 'Gemini APIへ接続できませんでした。';
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      final apiMessage = error?['message'] as String?;
      if (apiMessage?.isNotEmpty == true) message = apiMessage!;
    } catch (_) {
      // Keep the privacy-safe generic message.
    }
    return GeminiCloudException(message, statusCode: response.statusCode);
  }

  String _mimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _prompt(String ocrText, Map<String, String> categories) =>
      '''
あなたは日本の家計簿アプリの購入画像解析エンジンです。
画像内にある実際に支払った費用を抽出してください。

重要:
- 1枚に複数のレシート、請求、決済、注文、取引行がある場合は、別々のpurchases要素にする。
- 1枚のレシートの商品明細は複数費用へ分割せず、1購入のitemsにまとめる。
- 同一取引を重複させない。
- 小計、預り金、釣銭、残高、ポイント残高を支払額にしない。
- 推測だけで存在しない費用や商品を作らない。
- 商品合計と支払合計が違っても値を捏造しない。
- 日時が不明ならpurchasedAtは省略し、warningsへ追加する。
- 日本円の整数で読み取れる費用だけを返す。

利用可能カテゴリ:
${categories.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ')}

端末内OCR文字列:
${ocrText.length > 8000 ? ocrText.substring(0, 8000) : ocrText}
''';

  Map<String, dynamic> _responseSchema(List<String> categoryCodes) => {
    'type': 'object',
    'properties': {
      'purchases': {
        'type': 'array',
        'maxItems': 30,
        'items': {
          'type': 'object',
          'properties': {
            'merchant': {
              'type': ['string', 'null'],
            },
            'purchasedAt': {
              'type': ['string', 'null'],
              'format': 'date-time',
            },
            'totalAmount': {'type': 'integer', 'minimum': 0},
            'paymentMethod': {
              'type': ['string', 'null'],
            },
            'categoryCode': {'type': 'string', 'enum': categoryCodes},
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                  'quantity': {'type': 'integer', 'minimum': 1},
                  'amount': {'type': 'integer', 'minimum': 0},
                  'categoryCode': {'type': 'string', 'enum': categoryCodes},
                },
                'required': ['name', 'quantity', 'amount', 'categoryCode'],
              },
            },
            'confidence': {'type': 'number', 'minimum': 0, 'maximum': 1},
            'warnings': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': [
            'totalAmount',
            'categoryCode',
            'items',
            'confidence',
            'warnings',
          ],
        },
      },
    },
    'required': ['purchases'],
  };
}
