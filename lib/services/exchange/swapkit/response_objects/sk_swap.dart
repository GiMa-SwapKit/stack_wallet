import 'package:decimal/decimal.dart';

import 'sk_parse_utils.dart';

/// An EVM call SwapKit built (`tx` with `txType: EVM`, or `approvalTx`).
class SkEvmTx {
  final String to;

  /// Value in wei.
  final BigInt value;

  /// Hex call data, 0x-prefixed.
  final String data;

  /// Gas limit, if SwapKit could estimate one.
  final int? gasLimit;

  SkEvmTx({
    required this.to,
    required this.value,
    required this.data,
    required this.gasLimit,
  });

  /// Parses `{to, value, data, gas | gasLimit}`; null if it isn't one.
  static SkEvmTx? tryParse(dynamic json) {
    final map = skMapOrNull(json);
    final to = skStringOrNull(map?["to"]);
    final data = skStringOrNull(map?["data"]);
    if (map == null || to == null || data == null || !data.startsWith("0x")) {
      return null;
    }
    final gas = skBigIntOrNull(map["gas"] ?? map["gasLimit"]);
    return SkEvmTx(
      to: to,
      value: skBigIntOrNull(map["value"]) ?? BigInt.zero,
      data: data,
      gasLimit: gas?.toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
    "to": to,
    "value": value.toString(),
    "data": data,
    if (gasLimit != null) "gasLimit": gasLimit,
  };
}

/// Response of `POST /v3/swap`.
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

  /// Kind of [evmTx] / [psbt] SwapKit built, e.g. `EVM` or `PSBT`. Null when
  /// the swap was created with `disableBuildTx`.
  final String? txType;

  /// Contract call to send, for `contractCall` routes on EVM chains.
  final SkEvmTx? evmTx;

  /// ERC-20 approval to send before [evmTx], if the allowance is too low.
  final SkEvmTx? approvalTx;

  /// Base64 PSBT to sign, for UTXO routes SwapKit builds itself.
  final String? psbt;

  /// Base64 serialised Solana transaction to sign (`SERIALIZED_BASE64`).
  final String? solanaTx;

  /// Hex CBOR Cardano transaction to sign (`CBOR`).
  final String? cardanoTx;

  /// Base64 XDR Stellar transaction envelope to sign (`STELLAR`).
  final String? stellarTx;

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
    this.txType,
    this.evmTx,
    this.approvalTx,
    this.psbt,
    this.solanaTx,
    this.cardanoTx,
    this.stellarTx,
  });

  factory SkSwap.fromMap(Map<String, dynamic> map) {
    final meta = skMapOrNull(map["meta"]);

    // `targetAddress` is the documented send destination. Deposit channel
    // routes may omit it and only return `inboundAddress`.
    var depositAddress =
        skStringOrNull(map["targetAddress"]) ??
        skStringOrNull(map["inboundAddress"]);
    // Bitcoin Cash addresses sometimes come without their cashaddr prefix
    if (depositAddress != null &&
        (map["sellAsset"] as String).startsWith("BCH.") &&
        !depositAddress.contains(":")) {
      depositAddress = "bitcoincash:$depositAddress";
    }
    if (depositAddress == null) {
      throw const FormatException(
        "SwapKit /v3/swap response has no targetAddress or inboundAddress",
      );
    }

    final expiry = meta?["depositChannelExpiration"];
    final txType = skStringOrNull(map["txType"]);
    final tx = map["tx"];

    return SkSwap(
      txType: txType,
      evmTx: txType == "EVM" ? SkEvmTx.tryParse(tx) : null,
      approvalTx: SkEvmTx.tryParse(map["approvalTx"]),
      psbt: txType == "PSBT" && tx is String && tx.isNotEmpty ? tx : null,
      solanaTx:
          txType == "SERIALIZED_BASE64" &&
              tx is String &&
              tx.isNotEmpty &&
              (map["sellAsset"] as String).startsWith("SOL.")
          ? tx
          : null,
      cardanoTx: txType == "CBOR" && tx is String && tx.isNotEmpty ? tx : null,
      stellarTx: txType == "STELLAR" && tx is String && tx.isNotEmpty
          ? tx
          : null,
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
