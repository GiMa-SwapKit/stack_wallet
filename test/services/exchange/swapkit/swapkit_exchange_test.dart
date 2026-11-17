import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/exchange/response_objects/estimate.dart';
import 'package:stackwallet/models/exchange/response_objects/trade.dart';
import 'package:stackwallet/services/exchange/exchange.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_quote.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_swap.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_token.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_track.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_api.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_exchange.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_stack_send.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_trade_info.dart';
import 'package:stackwallet/utilities/amount/amount.dart';

void main() {
  group("SwapKitExchange", () {
    test("is resolvable by name, including provider suffix", () {
      expect(Exchange.fromName("SwapKit"), same(SwapKitExchange.instance));
      expect(
        Exchange.fromName("SwapKit (NEAR Intents)"),
        same(SwapKitExchange.instance),
      );
    });

    test("needs a refund address and no extra id", () {
      expect(SwapKitExchange.instance.supportsRefundAddress, isTrue);
      expect(SwapKitExchange.instance.supportsExtraId, isFalse);
    });

    test("sells only assets Stack can send, buys any listed asset", () {
      for (final id in [
        "BTC.BTC",
        "BCH.BCH",
        "LTC.LTC",
        "DOGE.DOGE",
        "DASH.DASH",
        "ADA.ADA",
        "XLM.XLM",
        "ETH.ETH",
        "ETH.USDC-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "SOL.SOL",
        "SOL.USDC-EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      ]) {
        expect(SwapKitExchange.canSell(id), isTrue, reason: id);
      }
      for (final id in [
        "TRON.TRX",
        "XRP.XRP",
        "BSC.BNB",
        "ARB.ETH",
        "BASE.USDC-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        "XLM.USDC-GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
      ]) {
        expect(SwapKitExchange.canSell(id), isFalse, reason: id);
      }
    });

    test("chains without prebuilt signing only get plain deposits", () {
      expect(SwapKitAPI.supportedTxHints, ["simpleTransfer"]);
    });

    Future<String?> createError({
      String? extraId,
      String refundExtraId = "",
      String addressRefund = "bc1qrefund",
      bool fixedRate = false,
      bool reversed = false,
    }) async {
      final response = await SwapKitExchange.instance.createTrade(
        from: "btc",
        to: "eth",
        fromNetwork: "btc",
        toNetwork: "eth",
        fixedRate: fixedRate,
        amount: Decimal.one,
        addressTo: "0xdestination",
        extraId: extraId,
        addressRefund: addressRefund,
        refundExtraId: refundExtraId,
        estimate: Estimate(
          estimatedAmount: Decimal.one,
          fixedRate: fixedRate,
          reversed: reversed,
          exchangeProvider: "Chainflip",
          rateId: "route",
        ),
        reversed: reversed,
      );
      expect(response.value, isNull);
      return response.exception?.toString();
    }

    test("rejects unsupported trades before any network call", () async {
      expect(await createError(extraId: "123"), contains("memos"));
      expect(await createError(refundExtraId: "123"), contains("memos"));
      expect(await createError(addressRefund: ""), contains("refund address"));
      // an amount to receive is only taken for fixed rate (EXACT_OUTPUT)
      expect(await createError(reversed: true), contains("fixed rate"));
    });

    Trade trade({required String payInTxid, String? other}) => Trade(
      uuid: "uuid",
      tradeId: "swap-id",
      rateType: "estimated",
      direction: "direct",
      timestamp: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      payInCurrency: "BTC",
      payInAmount: "0.01",
      payInAddress: "bc1qdeposit",
      payInNetwork: "btc",
      payInExtraId: "",
      payInTxid: payInTxid,
      payOutCurrency: "ETH",
      payOutAmount: "0.35",
      payOutAddress: "0xdestination",
      payOutNetwork: "eth",
      payOutExtraId: "",
      payOutTxid: "",
      refundAddress: "bc1qrefund",
      refundExtraId: "",
      status: "Waiting",
      exchangeName: "SwapKit (NEAR Intents)",
      other: other,
    );

    test("tracking link deep links to the deposit tx once known", () {
      const info = '{"swapkit":1,"routeId":"r","sellChainId":"bitcoin"}';
      expect(
        SwapKitExchange.trackingUrl(trade(payInTxid: "abc123", other: info)),
        "https://track.swapkit.dev/tx/abc123?chainId=bitcoin",
      );
      expect(
        SwapKitExchange.trackingUrl(trade(payInTxid: "abc123")),
        "https://track.swapkit.dev",
      );
    });
  });

  group("SwapKit response parsing", () {
    test("token", () {
      final gas = SkToken.fromMap({
        "chain": "BTC",
        "chainId": "bitcoin",
        "ticker": "BTC",
        "identifier": "BTC.BTC",
        "name": "Bitcoin",
        "decimals": 8,
      });
      expect(gas.isGasAsset, isTrue);

      final usdc = SkToken.fromMap({
        "chain": "ETH",
        "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "chainId": "1",
        "ticker": "USDC",
        "identifier": "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48",
        "decimals": 6,
        "isStablecoin": true,
      });
      expect(usdc.isGasAsset, isFalse);
      expect(usdc.isStablecoin, isTrue);
      expect(usdc.name, "USDC");
      // matches Stack's lower case default token list
      expect(
        usdc.contractAddress,
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      );
      expect(gas.contractAddress, isNull);

      // base58 addresses are case-sensitive and must not be changed
      final splUsdc = SkToken.fromMap({
        "chain": "SOL",
        "address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        "ticker": "USDC",
        "identifier": "SOL.USDC-EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      });
      expect(
        splUsdc.contractAddress,
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      );
    });

    test("quote with routes and provider errors", () {
      final quote = SkQuote.fromMap({
        "quoteId": "q",
        "routes": [
          {
            "routeId": "r1",
            "providers": ["CHAINFLIP"],
            "sellAsset": "BTC.BTC",
            "buyAsset": "ETH.ETH",
            "sellAmount": "0.1",
            "expectedBuyAmount": "2.5",
            "expectedBuyAmountMaxSlippage": "2.45",
            "estimatedTime": {"total": 600},
            "txHint": "simpleTransfer",
            "warnings": [
              {"code": "highSlippage", "display": "High slippage"},
            ],
            "meta": {
              "tags": ["RECOMMENDED"],
            },
          },
        ],
        "providerErrors": [
          {
            "provider": "NEAR",
            "errorCode": "sellAssetAmountTooSmall",
            "minAmount": "0.002",
          },
          {
            "provider": "THORCHAIN_STREAMING",
            "errorCode": "sellAssetAmountTooSmall",
            "minAmount": "0.0005",
          },
        ],
      });

      expect(quote.routes.single.expectedBuyAmount, Decimal.parse("2.5"));
      expect(quote.routes.single.sellAmount, Decimal.parse("0.1"));
      expect(quote.routes.single.providerKey, "CHAINFLIP");
      expect(quote.routes.single.estimatedTimeSeconds, 600);
      expect(quote.routes.single.warnings, ["High slippage"]);
      expect(quote.routes.single.tags, ["RECOMMENDED"]);
      expect(quote.reportedMinAmount, Decimal.parse("0.0005"));
    });

    test("swap uses targetAddress, falls back to inboundAddress", () {
      final base = {
        "swapId": "s",
        "routeId": "r",
        "createdAt": "2026-11-16T10:00:00.000Z",
        "providers": ["CHAINFLIP"],
        "sellAsset": "BTC.BTC",
        "buyAsset": "ETH.ETH",
        "sellAmount": "0.1",
        "expectedBuyAmount": "2.5",
        "sourceAddress": "bc1qsource",
        "destinationAddress": "0xdest",
        "txHint": "simpleTransfer",
        "meta": {
          "providerDepositChannelId": "1234567-Bitcoin-89",
          "depositChannelExpiration": 1795392000,
        },
      };

      final a = SkSwap.fromMap({...base, "targetAddress": "bc1qdeposit"});
      expect(a.depositAddress, "bc1qdeposit");
      expect(a.depositChannelId, "1234567-Bitcoin-89");
      expect(
        a.depositChannelExpiration,
        DateTime.fromMillisecondsSinceEpoch(1795392000 * 1000, isUtc: true),
      );

      final b = SkSwap.fromMap({...base, "inboundAddress": "bc1qinbound"});
      expect(b.depositAddress, "bc1qinbound");

      expect(() => SkSwap.fromMap(base), throwsFormatException);
    });

    test("track", () {
      final t = SkTrack.fromMap({
        "chainId": "bitcoin",
        "hash": "in",
        "status": "completed",
        "toAmount": "2.49",
        "legs": [
          {"hash": "in"},
          {"hash": "out"},
        ],
      });
      expect(t.status, "completed");
      expect(t.toAmount, "2.49");
      expect(t.outboundHash, "out");

      final single = SkTrack.fromMap({
        "hash": "in",
        "status": "pending",
        "legs": [
          {"hash": "in"},
        ],
      });
      expect(single.outboundHash, isNull);
    });

    test("track picks the leg paying the destination as the payout", () {
      // shape of a completed USDC -> BTC swap via NEAR (live /track)
      final t = SkTrack.fromMap({
        "chainId": "1",
        "hash": "0xdeposit",
        "status": "completed",
        "toAmount": "0.0154678",
        "toAddress": "bc1qdest",
        "legs": [
          {"chainId": "1", "hash": "0xdeposit", "toAddress": "0xnear"},
          {"chainId": "near", "hash": "NEARSWAP", "toAddress": "bc1qdest"},
          {"chainId": "bitcoin", "hash": "btcpayout", "toAddress": "bc1qdest"},
        ],
      });
      expect(t.outboundHash, "btcpayout");
      expect(t.toAmount, "0.0154678");
    });

    // shapes taken from live /v3/swap responses
    final swapBase = {
      "swapId": "s",
      "routeId": "r",
      "createdAt": "2026-11-16T10:00:00.000Z",
      "providers": ["THORCHAIN_STREAMING"],
      "sellAsset": "ETH.USDC-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      "buyAsset": "BTC.BTC",
      "sellAmount": "2000",
      "expectedBuyAmount": "0.03",
      "sourceAddress": "0xsource",
      "destinationAddress": "bc1qdest",
      "targetAddress": "0xD37BbE5744D730a1d98d8DC97c42F0Ca46aD7146",
    };

    test("swap with an EVM contract call and approval", () {
      final swap = SkSwap.fromMap({
        ...swapBase,
        "txHint": "contractCall",
        "txType": "EVM",
        "tx": {
          "to": "0xD37BbE5744D730a1d98d8DC97c42F0Ca46aD7146",
          "from": "0xsource",
          "gas": "0x27596",
          "value": "0x6f05b59d3b20000",
          "data": "0x44bc937b00",
        },
        "approvalTx": {
          "to": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "from": "0xsource",
          "value": "0",
          "data": "0x095ea7b300",
          "gasLimit": "0xdc29",
        },
      });
      expect(swap.evmTx!.to, "0xD37BbE5744D730a1d98d8DC97c42F0Ca46aD7146");
      expect(swap.evmTx!.value, BigInt.parse("6f05b59d3b20000", radix: 16));
      expect(swap.evmTx!.gasLimit, 0x27596);
      expect(swap.evmTx!.data, "0x44bc937b00");
      expect(swap.approvalTx!.value, BigInt.zero);
      expect(swap.approvalTx!.gasLimit, 0xdc29);
      expect(swap.psbt, isNull);
    });

    test("swap with a PSBT and a memo route", () {
      final psbt = SkSwap.fromMap({
        ...swapBase,
        "txHint": "transferWithMemo",
        "txType": "PSBT",
        "tx": "cHNidP8BAA==",
        "memo": "0x0101fa",
      });
      expect(psbt.psbt, "cHNidP8BAA==");
      expect(psbt.evmTx, isNull);

      final memo = SkSwap.fromMap({
        ...swapBase,
        "txHint": "transferWithMemo",
        "memo": "=:e:0xdest:176102572/1/0:-_/tan:7/0",
      });
      expect(memo.memo, startsWith("=:e:"));
      expect(memo.txType, isNull);
      expect(memo.psbt, isNull);
    });

    test("swap with a Solana program call", () {
      final swap = SkSwap.fromMap({
        ...swapBase,
        "sellAsset": "SOL.SOL",
        "txHint": "contractCall",
        "txType": "SERIALIZED_BASE64",
        "tx": "AQAAAA==",
        "targetAddress": "J88B7gmadHzTNGiy54c9Ms8BsEXNdB2fntFyhKpk3qoT",
      });
      expect(swap.solanaTx, "AQAAAA==");
      expect(swap.evmTx, isNull);
      expect(swap.psbt, isNull);

      final info = SwapKitTradeInfo.tryParse(
        SwapKitTradeInfo(
          routeId: "r",
          depositChannelId: null,
          depositAddress: null,
          sellChainId: "solana",
          providers: const ["CHAINFLIP"],
          depositDeadline: null,
          execution: SwapKitExecution.solana,
          solanaTx: swap.solanaTx,
          sellAsset: "SOL.USDC-EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
          sourceAddress: "stnkw",
        ).toJsonString(),
      )!;
      expect(info.solanaTx, "AQAAAA==");
      expect(info.sellAsset, startsWith("SOL.USDC-"));
    });

    test("swap with Cardano, Stellar and Bitcoin Cash prebuilt txs", () {
      final ada = SkSwap.fromMap({
        ...swapBase,
        "sellAsset": "ADA.ADA",
        "txHint": "simpleTransfer",
        "txType": "CBOR",
        "tx": "84a40086825820d6",
        "targetAddress":
            "addr1v96vdwc0sqa42wvqrd50evkcdgv3f93rf7zpc9snqn64hvq32xdcl",
      });
      expect(ada.cardanoTx, "84a40086825820d6");
      expect(ada.stellarTx, isNull);

      final xlm = SkSwap.fromMap({
        ...swapBase,
        "sellAsset": "XLM.XLM",
        "txHint": "transferWithMemo",
        "txType": "STELLAR",
        "tx": "AAAAAgAAAAAoD919",
        "memo": "242482172",
        "targetAddress":
            "GDJ4JZXZELZD737NVFORH4PSSQDWFDZTKW3AIDKHYQG23ZXBPDGGQBJK",
      });
      expect(xlm.stellarTx, "AAAAAgAAAAAoD919");
      expect(xlm.cardanoTx, isNull);

      // THORChain returns Bitcoin Cash vaults without the cashaddr prefix
      final bch = SkSwap.fromMap({
        ...swapBase,
        "sellAsset": "BCH.BCH",
        "txHint": "transferWithMemo",
        "txType": "PSBT",
        "tx": "cHNidP8BAA==",
        "targetAddress": "qzat5qhem4xrcy6k20k2v8l837wt5rvrnykj63fjv5",
      });
      expect(
        bch.depositAddress,
        "bitcoincash:qzat5qhem4xrcy6k20k2v8l837wt5rvrnykj63fjv5",
      );
      expect(bch.psbt, "cHNidP8BAA==");
    });

    test("trade info round trip", () {
      final info = SwapKitTradeInfo(
        routeId: "r",
        depositChannelId: null,
        depositAddress: null,
        sellChainId: "1",
        providers: const ["CHAINFLIP"],
        depositDeadline: null,
        execution: SwapKitExecution.evm,
        evmTx: SkEvmTx(
          to: "0xrouter",
          value: BigInt.from(500),
          data: "0xdd68",
          gasLimit: 161174,
        ),
        approvalTx: SkEvmTx(
          to: "0xtoken",
          value: BigInt.zero,
          data: "0x095e",
          gasLimit: null,
        ),
        sourceAddress: "0xsource",
      );
      final back = SwapKitTradeInfo.tryParse(info.toJsonString())!;
      expect(back.execution, SwapKitExecution.evm);
      expect(back.execution.isPrebuilt, isTrue);
      expect(back.evmTx!.value, BigInt.from(500));
      expect(back.evmTx!.gasLimit, 161174);
      expect(back.approvalTx!.to, "0xtoken");
      expect(back.sourceAddress, "0xsource");

      // trades created before route kinds existed are plain deposits
      final old = SwapKitTradeInfo.tryParse(
        '{"swapkit":1,"routeId":"r","depositAddress":"bc1q"}',
      )!;
      expect(old.execution, SwapKitExecution.deposit);
      expect(old.execution.isPrebuilt, isFalse);
      expect(old.payableFromAnyWallet, isTrue);
    });

    test("prebuilt plain deposits stay payable from any wallet", () {
      SwapKitTradeInfo info(SwapKitExecution execution, String hint) =>
          SwapKitTradeInfo.tryParse(
            SwapKitTradeInfo(
              routeId: "r",
              depositChannelId: null,
              depositAddress: "bc1qdeposit",
              sellChainId: "bitcoin",
              providers: const ["NEAR"],
              depositDeadline: null,
              execution: execution,
              routeHint: hint,
              psbt: "cHNidP8BAA==",
            ).toJsonString(),
          )!;

      // NEAR via a PSBT: Send from Stack signs it, any wallet may pay
      final near = info(SwapKitExecution.psbt, "simpleTransfer");
      expect(near.execution.isPrebuilt, isTrue);
      expect(near.payableFromAnyWallet, isTrue);

      // THORChain via a PSBT: only Send from Stack can pay it
      final thor = info(SwapKitExecution.psbt, "transferWithMemo");
      expect(thor.payableFromAnyWallet, isFalse);
    });
  });

  group("SwapKit Send from Stack", () {
    test("PSBT payment checks", () {
      Amount sats(int v) => Amount(rawValue: BigInt.from(v), fractionDigits: 8);

      // live Chainflip PSBT: 0.05 BTC to the vault, 405 sats fee
      SwapKitStackSend.checkPsbtPayment(
        paid: sats(5000000),
        fee: sats(405),
        expected: sats(5000000),
      );
      expect(
        () => SwapKitStackSend.checkPsbtPayment(
          paid: sats(4000000),
          fee: sats(405),
          expected: sats(5000000),
        ),
        throwsException,
      );
      expect(
        () => SwapKitStackSend.checkPsbtPayment(
          paid: sats(5000000),
          fee: sats(600000),
          expected: sats(5000000),
        ),
        throwsException,
      );
    });
  });
}
