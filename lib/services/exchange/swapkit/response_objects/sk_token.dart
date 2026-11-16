import 'sk_parse_utils.dart';

/// An asset as returned by `GET /tokens`.
///
/// [identifier] is SwapKit's asset id: `CHAIN.TICKER` for gas assets
/// (e.g. `BTC.BTC`) and `CHAIN.TICKER-CONTRACT` for tokens
/// (e.g. `ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48`).
class SkToken {
  final String chain;
  final String? chainId;
  final String ticker;
  final String identifier;
  final String name;
  final int? decimals;

  /// Token contract with original (checksum) casing. Null for gas assets.
  final String? address;
  final String? logoURI;
  final String? coingeckoId;
  final bool isStablecoin;

  SkToken({
    required this.chain,
    required this.chainId,
    required this.ticker,
    required this.identifier,
    required this.name,
    required this.decimals,
    required this.address,
    required this.logoURI,
    required this.coingeckoId,
    required this.isStablecoin,
  });

  bool get isGasAsset => address == null || address!.isEmpty;

  factory SkToken.fromMap(Map<String, dynamic> map) => SkToken(
    chain: map["chain"] as String,
    chainId: skStringOrNull(map["chainId"]),
    ticker: map["ticker"] as String,
    identifier: map["identifier"] as String,
    name: skStringOrNull(map["name"]) ?? map["ticker"] as String,
    decimals: map["decimals"] is int ? map["decimals"] as int : null,
    address: skStringOrNull(map["address"]),
    logoURI: skStringOrNull(map["logoURI"]),
    coingeckoId: skStringOrNull(map["coingeckoId"]),
    isStablecoin: map["isStablecoin"] == true,
  );

  @override
  String toString() => "SkToken($identifier)";
}
