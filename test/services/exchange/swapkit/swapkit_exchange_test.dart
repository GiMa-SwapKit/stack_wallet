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
import 'package:stackwallet/utilities/address_utils.dart';
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

    test("only requests plain deposit-address routes", () {
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
      expect(await createError(fixedRate: true), contains("fixed rate"));
      expect(await createError(reversed: true), contains("reversed"));
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

    test("trade info round trip", () {
      final info = SwapKitTradeInfo(
        routeId: "r",
        depositChannelId: null,
        depositAddress: null,
        sellChainId: "1",
        providers: const ["CHAINFLIP"],
        depositDeadline: null,
        execution: SwapKitExecution.contractCall,
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
      expect(back.execution, SwapKitExecution.contractCall);
      expect(back.execution.needsStackWallet, isTrue);
      expect(back.evmTx!.value, BigInt.from(500));
      expect(back.evmTx!.gasLimit, 161174);
      expect(back.approvalTx!.to, "0xtoken");
      expect(back.sourceAddress, "0xsource");

      // trades created before route kinds existed are plain deposits
      final old = SwapKitTradeInfo.tryParse(
        '{"swapkit":1,"routeId":"r","depositAddress":"bc1q"}',
      )!;
      expect(old.execution, SwapKitExecution.deposit);
      expect(old.execution.needsStackWallet, isFalse);
    });
  });

  group("SwapKit Send from Stack", () {
    test("memo to OP_RETURN payload", () {
      // text memos (THORChain, Maya, Harbor) are UTF-8
      expect(SwapKitStackSend.memoToOpReturnHex("=:e:0x1"), "3d3a653a307831");
      // 0x memos (Chainflip vault swaps) are raw bytes
      expect(SwapKitStackSend.memoToOpReturnHex("0x0101FA"), "0101fa");
    });

    test("OP_RETURN script", () {
      expect(AddressUtils.opReturnScriptFromHex("0101fa"), [
        0x6a,
        3,
        1,
        1,
        0xfa,
      ]);
      final long = "ab" * 76;
      expect(AddressUtils.opReturnScriptFromHex(long).sublist(0, 3), [
        0x6a,
        0x4c,
        76,
      ]);
      expect(
        () => AddressUtils.opReturnScriptFromHex("ab" * 81),
        throwsFormatException,
      );
    });

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
