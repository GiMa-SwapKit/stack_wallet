import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/exchange/response_objects/estimate.dart';
import 'package:stackwallet/services/exchange/exchange.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_quote.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_swap.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_token.dart';
import 'package:stackwallet/services/exchange/swapkit/response_objects/sk_track.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_api.dart';
import 'package:stackwallet/services/exchange/swapkit/swapkit_exchange.dart';

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
  });
}
