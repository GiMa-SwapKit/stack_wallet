import 'package:decimal/decimal.dart';

import 'sk_parse_utils.dart';

/// Response of `POST /v3/swap` (called with `disableBuildTx: true`).
class SkSwap {
  final String swapId;
  final String routeId;
  final DateTime createdAt;
  final List<String> providers;
  final String sellAsset;
  final String buyAsset;
  final Decimal sellAmount;
  final Decimal expectedBuyAmount;
  final String sourceAddress;
  final String destinationAddress;

  /// Where the user must send [sellAmount] of [sellAsset].
  final String depositAddress;
  final String? memo;
  final String? txHint;

  /// Chainflip / Flashnet deposit channel id, used for `/track`.
  final String? depositChannelId;

  /// Deposit deadline (NOT the quote expiry).
  final DateTime? depositChannelExpiration;

  SkSwap({
    required this.swapId,
    required this.routeId,
    required this.createdAt,
    required this.providers,
    required this.sellAsset,
    required this.buyAsset,
    required this.sellAmount,
    required this.expectedBuyAmount,
    required this.sourceAddress,
    required this.destinationAddress,
    required this.depositAddress,
    required this.memo,
    required this.txHint,
    required this.depositChannelId,
    required this.depositChannelExpiration,
  });

  factory SkSwap.fromMap(Map<String, dynamic> map) {
    final meta = skMapOrNull(map["meta"]);

    // `targetAddress` is the documented send destination. Deposit channel
    // routes may omit it and only return `inboundAddress`.
    final depositAddress =
        skStringOrNull(map["targetAddress"]) ??
        skStringOrNull(map["inboundAddress"]);
    if (depositAddress == null) {
      throw const FormatException(
        "SwapKit /v3/swap response has no targetAddress or inboundAddress",
      );
    }

    final expiry = meta?["depositChannelExpiration"];

    return SkSwap(
      swapId: map["swapId"] as String,
      routeId: map["routeId"] as String,
      createdAt:
          DateTime.tryParse(map["createdAt"]?.toString() ?? "")?.toUtc() ??
          DateTime.now().toUtc(),
      providers: (map["providers"] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      sellAsset: map["sellAsset"] as String,
      buyAsset: map["buyAsset"] as String,
      sellAmount: skDecimalOrNull(map["sellAmount"]) ?? Decimal.zero,
      expectedBuyAmount:
          skDecimalOrNull(map["expectedBuyAmount"]) ?? Decimal.zero,
      sourceAddress: map["sourceAddress"]?.toString() ?? "",
      destinationAddress: map["destinationAddress"]?.toString() ?? "",
      depositAddress: depositAddress,
      memo: skStringOrNull(map["memo"]),
      txHint: skStringOrNull(map["txHint"]),
      depositChannelId: skStringOrNull(meta?["providerDepositChannelId"]),
      depositChannelExpiration: expiry is num
          ? DateTime.fromMillisecondsSinceEpoch(
              expiry.toInt() * 1000,
              isUtc: true,
            )
          : null,
    );
  }
}
