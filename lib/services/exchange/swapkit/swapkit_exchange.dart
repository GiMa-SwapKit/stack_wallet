/*
 * This file is part of Stack Wallet.
 *
 * Copyright (c) 2026 Cypher Stack
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:isar_community/isar.dart';
import 'package:uuid/uuid.dart';

import '../../../app_config.dart';
import '../../../exceptions/exchange/exchange_exception.dart';
import '../../../models/exchange/response_objects/estimate.dart';
import '../../../models/exchange/response_objects/range.dart';
import '../../../models/exchange/response_objects/trade.dart';
import '../../../models/isar/exchange_cache/currency.dart';
import '../../../models/isar/exchange_cache/pair.dart';
import '../../trade_sent_from_stack_service.dart';
import '../exchange.dart';
import '../exchange_data_loading_service.dart';
import '../exchange_response.dart';
import 'response_objects/sk_quote.dart';
import 'response_objects/sk_swap.dart';
import 'response_objects/sk_token.dart';
import 'response_objects/sk_track.dart';
import 'swapkit_api.dart';

/// SwapKit (https://swapkit.dev) cross-chain swap aggregator.
///
/// SwapKit routes a swap through one of several providers (Chainflip, NEAR
/// Intents, THORChain, Maya, ...). Each route is shown in the provider list as
/// its own estimate, like Trocador's partners, e.g. "SwapKit (Chainflip)".
///
/// Only routes whose deposit is a plain transfer to a deposit address
/// (`txHint == simpleTransfer`) are requested, so the existing
/// "send to pay-in address" flow works unchanged for every coin.
class SwapKitExchange extends Exchange {
  SwapKitExchange._();

  static SwapKitExchange? _instance;
  static SwapKitExchange get instance => _instance ??= SwapKitExchange._();

  /// Must not contain spaces: [Exchange.fromName] splits
  /// "SwapKit (Chainflip)" on the first space.
  static const exchangeName = "SwapKit";

  @override
  String get name => exchangeName;

  /// `/v3/swap` requires a `sourceAddress` on the sell chain, and refunds go to
  /// it, so the refund address is mandatory for SwapKit trades.
  @override
  bool get supportsRefundAddress => true;

  /// Memo routes are filtered out (see [SwapKitAPI.supportedTxHints]) and
  /// SwapKit has no separate payout memo field.
  @override
  bool get supportsExtraId => false;

  // ===========================================================================
  // Asset mapping

  /// SwapKit chain code -> network string stored on [Currency.network].
  ///
  /// The network is also the "fuzzy net" used to group the same asset across
  /// providers (see [Currency.getFuzzyNet]), so values follow the lowercase
  /// network names the other providers (ChangeNOW, Exolix, ...) use.
  static const Map<String, String> _chainToNetwork = {
    "BTC": "btc",
    "BCH": "bch",
    "LTC": "ltc",
    "DOGE": "doge",
    "DASH": "dash",
    "ZEC": "zec",
    "ETH": "eth",
    "ARB": "arbitrum",
    "BASE": "base",
    "OP": "op",
    "POL": "matic",
    "AVAX": "avaxc",
    "BSC": "bsc",
    "GNO": "xdai",
    "SOL": "sol",
    "TRON": "trx",
    "XRP": "xrp",
    "XLM": "xlm",
    "ADA": "ada",
    "TON": "ton",
    "SUI": "sui",
    "NEAR": "near",
    "GAIA": "atom",
    "THOR": "rune",
    "MAYA": "cacao",
    "KUJI": "kuji",
    "DOT": "dot",
  };

  /// SwapKit chain code -> chainId expected by `POST /track`.
  static const Map<String, String> _chainToTrackChainId = {
    "BTC": "bitcoin",
    "BCH": "bitcoincash",
    "LTC": "litecoin",
    "DOGE": "dogecoin",
    "DASH": "dash",
    "ZEC": "zcash",
    "ETH": "1",
    "ARB": "42161",
    "BASE": "8453",
    "OP": "10",
    "POL": "137",
    "AVAX": "43114",
    "BSC": "56",
    "GNO": "100",
    "SOL": "solana",
    "TRON": "728126428",
    "XRP": "ripple",
    "XLM": "stellar",
    "ADA": "cardano",
    "TON": "ton",
    "SUI": "sui",
    "NEAR": "near",
    "GAIA": "cosmoshub-4",
    "THOR": "thorchain-1",
    "MAYA": "mayachain-mainnet-v1",
    "KUJI": "kaiyo-1",
  };

  static String _networkForChain(String chain) =>
      _chainToNetwork[chain.toUpperCase()] ?? chain.toLowerCase();

  /// Chain code is the part of the identifier before the first '.'.
  static String _chainOf(String identifier) => identifier.split(".").first;

  static String _key(String ticker, String? network) =>
      "${ticker.toLowerCase()}|${(network ?? "").toLowerCase()}";

  /// ticker|network -> SwapKit identifier. Filled by [getAllCurrencies] and
  /// lazily from the Isar exchange cache after an app restart.
  final Map<String, String> _identifiers = {};

  /// ticker|network (sell side) -> min amount last reported by SwapKit.
  final Map<String, Decimal> _lastReportedMin = {};

  Future<String> _identifierFor(String ticker, String? network) async {
    final key = _key(ticker, network);
    final cached = _identifiers[key];
    if (cached != null) return cached;

    final isar = await ExchangeDataLoadingService.instance.isar;
    final currency = await isar.currencies
        .filter()
        .exchangeNameEqualTo(exchangeName)
        .and()
        .tickerEqualTo(ticker, caseSensitive: false)
        .and()
        .networkEqualTo(network ?? "", caseSensitive: false)
        .findFirst();

    final identifier = currency?.externalId;
    if (identifier == null) {
      throw ExchangeException(
        "SwapKit does not support $ticker on ${network ?? "?"}",
        ExchangeExceptionType.generic,
      );
    }
    _identifiers[key] = identifier;
    return identifier;
  }

  /// Keep the list to assets that matter for Stack Wallet instead of all
  /// ~6000 SwapKit tokens: every gas asset, every stablecoin, and ERC-20s on
  /// Ethereum that have a CoinGecko listing (Stack supports ERC-20 tokens).
  static bool _include(SkToken t) =>
      t.isGasAsset ||
      t.isStablecoin ||
      (t.chain.toUpperCase() == "ETH" && t.coingeckoId != null);

  // ===========================================================================
  // Exchange API

  @override
  Future<ExchangeResponse<List<Currency>>> getAllCurrencies(
    bool fixedRate,
  ) async {
    try {
      if (fixedRate) {
        throw ExchangeException(
          "SwapKit does not support fixed rate",
          ExchangeExceptionType.generic,
        );
      }

      final tokens = await SwapKitAPI.getTokens();

      // Prefer listed tokens when several share ticker + network, so a
      // ticker|network pair always resolves to exactly one identifier.
      tokens.sort((a, b) {
        if (a.isGasAsset != b.isGasAsset) return a.isGasAsset ? -1 : 1;
        final aListed = a.coingeckoId != null;
        final bListed = b.coingeckoId != null;
        if (aListed != bListed) return aListed ? -1 : 1;
        return 0;
      });

      final Map<String, Currency> byKey = {};
      for (final t in tokens.where(_include)) {
        final network = _networkForChain(t.chain);
        final key = _key(t.ticker, network);
        if (byKey.containsKey(key)) continue;

        byKey[key] = Currency(
          exchangeName: exchangeName,
          ticker: t.ticker.toUpperCase(),
          name: t.name,
          network: network,
          image: t.logoURI ?? "",
          externalId: t.identifier,
          isFiat: false,
          rateType: SupportedRateType.estimated,
          isAvailable: true,
          // a token on another chain (e.g. ETH on Arbitrum) is not the coin
          isStackCoin: t.isGasAsset && AppConfig.isStackCoin(t.ticker),
          tokenContract: t.address,
        );
        _identifiers[key] = t.identifier;
      }

      return ExchangeResponse(value: byKey.values.toList());
    } on ExchangeException catch (e) {
      return ExchangeResponse(exception: e);
    } catch (e) {
      return ExchangeResponse(
        exception: ExchangeException(
          e.toString(),
          ExchangeExceptionType.generic,
        ),
      );
    }
  }

  /// SwapKit has no range endpoint. Providers report a minimum only when they
  /// decline a quote, so return the last minimum seen for this sell asset, if
  /// any, instead of spending a rate-limited quote call here.
  @override
  Future<ExchangeResponse<Range>> getRange(
    String from,
    String? fromNetwork,
    String to,
    String? toNetwork,
    bool fixedRate,
  ) async {
    if (fixedRate) {
      return ExchangeResponse(
        exception: ExchangeException(
          "SwapKit does not support fixed rate",
          ExchangeExceptionType.generic,
        ),
      );
    }
    return ExchangeResponse(
      value: Range(min: _lastReportedMin[_key(from, fromNetwork)]),
    );
  }

  @override
  Future<ExchangeResponse<List<Estimate>>> getEstimates(
    String from,
    String? fromNetwork,
    String to,
    String? toNetwork,
    Decimal amount,
    bool fixedRate,
    bool reversed,
  ) async {
    try {
      if (fixedRate) {
        throw ExchangeException(
          "SwapKit does not support fixed rate",
          ExchangeExceptionType.generic,
        );
      }
      if (reversed) {
        // EXACT_OUTPUT exists but only NEAR/Flashnet serve it; not exposed yet.
        throw ExchangeException(
          "SwapKit does not support reversed estimates",
          ExchangeExceptionType.generic,
        );
      }

      final quote = await _quote(from, fromNetwork, to, toNetwork, amount);

      final estimates = _bestRoutePerProvider(quote.routes)
          .map(
            (r) => Estimate(
              estimatedAmount: r.expectedBuyAmount,
              fixedRate: false,
              reversed: false,
              exchangeProvider: _displayName(r),
              rateId: r.routeId,
              warningMessage: r.warnings.isEmpty ? null : r.warnings.join("\n"),
            ),
          )
          .toList();

      if (estimates.isEmpty) {
        final min = quote.reportedMinAmount;
        throw ExchangeException(
          min != null && amount < min
              ? "Amount too small. Minimum is $min ${from.toUpperCase()}"
              : "No SwapKit routes available for this pair",
          ExchangeExceptionType.orderNotFound,
        );
      }

      return ExchangeResponse(value: estimates);
    } on ExchangeException catch (e) {
      return ExchangeResponse(exception: e);
    } catch (e) {
      return ExchangeResponse(
        exception: ExchangeException(
          e.toString(),
          ExchangeExceptionType.generic,
        ),
      );
    }
  }

  @override
  Future<ExchangeResponse<Trade>> createTrade({
    required String from,
    required String to,
    required String? fromNetwork,
    required String? toNetwork,
    required bool fixedRate,
    required Decimal amount,
    required String addressTo,
    String? extraId,
    required String addressRefund,
    required String refundExtraId,
    Estimate? estimate,
    required bool reversed,
  }) async {
    try {
      if (fixedRate) {
        throw ExchangeException(
          "SwapKit does not support fixed rate",
          ExchangeExceptionType.generic,
        );
      }
      if (reversed) {
        throw ExchangeException(
          "SwapKit does not support reversed trades",
          ExchangeExceptionType.generic,
        );
      }
      if (extraId?.isNotEmpty == true || refundExtraId.isNotEmpty) {
        throw ExchangeException(
          "SwapKit does not support destination or refund memos",
          ExchangeExceptionType.generic,
        );
      }
      if (addressRefund.isEmpty) {
        throw ExchangeException(
          "SwapKit requires a refund address on the sending chain",
          ExchangeExceptionType.generic,
        );
      }

      final providerName = estimate?.exchangeProvider;

      SkSwap swap;
      try {
        final routeId =
            estimate?.rateId ??
            (await _requoteRoute(
              from,
              fromNetwork,
              to,
              toNetwork,
              amount,
              providerName,
            )).routeId;
        swap = await _swap(routeId, addressRefund, addressTo);
      } on SwapKitApiException catch (e) {
        // routeIds are cached for ~5 minutes; re-quote once if it expired.
        if (e.errorCode != "swapRouteNotFound") rethrow;
        final route = await _requoteRoute(
          from,
          fromNetwork,
          to,
          toNetwork,
          amount,
          providerName,
        );
        swap = await _swap(route.routeId, addressRefund, addressTo);
      }

      // Defensive: we only ask for simpleTransfer routes. A memo we cannot
      // attach would mean funds are not credited to this swap.
      if (swap.memo != null ||
          (swap.txHint ?? "simpleTransfer") != "simpleTransfer") {
        throw ExchangeException(
          "SwapKit returned a route that needs a memo/contract call, "
          "which Stack Wallet cannot send",
          ExchangeExceptionType.generic,
        );
      }

      final sellIdentifier = await _identifierFor(from, fromNetwork);
      final info = _SkTradeInfo(
        routeId: swap.routeId,
        depositChannelId: swap.depositChannelId,
        depositAddress: swap.depositAddress,
        sellChainId: _chainToTrackChainId[_chainOf(sellIdentifier)],
        providers: swap.providers,
        depositDeadline: swap.depositChannelExpiration,
      );

      final provider = providerName ?? _displayNameForProviders(swap.providers);

      return ExchangeResponse(
        value: Trade(
          uuid: const Uuid().v1(),
          tradeId: swap.swapId,
          rateType: "estimated",
          direction: "direct",
          timestamp: swap.createdAt,
          updatedAt: swap.createdAt,
          payInCurrency: from.toUpperCase(),
          payInAmount: swap.sellAmount.toString(),
          payInAddress: swap.depositAddress,
          payInNetwork: fromNetwork ?? "",
          payInExtraId: "",
          payInTxid: "",
          payOutCurrency: to.toUpperCase(),
          payOutAmount: swap.expectedBuyAmount.toString(),
          payOutAddress: swap.destinationAddress.isNotEmpty
              ? swap.destinationAddress
              : addressTo,
          payOutNetwork: toNetwork ?? "",
          payOutExtraId: "",
          payOutTxid: "",
          refundAddress: addressRefund,
          refundExtraId: "",
          status: "Waiting",
          exchangeName: "$exchangeName ($provider)",
          other: info.toJsonString(),
        ),
      );
    } on ExchangeException catch (e) {
      return ExchangeResponse(exception: e);
    } catch (e) {
      return ExchangeResponse(
        exception: ExchangeException(
          e.toString(),
          ExchangeExceptionType.generic,
        ),
      );
    }
  }

  /// SwapKit cannot look a swap up by swapId; status is tracked via
  /// [updateTrade] using the deposit tx hash / deposit channel instead.
  @override
  Future<ExchangeResponse<Trade>> getTrade(String tradeId) async {
    return ExchangeResponse(
      exception: ExchangeException(
        "SwapKit does not support trade lookup by id",
        ExchangeExceptionType.generic,
      ),
    );
  }

  @override
  Future<ExchangeResponse<List<Trade>>> getTrades() async {
    return ExchangeResponse(
      exception: ExchangeException(
        "SwapKit does not provide a trade history endpoint",
        ExchangeExceptionType.generic,
      ),
    );
  }

  @override
  Future<ExchangeResponse<Trade>> updateTrade(Trade trade) async {
    try {
      final info = _SkTradeInfo.tryParse(trade.other);

      // The deposit tx hash is the most reliable tracking key. Use the one we
      // already know, or the txid recorded when the user sent from Stack.
      String? hash = trade.payInTxid.isNotEmpty ? trade.payInTxid : null;
      hash ??= TradeSentFromStackService().getTxidForTradeId(trade.tradeId);

      final SkTrack t;
      try {
        t = await SwapKitAPI.track(
          hash: info?.sellChainId != null ? hash : null,
          chainId: info?.sellChainId,
          depositChannelId: info?.depositChannelId,
          depositAddress: info?.depositAddress ?? trade.payInAddress,
          routeId: info?.routeId,
        );
      } on SwapKitApiException catch (e) {
        // Right after broadcast /track often 404s; nothing deposited yet is
        // also a 404. Keep the trade waiting until the deposit deadline.
        if (e.httpCode == 404) {
          return ExchangeResponse(
            value: trade.copyWith(
              updatedAt: DateTime.now(),
              status: _mapStatus("not_started", info?.depositDeadline),
            ),
          );
        }
        rethrow;
      }

      final status = _mapStatus(t.status, info?.depositDeadline);

      return ExchangeResponse(
        value: trade.copyWith(
          updatedAt: DateTime.now(),
          payInTxid: t.hash ?? trade.payInTxid,
          payOutAmount: status == "Finished" && t.toAmount != null
              ? t.toAmount
              : trade.payOutAmount,
          payOutTxid: t.outboundHash ?? trade.payOutTxid,
          status: status,
        ),
      );
    } on ExchangeException catch (e) {
      return ExchangeResponse(exception: e);
    } catch (e) {
      return ExchangeResponse(
        exception: ExchangeException(
          e.toString(),
          ExchangeExceptionType.generic,
        ),
      );
    }
  }

  // ===========================================================================
  // helpers

  Future<SkQuote> _quote(
    String from,
    String? fromNetwork,
    String to,
    String? toNetwork,
    Decimal amount,
  ) async {
    final sellAsset = await _identifierFor(from, fromNetwork);
    final buyAsset = await _identifierFor(to, toNetwork);

    final SkQuote quote;
    try {
      quote = await SwapKitAPI.getQuote(
        sellAsset: sellAsset,
        buyAsset: buyAsset,
        sellAmount: amount,
      );
    } on SwapKitApiException catch (e) {
      if (e.errorCode == "noRoutesFound") {
        throw ExchangeException(
          "No SwapKit routes available for this pair",
          ExchangeExceptionType.orderNotFound,
        );
      }
      rethrow;
    }

    final min = quote.reportedMinAmount;
    if (min != null) {
      _lastReportedMin[_key(from, fromNetwork)] = min;
    }
    return quote;
  }

  Future<SkRoute> _requoteRoute(
    String from,
    String? fromNetwork,
    String to,
    String? toNetwork,
    Decimal amount,
    String? preferredProvider,
  ) async {
    final quote = await _quote(from, fromNetwork, to, toNetwork, amount);
    final routes = _bestRoutePerProvider(quote.routes);
    if (routes.isEmpty) {
      throw ExchangeException(
        "No SwapKit routes available for this pair",
        ExchangeExceptionType.orderNotFound,
      );
    }
    return routes.firstWhere(
      (r) => _displayName(r) == preferredProvider,
      orElse: () => routes.first,
    );
  }

  Future<SkSwap> _swap(String routeId, String source, String destination) =>
      SwapKitAPI.createSwap(
        routeId: routeId,
        sourceAddress: source,
        destinationAddress: destination,
        refundAddress: source,
      );

  /// One route per provider combination (the estimate's name is the UI's
  /// selection key), best output first.
  static List<SkRoute> _bestRoutePerProvider(List<SkRoute> routes) {
    final Map<String, SkRoute> best = {};
    for (final r in routes) {
      if ((r.txHint ?? "simpleTransfer") != "simpleTransfer") continue;
      if (r.expectedBuyAmount <= Decimal.zero) continue;
      final existing = best[r.providerKey];
      if (existing == null ||
          r.expectedBuyAmount > existing.expectedBuyAmount) {
        best[r.providerKey] = r;
      }
    }
    return best.values.toList()
      ..sort((a, b) => b.expectedBuyAmount.compareTo(a.expectedBuyAmount));
  }

  static const Map<String, String> _providerNames = {
    "CHAINFLIP": "Chainflip",
    "CHAINFLIP_STREAMING": "Chainflip",
    "THORCHAIN": "THORChain",
    "THORCHAIN_STREAMING": "THORChain",
    "MAYACHAIN": "Maya",
    "MAYACHAIN_STREAMING": "Maya",
    "NEAR": "NEAR Intents",
    "FLASHNET": "Flashnet",
    "GARDEN": "Garden",
    "HARBOR": "Harbor",
    "MAYAN": "Mayan",
    "RELAY": "Relay",
    "PACTSWAP": "PactSwap",
    "ONEINCH": "1inch",
    "JUPITER": "Jupiter",
    "OKX": "OKX",
    "UNISWAP_V2": "Uniswap",
    "UNISWAP_V3": "Uniswap",
    "SUSHISWAP_V2": "SushiSwap",
    "PANCAKESWAP": "PancakeSwap",
    "TRADERJOE_V2": "Trader Joe",
  };

  static String _displayNameForProviders(List<String> providers) {
    final names = <String>[];
    for (final p in providers) {
      final n = _providerNames[p] ?? p;
      if (!names.contains(n)) names.add(n);
    }
    return names.isEmpty ? exchangeName : names.join(" + ");
  }

  /// Streaming and non-streaming variants share a display name, so append
  /// the variant to keep estimate names (the UI's selection key) unique.
  static String _displayName(SkRoute r) {
    final base = _displayNameForProviders(r.providers);
    return r.providers.any((p) => p.endsWith("_STREAMING"))
        ? "$base streaming"
        : base;
  }

  /// Map SwapKit `/track` statuses to the ChangeNOW style strings the trade
  /// UI and notification service already understand.
  static String _mapStatus(String status, DateTime? depositDeadline) {
    switch (status) {
      case "not_started":
        if (depositDeadline != null &&
            DateTime.now().toUtc().isAfter(depositDeadline)) {
          return "expired";
        }
        return "Waiting";
      case "pending":
        return "Confirming";
      case "swapping":
        return "Exchanging";
      case "completed":
        return "Finished";
      case "refunded":
        return "Refunded";
      case "failed":
        return "Failed";
      default:
        return "Waiting";
    }
  }
}

/// Tracking data persisted in [Trade.other] as JSON.
class _SkTradeInfo {
  final String routeId;
  final String? depositChannelId;
  final String? depositAddress;
  final String? sellChainId;
  final List<String> providers;
  final DateTime? depositDeadline;

  _SkTradeInfo({
    required this.routeId,
    required this.depositChannelId,
    required this.depositAddress,
    required this.sellChainId,
    required this.providers,
    required this.depositDeadline,
  });

  String toJsonString() => jsonEncode({
    "swapkit": 1,
    "routeId": routeId,
    "depositChannelId": depositChannelId,
    "depositAddress": depositAddress,
    "sellChainId": sellChainId,
    "providers": providers,
    "depositDeadline": depositDeadline?.millisecondsSinceEpoch,
  });

  static _SkTradeInfo? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = jsonDecode(source);
      if (map is! Map || map["swapkit"] == null) return null;
      final deadline = map["depositDeadline"];
      return _SkTradeInfo(
        routeId: map["routeId"] as String,
        depositChannelId: map["depositChannelId"] as String?,
        depositAddress: map["depositAddress"] as String?,
        sellChainId: map["sellChainId"] as String?,
        providers: (map["providers"] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        depositDeadline: deadline is int
            ? DateTime.fromMillisecondsSinceEpoch(deadline, isUtc: true)
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
