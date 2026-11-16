import 'package:decimal/decimal.dart';

import 'sk_parse_utils.dart';

/// Response of `POST /v3/quote`.
class SkQuote {
  final String? quoteId;
  final List<SkRoute> routes;
  final List<SkProviderError> providerErrors;

  SkQuote({
    required this.quoteId,
    required this.routes,
    required this.providerErrors,
  });

  factory SkQuote.fromMap(Map<String, dynamic> map) => SkQuote(
    quoteId: skStringOrNull(map["quoteId"]),
    routes: skMapList(map["routes"]).map(SkRoute.fromMap).toList(),
    providerErrors: skMapList(
      map["providerErrors"],
    ).map(SkProviderError.fromMap).toList(),
  );

  /// Smallest `minAmount` reported by any provider that declined the amount
  /// with `sellAssetAmountTooSmall`. Human units.
  Decimal? get reportedMinAmount {
    final mins = providerErrors
        .map((e) => e.minAmount)
        .whereType<Decimal>()
        .toList();
    if (mins.isEmpty) return null;
    mins.sort();
    return mins.first;
  }
}

class SkRoute {
  /// Cached server side for ~5 minutes. Passed to `/v3/swap`.
  final String routeId;
  final List<String> providers;
  final String sellAsset;
  final String buyAsset;
  final Decimal sellAmount;
  final Decimal expectedBuyAmount;
  final Decimal? expectedBuyAmountMaxSlippage;
  final int? estimatedTimeSeconds;
  final String? txHint;
  final List<String> tags;
  final List<String> warnings;

  SkRoute({
    required this.routeId,
    required this.providers,
    required this.sellAsset,
    required this.buyAsset,
    required this.sellAmount,
    required this.expectedBuyAmount,
    required this.expectedBuyAmountMaxSlippage,
    required this.estimatedTimeSeconds,
    required this.txHint,
    required this.tags,
    required this.warnings,
  });

  /// Stable key identifying the route's provider combination, e.g.
  /// `CHAINFLIP` or `ONEINCH+CHAINFLIP`.
  String get providerKey => providers.join("+");

  factory SkRoute.fromMap(Map<String, dynamic> map) {
    final meta = skMapOrNull(map["meta"]);
    final time = skMapOrNull(map["estimatedTime"]);
    return SkRoute(
      routeId: map["routeId"] as String,
      providers: (map["providers"] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      sellAsset: map["sellAsset"] as String,
      buyAsset: map["buyAsset"] as String,
      sellAmount: skDecimalOrNull(map["sellAmount"]) ?? Decimal.zero,
      expectedBuyAmount:
          skDecimalOrNull(map["expectedBuyAmount"]) ?? Decimal.zero,
      expectedBuyAmountMaxSlippage: skDecimalOrNull(
        map["expectedBuyAmountMaxSlippage"],
      ),
      estimatedTimeSeconds: (time?["total"] as num?)?.round(),
      txHint: skStringOrNull(map["txHint"]),
      tags: (meta?["tags"] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      warnings: skMapList(map["warnings"])
          .map((e) => skStringOrNull(e["display"]) ?? e["code"].toString())
          .toList(),
    );
  }
}

class SkProviderError {
  final String? provider;
  final String? errorCode;
  final String? message;
  final Decimal? minAmount;

  SkProviderError({
    required this.provider,
    required this.errorCode,
    required this.message,
    required this.minAmount,
  });

  factory SkProviderError.fromMap(Map<String, dynamic> map) => SkProviderError(
    provider: skStringOrNull(map["provider"]),
    errorCode: skStringOrNull(map["errorCode"]),
    message: skStringOrNull(map["message"]),
    minAmount: skDecimalOrNull(map["minAmount"]),
  );
}
