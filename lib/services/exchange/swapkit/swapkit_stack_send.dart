/*
 * This file is part of Stack Wallet.
 *
 * Copyright (c) 2026 Cypher Stack
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../app_config.dart';
import '../../../models/exchange/response_objects/trade.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../utilities/extensions/extensions.dart';
import '../../../wallets/models/tx_data.dart';
import '../../../wallets/wallet/impl/cardano_wallet.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../wallets/wallet/impl/solana_wallet.dart';
import '../../../wallets/wallet/impl/stellar_wallet.dart';
import '../../../wallets/wallet/wallet.dart';
import '../../../wallets/wallet/wallet_mixin_interfaces/electrumx_interface.dart';
import 'swapkit_trade_info.dart';

/// "Send from Stack" for SwapKit trades: signs the transaction SwapKit built
/// for the wallet (see [SwapKitExecution]). Stack never builds its own
/// transaction for a SwapKit trade.
abstract final class SwapKitStackSend {
  static SwapKitTradeInfo? _info(Trade trade) {
    final info = SwapKitTradeInfo.of(trade);
    return info != null && info.execution.isPrebuilt ? info : null;
  }

  /// Whether "Send from Stack" pays [trade] with SwapKit's prebuilt
  /// transaction through [prepare].
  static bool handles(Trade trade) => _info(trade) != null;

  /// Whether "Send from Stack" may be offered for [trade]. A SwapKit trade
  /// without a prebuilt transaction (refund address outside Stack) is paid
  /// from another wallet instead. Other providers' trades are unaffected.
  static bool sendFromStackAllowed(Trade trade) {
    final info = SwapKitTradeInfo.of(trade);
    return info == null || info.execution.isPrebuilt;
  }

  /// Whether [trade] can only be paid with "Send from Stack": a plain
  /// transfer to the pay-in address would not pay it.
  static bool requiresStackWallet(Trade trade) =>
      _info(trade)?.payableFromAnyWallet == false;

  /// Ticker of the wallet coin [trade] is sent from. Tokens are sent from
  /// their chain's wallet (ERC-20 from Ethereum, SPL from Solana), which owns
  /// them and pays the fee.
  static String walletTicker(Trade trade) => switch (_info(trade)?.execution) {
    SwapKitExecution.evm => "ETH",
    SwapKitExecution.solana => "SOL",
    _ => trade.payInCurrency,
  };

  /// Warning to show next to the pay-in details of [trade], if a plain
  /// transfer to the pay-in address would not pay it.
  static String? manualSendWarning(Trade trade) {
    final info = _info(trade);
    if (info == null || info.payableFromAnyWallet) return null;
    final from = info.sourceAddress == null
        ? "the wallet whose address you gave as refund address"
        : "the wallet ${info.sourceAddress}";
    return "Pay this swap with \"Send from ${AppConfig.appName}\", from "
        "$from. The deposit is a transaction prepared for that wallet; "
        "coins sent to this address any other way are not credited to the "
        "swap.";
  }

  /// Prepares SwapKit's transaction for [trade] in [wallet], ready for the
  /// usual confirm screen. [amount] is the trade's pay-in amount.
  static Future<TxData> prepare({
    required Trade trade,
    required Wallet wallet,
    required Amount amount,
  }) async {
    final info = _info(trade);
    if (info == null) {
      throw StateError("Not a SwapKit trade with a prebuilt transaction");
    }
    final coin = wallet.cryptoCurrency;
    final note =
        "${trade.payInCurrency.toUpperCase()}/"
        "${trade.payOutCurrency.toUpperCase()} exchange";
    final address = trade.payInAddress;

    // account chains: the transaction was built for one address
    final source = info.sourceAddress;
    if (source != null) {
      final myAddress = (await wallet.getCurrentReceivingAddress())!.value;
      // hex (EVM) addresses are case-insensitive, the others are not
      final same = source.startsWith("0x")
          ? myAddress.toLowerCase() == source.toLowerCase()
          : myAddress == source;
      if (!same) {
        throw Exception("Send this swap from the wallet $source");
      }
    }

    TxData toDeposit(Amount value) => TxData(
      recipients: [
        TxRecipient(
          address: address,
          amount: value,
          isChange: false,
          addressType: coin.getAddressType(address)!,
        ),
      ],
      feeRateType: FeeRateType.average,
      note: note,
    );

    switch (info.execution) {
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

      case SwapKitExecution.evm:
        if (wallet is! EthereumWallet) {
          throw Exception("Send this swap from an Ethereum wallet");
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

      case SwapKitExecution.solana:
        if (wallet is! SolanaWallet) {
          throw Exception("Send this swap from a Solana wallet");
        }
        // SOL moved by the transaction; a token swap moves no SOL
        final sellsSol = info.sellAsset == null || info.sellAsset == "SOL.SOL";
        return wallet.prepareSerializedTransaction(
          base64Transaction: info.solanaTx!,
          txData: toDeposit(
            sellsSol
                ? amount
                : Amount.zeroWith(fractionDigits: coin.fractionDigits),
          ),
        );

      case SwapKitExecution.cardano:
        if (wallet is! CardanoWallet) {
          throw Exception("Send this swap from a Cardano wallet");
        }
        return wallet.prepareSerializedTransaction(
          cborHex: info.cardanoTx!,
          txData: toDeposit(amount),
        );

      case SwapKitExecution.stellar:
        if (wallet is! StellarWallet) {
          throw Exception("Send this swap from a Stellar wallet");
        }
        return wallet.prepareSerializedTransaction(
          envelopeXdr: info.stellarTx!,
          txData: toDeposit(amount),
        );

      case SwapKitExecution.deposit:
        throw StateError("Plain deposits are not sent from Stack");
    }
  }

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
