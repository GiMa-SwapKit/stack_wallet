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
import '../../../db/isar/main_db.dart';
import '../../../exceptions/exchange/exchange_exception.dart';
import '../../../models/exchange/response_objects/estimate.dart';
import '../../../models/exchange/response_objects/range.dart';
import '../../../models/exchange/response_objects/trade.dart';
import '../../../models/isar/exchange_cache/currency.dart';
import '../../../models/isar/exchange_cache/pair.dart';
import '../../../models/isar/models/isar_models.dart';
import '../../trade_sent_from_stack_service.dart';
import '../exchange.dart';
import '../exchange_data_loading_service.dart';
import '../exchange_response.dart';
import 'response_objects/sk_quote.dart';
import 'response_objects/sk_swap.dart';
import 'response_objects/sk_token.dart';
import 'response_objects/sk_track.dart';
import 'swapkit_api.dart';
import 'swapkit_trade_info.dart';

/// SwapKit (https://swapkit.dev) cross-chain swap aggregator.
///
/// SwapKit routes a swap through one of several providers (Chainflip, NEAR
/// Intents, THORChain, Maya, ...). Each route is shown in the provider list as
/// its own estimate, like Trocador's partners, e.g. "SwapKit (Chainflip)".
///
/// Routes that are a plain transfer to a deposit address work like any other
/// provider: the user can pay from any wallet. Memo routes (THORChain, Maya,
/// Harbor, ...), Chainflip vault swaps (a PSBT SwapKit builds) and EVM
/// contract calls are offered where a Stack wallet can send them, and are
/// paid with "Send from Stack" (see [SwapKitExecution]).
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

  /// SwapKit has no payout (destination) memo field. Deposit memos are
  /// attached by "Send from Stack", see [SwapKitExecution.memo].
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
  };

  /// Chains SwapKit's /tokens still lists but that SwapKit no longer swaps.
  static const Set<String> _unsupportedChains = {"DOT"};

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

  /// routeId -> route of the latest quote, so [createTrade] knows the route
  /// kind of the estimate the user picked.
  final Map<String, SkRoute> _routes = {};

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
      !_unsupportedChains.contains(t.chain.toUpperCase()) &&
      (t.isGasAsset ||
          t.isStablecoin ||
          (t.chain.toUpperCase() == "ETH" && t.coingeckoId != null));

  /// True only for a chain's own coin, e.g. `BTC.BTC` or `ETH.ETH`, not for
  /// ETH as the gas asset of Arbitrum, Base or Optimism.
  static bool _isNativeCoin(SkToken t) =>
      t.isGasAsset && _networkForChain(t.chain) == t.ticker.toLowerCase();

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
          isStackCoin: _isNativeCoin(t) && AppConfig.isStackCoin(t.ticker),
          tokenContract: t.contractAddress,
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
              warningMessage: _warningFor(r),
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
      final sellIdentifier = await _identifierFor(from, fromNetwork);
      final sellChain = _chainOf(sellIdentifier).toUpperCase();

      Future<SkRoute> requote() =>
          _requoteRoute(from, fromNetwork, to, toNetwork, amount, providerName);

      SkRoute route =
          (estimate?.rateId == null ? null : _routes[estimate!.rateId]) ??
          await requote();

      ({SkSwap swap, SwapKitExecution execution}) created;
      try {
        try {
          created = await _createSwapFor(
            route: route,
            sellChain: sellChain,
            refundAddress: addressRefund,
            destinationAddress: addressTo,
          );
        } on SwapKitApiException catch (e) {
          // routeIds are cached for ~5 minutes; re-quote once if it expired.
          if (e.errorCode != "swapRouteNotFound") rethrow;
          route = await requote();
          created = await _createSwapFor(
            route: route,
            sellChain: sellChain,
            refundAddress: addressRefund,
            destinationAddress: addressTo,
          );
        }
      } on SwapKitApiException catch (e) {
        if (e.errorCode == "insufficientBalance") {
          throw ExchangeException(
            "The wallet you are swapping from does not hold enough "
            "${from.toUpperCase()} (and network fee) for this swap",
            ExchangeExceptionType.generic,
          );
        }
        rethrow;
      }
      final swap = created.swap;
      final execution = created.execution;

      final info = SwapKitTradeInfo(
        routeId: swap.routeId,
        depositChannelId: swap.depositChannelId,
        // a plain transfer's deposit address belongs to this swap; a memo
        // vault or router is shared by every user of the provider, so it
        // must not be used to look this swap up
        depositAddress:
            route.txHint == null || route.txHint == SwapKitAPI.hintTransfer
            ? swap.depositAddress
            : null,
        routeHint: route.txHint ?? SwapKitAPI.hintTransfer,
        sellChainId: _chainToTrackChainId[sellChain],
        providers: swap.providers,
        depositDeadline: swap.depositChannelExpiration,
        execution: execution,
        memo: execution == SwapKitExecution.memo ? swap.memo : null,
        psbt: swap.psbt,
        evmTx: swap.evmTx,
        approvalTx: swap.approvalTx,
        solanaTx: swap.solanaTx,
        sellAsset: sellIdentifier,
        sourceAddress: execution == SwapKitExecution.contractCall
            ? addressRefund
            : null,
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
          // shown with the deposit address, like other providers' memos
          payInExtraId: info.memo ?? "",
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
      final info = SwapKitTradeInfo.tryParse(trade.other);
      final hash = _depositHash(trade);

      // Once a deposit was sent the trade must not expire: a deposit made
      // before the deadline can still be confirming after it.
      final deadline = hash == null ? info?.depositDeadline : null;

      SkTrack? t;

      // 1. The deposit tx hash is the most precise key.
      if (hash != null && info?.sellChainId != null) {
        t = await _trackOrNull(
          () => SwapKitAPI.track(
            hash: hash,
            chainId: info!.sellChainId,
            routeId: info.routeId,
          ),
        );
      }

      // 2. SwapKit answers an unknown or not yet indexed hash with
      // `not_started` (or 404). The deposit channel / address is linked to
      // the swap from the moment it is created, so ask by that as well.
      if (t == null || _isNotStarted(t)) {
        final byDeposit = await _trackOrNull(
          () => SwapKitAPI.track(
            depositChannelId: info?.depositChannelId,
            // older trades have no info: fall back to the pay-in address
            depositAddress: info == null
                ? trade.payInAddress
                : info.depositAddress,
            routeId: info?.routeId,
          ),
        );
        if (byDeposit != null && (t == null || !_isNotStarted(byDeposit))) {
          t = byDeposit;
        }
      }

      if (t == null) {
        return ExchangeResponse(
          value: trade.copyWith(
            updatedAt: DateTime.now(),
            status: _mapStatus("not_started", deadline),
          ),
        );
      }

      final status = _mapStatus(t.status, deadline);

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
        txHints: _txHintsFor(sellAsset),
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
    // routeIds are only valid for ~5 minutes, keep just the latest quote's
    _routes
      ..clear()
      ..addEntries(quote.routes.map((r) => MapEntry(r.routeId, r)));
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

  /// Creates the SwapKit swap for [route] and works out how the user pays it.
  ///
  /// When the refund address belongs to a Stack wallet that can sign
  /// SwapKit's prebuilt transactions (see [_prebuiltChains]), SwapKit always
  /// builds the deposit transaction and that wallet signs it: a PSBT on UTXO
  /// chains, an EVM transaction on Ethereum, a serialised transaction on
  /// Solana. This holds for every route kind, plain transfers included.
  /// Otherwise only routes that need no prebuilt transaction work: plain
  /// deposits (paid from any wallet) and memo routes on [_selfBuiltMemoChains].
  Future<({SkSwap swap, SwapKitExecution execution})> _createSwapFor({
    required SkRoute route,
    required String sellChain,
    required String refundAddress,
    required String destinationAddress,
  }) async {
    final provider = _displayName(route);
    final hint = route.txHint ?? SwapKitAPI.hintTransfer;

    final walletId = _prebuiltChains.contains(sellChain)
        ? await _stackWalletIdOrNull(refundAddress)
        : null;
    if (walletId != null) {
      final isUtxo = _utxoChains.contains(sellChain);
      try {
        final swap = await SwapKitAPI.createSwap(
          routeId: route.routeId,
          // on UTXO chains SwapKit spends from all of the wallet's addresses
          sourceAddress: isUtxo
              ? (await _spendableAddresses(walletId)).join(";")
              : refundAddress,
          destinationAddress: destinationAddress,
          refundAddress: refundAddress,
          buildTx: true,
          checkBalance: isUtxo,
        );
        final execution = isUtxo
            ? (swap.psbt == null ? null : SwapKitExecution.psbt)
            : (sellChain == "SOL" ? swap.solanaTx : swap.evmTx) == null
            ? null
            : SwapKitExecution.contractCall;
        if (execution == null) {
          throw ExchangeException(
            "SwapKit did not return a transaction to sign for $provider",
            ExchangeExceptionType.generic,
          );
        }
        return (swap: swap, execution: execution);
      } on SwapKitApiException catch (e) {
        // A plain deposit can still be paid from another wallet, so do not
        // block it on the refund wallet's balance.
        if (e.errorCode != "insufficientBalance" ||
            hint != SwapKitAPI.hintTransfer) {
          rethrow;
        }
      }
    }

    switch (hint) {
      case SwapKitAPI.hintTransfer:
        final swap = await SwapKitAPI.createSwap(
          routeId: route.routeId,
          sourceAddress: refundAddress,
          destinationAddress: destinationAddress,
          refundAddress: refundAddress,
        );
        if (swap.memo != null) {
          // a memo we do not attach means the deposit is not credited
          throw ExchangeException(
            "SwapKit returned a memo for a plain transfer route",
            ExchangeExceptionType.generic,
          );
        }
        return (swap: swap, execution: SwapKitExecution.deposit);

      case SwapKitAPI.hintMemo when _selfBuiltMemoChains.contains(sellChain):
        final swap = await SwapKitAPI.createSwap(
          routeId: route.routeId,
          sourceAddress: refundAddress,
          destinationAddress: destinationAddress,
          refundAddress: refundAddress,
        );
        final memo = swap.memo;
        if (memo == null) {
          throw ExchangeException(
            "SwapKit returned a memo route without a memo",
            ExchangeExceptionType.generic,
          );
        }
        // Bitcoin Cash memos go in an OP_RETURN, which holds at most 80 bytes
        final memoBytes = memo.startsWith("0x")
            ? (memo.length - 2) ~/ 2
            : utf8.encode(memo).length;
        if (sellChain == "BCH" && memoBytes > 80) {
          throw ExchangeException(
            "$provider's memo ($memoBytes bytes) does not fit in a "
            "${sellChain.toUpperCase()} transaction",
            ExchangeExceptionType.generic,
          );
        }
        return (swap: swap, execution: SwapKitExecution.memo);

      default:
        throw ExchangeException(
          _prebuiltChains.contains(sellChain)
              ? "To swap with $provider, choose one of your "
                    "${AppConfig.appName} ${sellChain.toUpperCase()} wallet's "
                    "addresses as the refund address. The swap is then signed "
                    "and sent from that wallet."
              : "$provider needs a kind of transaction "
                    "${AppConfig.appName} cannot send from "
                    "${sellChain.toUpperCase()}",
          ExchangeExceptionType.generic,
        );
    }
  }

  /// UTXO chains whose wallets sign SwapKit's PSBTs. Bitcoin Cash is not one
  /// of them (FORKID signing), see [_selfBuiltMemoChains].
  static const Set<String> _utxoChains = {"BTC", "LTC", "DOGE", "DASH"};

  /// Sell chains whose Stack wallets sign the transactions SwapKit builds.
  static const Set<String> _prebuiltChains = {..._utxoChains, "ETH", "SOL"};

  /// Sell chains whose Stack wallets add SwapKit's memo to their own
  /// transaction: an OP_RETURN on Bitcoin Cash, a memo on Stellar.
  static const Set<String> _selfBuiltMemoChains = {"BCH", "XLM"};

  /// Route kinds to request when selling [sellIdentifier]: plain transfers
  /// always; memo routes and contract calls where a Stack wallet can send
  /// them.
  static List<String> _txHintsFor(String sellIdentifier) {
    final chain = _chainOf(sellIdentifier).toUpperCase();
    final isChainCoin = !sellIdentifier.contains("-");
    return [
      SwapKitAPI.hintTransfer,
      if (_utxoChains.contains(chain) ||
          chain == "SOL" ||
          (isChainCoin && _selfBuiltMemoChains.contains(chain)))
        SwapKitAPI.hintMemo,
      if (chain == "ETH" || chain == "SOL") SwapKitAPI.hintContractCall,
    ];
  }

  /// walletId of the Stack wallet that owns [address], if any.
  static Future<String?> _stackWalletIdOrNull(String address) async {
    final match = await MainDB.instance.isar.addresses
        .filter()
        .valueEqualTo(address, caseSensitive: false)
        .findFirst();
    return match?.walletId;
  }

  /// Addresses holding the wallet's spendable coins, for SwapKit to build a
  /// PSBT from.
  static Future<List<String>> _spendableAddresses(String walletId) async {
    final utxos = await MainDB.instance.getUTXOs(walletId).findAll();
    final addresses = {
      for (final u in utxos)
        if (!u.isBlocked && u.used != true && u.address != null) u.address!,
    };
    if (addresses.isEmpty) {
      throw ExchangeException(
        "The wallet you are swapping from has no spendable coins",
        ExchangeExceptionType.generic,
      );
    }
    return addresses.toList();
  }

  /// One route per provider combination (the estimate's name is the UI's
  /// selection key), best output first. When a provider offers both, the
  /// plain transfer wins over a memo / contract call route, since it can be
  /// paid from any wallet.
  static List<SkRoute> _bestRoutePerProvider(List<SkRoute> routes) {
    bool isTransfer(SkRoute r) =>
        (r.txHint ?? SwapKitAPI.hintTransfer) == SwapKitAPI.hintTransfer;
    final Map<String, SkRoute> best = {};
    for (final r in routes) {
      if (r.expectedBuyAmount <= Decimal.zero) continue;
      final existing = best[r.providerKey];
      if (existing == null ||
          (isTransfer(r) && !isTransfer(existing)) ||
          (isTransfer(r) == isTransfer(existing) &&
              r.expectedBuyAmount > existing.expectedBuyAmount)) {
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

  static String? _warningFor(SkRoute r) {
    final hint = r.txHint ?? SwapKitAPI.hintTransfer;
    final sellChain = _chainOf(r.sellAsset).toUpperCase();
    final messages = [
      if (hint != SwapKitAPI.hintTransfer)
        "Must be sent with \"Send from ${AppConfig.appName}\" from your "
            "${AppConfig.appName} wallet: this route needs a "
            "${hint == SwapKitAPI.hintContractCall ? "contract call" : "memo"} "
            "that other wallets usually cannot add."
            "${_selfBuiltMemoChains.contains(sellChain) ? "" : " Use that wallet's address as the refund address."}",
      ...r.warnings,
    ];
    return messages.isEmpty ? null : messages.join("\n");
  }

  /// Streaming and non-streaming variants share a display name, so append
  /// the variant to keep estimate names (the UI's selection key) unique.
  static String _displayName(SkRoute r) {
    final base = _displayNameForProviders(r.providers);
    return r.providers.any((p) => p.endsWith("_STREAMING"))
        ? "$base streaming"
        : base;
  }

  /// Link shown under "Tracking" on the trade details page. Deep links to the
  /// deposit transaction on SwapKit's tracker once its hash is known.
  static String trackingUrl(Trade trade) {
    const fallback = "https://track.swapkit.dev";
    final chainId = SwapKitTradeInfo.tryParse(trade.other)?.sellChainId;
    if (chainId == null) return fallback;
    final hash = _depositHash(trade);
    if (hash == null) return fallback;
    return Uri.https("track.swapkit.dev", "/tx/$hash", {
      "chainId": chainId,
    }).toString();
  }

  /// The deposit tx hash SwapKit reported, or the txid recorded when the user
  /// sent the deposit from Stack.
  static String? _depositHash(Trade trade) => trade.payInTxid.isNotEmpty
      ? trade.payInTxid
      : TradeSentFromStackService().getTxidForTradeId(trade.tradeId);

  static bool _isNotStarted(SkTrack t) =>
      t.status == "not_started" || t.status == "unknown";

  /// Runs a `/track` call. Returns null when SwapKit has nothing for that
  /// key yet (404) or there is no key to ask with.
  static Future<SkTrack?> _trackOrNull(Future<SkTrack> Function() call) async {
    try {
      return await call();
    } on ExchangeException catch (e) {
      if (e is SwapKitApiException && e.httpCode == 404) return null;
      if (e.type == ExchangeExceptionType.orderNotFound) return null;
      rethrow;
    }
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
