/*
 * This file is part of Stack Wallet.
 *
 * Copyright (c) 2026 Cypher Stack
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:typed_data';

import '../../../app_config.dart';
import '../../../models/exchange/response_objects/trade.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../utilities/extensions/extensions.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/models/tx_data.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../wallets/wallet/wallet.dart';
import '../../../wallets/wallet/wallet_mixin_interfaces/electrumx_interface.dart';
import 'swapkit_trade_info.dart';

/// "Send from Stack" for SwapKit trades that are more than a plain transfer
/// to a deposit address: memo deposits, PSBTs SwapKit built for the wallet,
/// and EVM contract calls (see [SwapKitExecution]).
abstract final class SwapKitStackSend {
  static SwapKitTradeInfo? _info(Trade trade) {
    final info = SwapKitTradeInfo.of(trade);
    return info != null && info.execution.needsStackWallet ? info : null;
  }

  /// Whether [trade] must be paid through [prepare] instead of a plain
  /// transfer to its pay-in address.
  static bool handles(Trade trade) => _info(trade) != null;

  /// Ticker of the wallet coin [trade] is sent from. A contract call (also
  /// for an ERC-20 sell) is sent from an Ethereum wallet.
  static String walletTicker(Trade trade) =>
      _info(trade)?.execution == SwapKitExecution.contractCall
      ? "ETH"
      : trade.payInCurrency;

  /// Warning to show next to the pay-in details of [trade], if a plain
  /// transfer to the pay-in address would not pay it.
  static String? manualSendWarning(Trade trade) {
    final info = _info(trade);
    if (info == null) return null;
    final send = "Pay this swap with \"Send from ${AppConfig.appName}\"";
    return switch (info.execution) {
      SwapKitExecution.memo =>
        "$send. The deposit must carry the memo shown; a transfer without "
            "it is not credited to the swap.",
      SwapKitExecution.psbt =>
        "$send, from the wallet whose address you gave as refund address. "
            "The deposit is a transaction prepared for that wallet's coins; "
            "do not send to this address from another wallet.",
      SwapKitExecution.contractCall =>
        "$send, from the Ethereum wallet ${info.sourceAddress ?? ""}. "
            "The deposit is a call to the provider's contract; do not send "
            "coins to this address directly.",
      SwapKitExecution.deposit => null,
    };
  }

  /// Builds the transaction paying [trade] from [wallet], ready for the
  /// usual confirm screen. [amount] is the trade's pay-in amount.
  static Future<TxData> prepare({
    required Trade trade,
    required Wallet wallet,
    required Amount amount,
  }) async {
    final info = _info(trade);
    if (info == null) {
      throw StateError("Not a SwapKit Send from Stack trade");
    }
    final coin = wallet.cryptoCurrency;
    final note =
        "${trade.payInCurrency.toUpperCase()}/"
        "${trade.payOutCurrency.toUpperCase()} exchange";
    final address = trade.payInAddress;

    switch (info.execution) {
      case SwapKitExecution.memo:
        final recipient = TxRecipient(
          address: address,
          amount: amount,
          isChange: false,
          addressType: coin.getAddressType(address)!,
        );
        if (wallet is ElectrumXInterface) {
          return wallet.prepareSend(
            txData: TxData(
              recipients: [recipient],
              opReturnData: memoToOpReturnHex(info.memo!),
              feeRateType: FeeRateType.average,
              note: note,
            ),
          );
        }
        if (coin is Solana || coin is Stellar) {
          return wallet.prepareSend(
            txData: TxData(
              recipients: [recipient],
              memo: info.memo,
              feeRateType: FeeRateType.average,
              note: note,
            ),
          );
        }
        throw Exception("${coin.prettyName} wallets cannot send a swap memo");

      case SwapKitExecution.psbt:
        if (wallet is! ElectrumXInterface) {
          throw Exception(
            "Send this swap from a ${trade.payInCurrency} wallet",
          );
        }
        final txData = await wallet.prepareSendPsbt(
          psbtBase64: info.psbt!,
          recipientAddress: address,
          txData: TxData(note: note),
        );
        checkPsbtPayment(
          paid: txData.recipients!.first.amount,
          fee: txData.fee!,
          expected: amount,
        );
        return txData;

      case SwapKitExecution.contractCall:
        if (wallet is! EthereumWallet) {
          throw Exception("Send this swap from an Ethereum wallet");
        }
        final myAddress = (await wallet.getCurrentReceivingAddress())!.value;
        final source = info.sourceAddress;
        if (source != null && myAddress.toLowerCase() != source.toLowerCase()) {
          throw Exception("Send this swap from the Ethereum wallet $source");
        }
        final call = info.evmTx!;
        final approval = info.approvalTx;
        return wallet.prepareContractCall(
          txData: TxData(
            recipients: [
              TxRecipient(
                address: call.to,
                amount: Amount(
                  rawValue: call.value,
                  fractionDigits: coin.fractionDigits,
                ),
                isChange: false,
                addressType: coin.getAddressType(call.to)!,
              ),
            ],
            feeRateType: FeeRateType.average,
            note: note,
          ),
          data: call.data.toUint8ListFromHex,
          gasLimit: call.gasLimit,
          approval: approval == null
              ? null
              : (
                  to: approval.to,
                  data: approval.data.toUint8ListFromHex,
                  gasLimit: approval.gasLimit,
                ),
        );

      case SwapKitExecution.deposit:
        throw StateError("Plain deposits use the normal send flow");
    }
  }

  /// OP_RETURN payload of a swap memo: `0x…` memos are raw bytes (Chainflip
  /// vault swap parameters), others are text (THORChain, Maya, Harbor).
  static String memoToOpReturnHex(String memo) => memo.startsWith("0x")
      ? memo.substring(2).toLowerCase()
      : Uint8List.fromList(utf8.encode(memo)).toHex;

  /// A PSBT must pay exactly the swap amount to the deposit address, and its
  /// network fee must stay sane (at most 10% of the amount).
  static void checkPsbtPayment({
    required Amount paid,
    required Amount fee,
    required Amount expected,
  }) {
    if (paid.raw != expected.raw) {
      throw Exception(
        "The prepared transaction pays ${paid.decimal} instead of "
        "${expected.decimal} to the swap",
      );
    }
    if (fee.raw * BigInt.from(10) > expected.raw) {
      throw Exception(
        "The prepared transaction's network fee (${fee.decimal}) is more "
        "than 10% of the swap amount",
      );
    }
  }
}
