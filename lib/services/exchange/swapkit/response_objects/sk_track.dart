import 'sk_parse_utils.dart';

/// Response of `POST /track`.
class SkTrack {
  /// One of: not_started, pending, swapping, completed, refunded, failed,
  /// unknown.
  final String status;
  final String? trackingStatus;
  final String? hash;
  final String? chainId;
  final String? fromAmount;
  final String? toAmount;
  final String? toAddress;

  /// Hash of the payout transaction, taken from the last leg when available.
  final String? outboundHash;

  SkTrack({
    required this.status,
    required this.trackingStatus,
    required this.hash,
    required this.chainId,
    required this.fromAmount,
    required this.toAmount,
    required this.toAddress,
    required this.outboundHash,
  });

  factory SkTrack.fromMap(Map<String, dynamic> map) {
    final legs = skMapList(map["legs"]);
    final hash = skStringOrNull(map["hash"]);
    final toAddress = skStringOrNull(map["toAddress"]);

    // The payout is the last leg paying the swap's destination, e.g. legs
    // [ETH deposit, NEAR swap, BTC send] for USDC -> BTC via NEAR. With a
    // single leg, the leg hash is the deposit, not a payout.
    String? outboundHash;
    if (legs.length > 1) {
      final payouts = legs.where(
        (l) =>
            toAddress != null &&
            skStringOrNull(l["toAddress"]) == toAddress &&
            skStringOrNull(l["hash"]) != hash,
      );
      final leg = payouts.isNotEmpty ? payouts.last : legs.last;
      final legHash = skStringOrNull(leg["hash"]);
      outboundHash = legHash != hash ? legHash : null;
    }

    return SkTrack(
      status: skStringOrNull(map["status"]) ?? "unknown",
      trackingStatus: skStringOrNull(map["trackingStatus"]),
      hash: hash,
      chainId: skStringOrNull(map["chainId"]),
      fromAmount: skStringOrNull(map["fromAmount"]),
      toAmount: skStringOrNull(map["toAmount"]),
      toAddress: toAddress,
      outboundHash: outboundHash,
    );
  }
}
