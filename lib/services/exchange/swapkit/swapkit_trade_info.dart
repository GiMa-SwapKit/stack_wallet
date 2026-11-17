/*
 * This file is part of Stack Wallet.
 *
 * Copyright (c) 2026 Cypher Stack
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import '../../../models/exchange/response_objects/trade.dart';
import 'response_objects/sk_swap.dart';

/// How "Send from Stack" pays a SwapKit trade.
enum SwapKitExecution {
  /// Plain transfer to the deposit address, built by the wallet as usual.
  deposit,

  /// The wallet's own transfer carrying [SwapKitTradeInfo.memo] (an
  /// OP_RETURN on Bitcoin Cash, a memo on Stellar).
  memo,

  /// Sign [SwapKitTradeInfo.psbt], which SwapKit built from the wallet's
  /// coins (any route on BTC, LTC, DOGE, DASH).
  psbt,

  /// Sign the transaction SwapKit built for the wallet at
  /// [SwapKitTradeInfo.sourceAddress]: [SwapKitTradeInfo.evmTx] (after
  /// [SwapKitTradeInfo.approvalTx], if any) on Ethereum, or
  /// [SwapKitTradeInfo.solanaTx] on Solana. Any route kind, from a plain
  /// transfer to a contract call.
  contractCall;

  /// Whether Send from Stack pays the trade with SwapKit's data instead of a
  /// plain transfer to the pay-in address.
  bool get needsStackWallet => this != deposit;
}

/// SwapKit data kept in [Trade.other] as JSON, so the Hive trade model does
/// not change.
class SwapKitTradeInfo {
  final String routeId;
  final String? depositChannelId;
  final String? depositAddress;
  final String? sellChainId;
  final List<String> providers;
  final DateTime? depositDeadline;

  final SwapKitExecution execution;

  /// The route's `txHint`. Only a plain transfer (`simpleTransfer`) can also
  /// be paid from another wallet.
  final String? routeHint;
  final String? memo;
  final String? psbt;
  final SkEvmTx? evmTx;
  final SkEvmTx? approvalTx;
  final String? solanaTx;

  /// SwapKit identifier of the asset sold, e.g. `SOL.SOL` or
  /// `SOL.USDC-EPjF…`.
  final String? sellAsset;

  /// Address the swap was created for (the sending wallet's address for
  /// contract calls).
  final String? sourceAddress;

  SwapKitTradeInfo({
    required this.routeId,
    required this.depositChannelId,
    required this.depositAddress,
    required this.sellChainId,
    required this.providers,
    required this.depositDeadline,
    this.execution = SwapKitExecution.deposit,
    this.routeHint,
    this.memo,
    this.psbt,
    this.evmTx,
    this.approvalTx,
    this.solanaTx,
    this.sellAsset,
    this.sourceAddress,
  });

  String toJsonString() => jsonEncode({
    "swapkit": 1,
    "routeId": routeId,
    "depositChannelId": depositChannelId,
    "depositAddress": depositAddress,
    "sellChainId": sellChainId,
    "providers": providers,
    "depositDeadline": depositDeadline?.millisecondsSinceEpoch,
    "execution": execution.name,
    if (routeHint != null) "routeHint": routeHint,
    if (memo != null) "memo": memo,
    if (psbt != null) "psbt": psbt,
    if (evmTx != null) "evmTx": evmTx!.toMap(),
    if (approvalTx != null) "approvalTx": approvalTx!.toMap(),
    if (solanaTx != null) "solanaTx": solanaTx,
    if (sellAsset != null) "sellAsset": sellAsset,
    if (sourceAddress != null) "sourceAddress": sourceAddress,
  });

  static SwapKitTradeInfo? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = jsonDecode(source);
      if (map is! Map || map["swapkit"] == null) return null;
      final deadline = map["depositDeadline"];
      return SwapKitTradeInfo(
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
        execution: SwapKitExecution.values.firstWhere(
          (e) => e.name == map["execution"],
          orElse: () => SwapKitExecution.deposit,
        ),
        routeHint: map["routeHint"] as String?,
        memo: map["memo"] as String?,
        psbt: map["psbt"] as String?,
        evmTx: SkEvmTx.tryParse(map["evmTx"]),
        approvalTx: SkEvmTx.tryParse(map["approvalTx"]),
        solanaTx: map["solanaTx"] as String?,
        sellAsset: map["sellAsset"] as String?,
        sourceAddress: map["sourceAddress"] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether any wallet can pay the trade with a plain transfer to its
  /// pay-in address (trades from before route kinds were stored: when they
  /// were plain deposits).
  bool get payableFromAnyWallet => routeHint == null
      ? execution == SwapKitExecution.deposit
      : routeHint == "simpleTransfer";

  /// Info of a SwapKit [trade], or null for other providers' trades.
  static SwapKitTradeInfo? of(Trade trade) =>
      trade.exchangeName.startsWith("SwapKit") ? tryParse(trade.other) : null;
}
