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

/// How the user pays a SwapKit trade.
enum SwapKitExecution {
  /// Plain transfer to the deposit address, from any wallet.
  deposit,

  /// Transfer to the deposit address carrying [SwapKitTradeInfo.memo]
  /// (OP_RETURN on UTXO chains, a memo on Solana/Stellar). Send from Stack.
  memo,

  /// Sign [SwapKitTradeInfo.psbt], which SwapKit built from the wallet's
  /// coins. Send from Stack.
  psbt,

  /// A call to the provider's contract, sent from the wallet at
  /// [SwapKitTradeInfo.sourceAddress]: [SwapKitTradeInfo.evmTx] (after
  /// [SwapKitTradeInfo.approvalTx], if any) from Ethereum, or
  /// [SwapKitTradeInfo.solanaTx] from Solana. Send from Stack.
  contractCall;

  /// Whether the trade can only be paid with "Send from Stack".
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

  /// Info of a SwapKit [trade], or null for other providers' trades.
  static SwapKitTradeInfo? of(Trade trade) =>
      trade.exchangeName.startsWith("SwapKit") ? tryParse(trade.other) : null;
}
