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
    final lastLegHash = legs.isNotEmpty
        ? skStringOrNull(legs.last["hash"])
        : null;
    final hash = skStringOrNull(map["hash"]);

    return SkTrack(
      status: skStringOrNull(map["status"]) ?? "unknown",
      trackingStatus: skStringOrNull(map["trackingStatus"]),
      hash: hash,
      chainId: skStringOrNull(map["chainId"]),
      fromAmount: skStringOrNull(map["fromAmount"]),
      toAmount: skStringOrNull(map["toAmount"]),
      toAddress: skStringOrNull(map["toAddress"]),
      // with a single leg the leg hash is the inbound hash, not a payout
      outboundHash: legs.length > 1 && lastLegHash != hash ? lastLegHash : null,
    );
  }
}
