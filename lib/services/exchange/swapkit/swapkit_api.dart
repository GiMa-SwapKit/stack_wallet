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

import '../../../app_config.dart';
import '../../../exceptions/exchange/exchange_exception.dart';
import '../../../external_api_keys.dart';
import '../../../networking/http.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/prefs.dart';
import '../../tor_service.dart';
import 'response_objects/sk_quote.dart';
import 'response_objects/sk_swap.dart';
import 'response_objects/sk_token.dart';
import 'response_objects/sk_track.dart';

/// Thin client for the SwapKit REST API (https://docs.swapkit.dev).
///
/// Only the endpoints needed for a deposit-address style swap are used:
///   GET  /tokens     - supported assets
///   POST /v3/quote   - routes for a pair + amount (no addresses needed)
///   POST /v3/swap    - lock a route and get the deposit address
///   POST /track      - swap status
///
/// All amounts sent to and received from SwapKit are human readable decimal
/// strings (e.g. "0.05" for 0.05 BTC), NOT base units.
abstract class SwapKitAPI {
  static const String authority = "api.swapkit.dev";

  static const HTTP _client = HTTP();

  /// Route kinds, see `txHints` on `/v3/quote`:
  /// - `simpleTransfer`: plain transfer to a deposit address, from any wallet;
  /// - `transferWithMemo`: transfer carrying a memo (OP_RETURN on UTXO
  ///   chains, a memo on Solana/Stellar), or a PSBT SwapKit builds;
  /// - `contractCall`: call to a router contract on an EVM chain.
  /// The last two can only be sent with "Send from Stack".
  static const String hintTransfer = "simpleTransfer";
  static const String hintMemo = "transferWithMemo";
  static const String hintContractCall = "contractCall";

  /// Route kinds any wallet can pay; used when the sell chain has no Stack
  /// wallet that can send memos or contract calls.
  static const List<String> supportedTxHints = [hintTransfer];

  static Uri _buildUri(String path, [Map<String, String>? params]) =>
      Uri.https(authority, path, params);

  static Map<String, String> get _headers => {
    "Content-Type": "application/json",
    "Accept": "application/json",
    if (kSwapKitApiKey.isNotEmpty) "x-api-key": kSwapKitApiKey,
  };

  static Future<dynamic> _get(Uri uri) async {
    int code = -1;
    try {
      final response = await _client.get(
        url: uri,
        headers: _headers,
        proxyInfo: !AppConfig.hasFeature(AppFeature.tor)
            ? null
            : Prefs.instance.useTor
            ? TorService.sharedInstance.getProxyInfo()
            : null,
      );
      code = response.code;
      return _handle(code, response.body);
    } catch (e, s) {
      Logging.instance.e(
        "SwapKitAPI GET $uri HTTP:$code threw:",
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  static Future<dynamic> _post(Uri uri, Map<String, dynamic> body) async {
    int code = -1;
    try {
      final response = await _client.post(
        url: uri,
        headers: _headers,
        body: jsonEncode(body),
        proxyInfo: !AppConfig.hasFeature(AppFeature.tor)
            ? null
            : Prefs.instance.useTor
            ? TorService.sharedInstance.getProxyInfo()
            : null,
      );
      code = response.code;
      return _handle(code, response.body);
    } catch (e, s) {
      Logging.instance.e(
        "SwapKitAPI POST $uri HTTP:$code threw:",
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  /// SwapKit returns 2xx on success (202 = still pending on some chains for
  /// /track). Errors are `{ "error": "<code>", "message": "...", "data": ...}`.
  static dynamic _handle(int code, String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      json = null;
    }

    if (code >= 200 && code < 300) {
      if (json == null) {
        throw ExchangeException(
          "SwapKit returned an unparseable response (HTTP $code)",
          ExchangeExceptionType.serializeResponseError,
        );
      }
      return json;
    }

    throw SwapKitApiException.fromResponse(code, json, body);
  }

  // ===========================================================================

  /// GET /tokens?provider=all
  static Future<List<SkToken>> getTokens({String provider = "all"}) async {
    final json = await _get(_buildUri("/tokens", {"provider": provider}));
    final tokens = (json is Map ? json["tokens"] : null);
    if (tokens is! List) {
      throw ExchangeException(
        "SwapKit /tokens: missing `tokens` list",
        ExchangeExceptionType.serializeResponseError,
      );
    }
    return tokens
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => SkToken.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// POST /v3/quote
  ///
  /// [sellAmount] is a human readable decimal amount.
  static Future<SkQuote> getQuote({
    required String sellAsset,
    required String buyAsset,
    required Decimal sellAmount,
    String? sourceAddress,
    String? destinationAddress,
    num? slippage,
    List<String> txHints = supportedTxHints,
  }) async {
    final json = await _post(_buildUri("/v3/quote"), {
      "sellAsset": sellAsset,
      "buyAsset": buyAsset,
      "sellAmount": sellAmount.toString(),
      if (sourceAddress != null) "sourceAddress": sourceAddress,
      if (destinationAddress != null) "destinationAddress": destinationAddress,
      if (slippage != null) "slippage": slippage,
      "txHints": txHints,
    });
    return SkQuote.fromMap(Map<String, dynamic>.from(json as Map));
  }

  /// POST /v3/swap
  ///
  /// With [buildTx] false (deposit and memo routes) Stack Wallet builds,
  /// signs and broadcasts the deposit itself and only needs the deposit
  /// address, memo, amounts and tracking identifiers. With [buildTx] true
  /// SwapKit returns the transaction to sign: EVM call data (plus an ERC-20
  /// approval when needed) or a PSBT spending [sourceAddress]'s coins. On UTXO
  /// chains [sourceAddress] may list several addresses separated by `;`.
  static Future<SkSwap> createSwap({
    required String routeId,
    required String sourceAddress,
    required String destinationAddress,
    String? refundAddress,
    bool buildTx = false,
    bool checkBalance = false,
  }) async {
    final json = await _post(_buildUri("/v3/swap"), {
      "routeId": routeId,
      "sourceAddress": sourceAddress,
      "destinationAddress": destinationAddress,
      if (refundAddress != null && refundAddress.isNotEmpty)
        "refundAddress": refundAddress,
      // fail rather than silently drop the user's refund address
      "refundAddressSetting": "STRICT",
      "disableBuildTx": !buildTx,
      // Deposit routes are paid after the swap is created, often from an
      // HD/UTXO wallet with no single funded source address. Without this
      // SwapKit rejects them with `insufficientBalance`.
      "disableBalanceCheck": !checkBalance,
    });
    return SkSwap.fromMap(Map<String, dynamic>.from(json as Map));
  }

  /// POST /track
  ///
  /// Provide exactly one identifier set: [hash] + [chainId], or
  /// [depositChannelId], or [depositAddress].
  static Future<SkTrack> track({
    String? hash,
    String? chainId,
    String? depositChannelId,
    String? depositAddress,
    String? routeId,
  }) async {
    final Map<String, dynamic> body;
    if (hash != null && hash.isNotEmpty && chainId != null) {
      body = {"hash": hash, "chainId": chainId};
    } else if (depositChannelId != null && depositChannelId.isNotEmpty) {
      body = {"depositChannelId": depositChannelId};
    } else if (depositAddress != null && depositAddress.isNotEmpty) {
      body = {"depositAddress": depositAddress};
    } else {
      throw ExchangeException(
        "SwapKit /track: no tracking identifier available yet",
        ExchangeExceptionType.orderNotFound,
      );
    }
    if (routeId != null) body["routeId"] = routeId;

    final json = await _post(_buildUri("/track"), body);
    return SkTrack.fromMap(Map<String, dynamic>.from(json as Map));
  }
}

class SwapKitApiException extends ExchangeException {
  final int httpCode;

  /// SwapKit error code, e.g. `noRoutesFound`, `swapRouteNotFound`,
  /// `txNotFound`, `rateLimitExceeded`.
  final String? errorCode;

  SwapKitApiException(
    super.message,
    super.type, {
    required this.httpCode,
    this.errorCode,
  });

  factory SwapKitApiException.fromResponse(
    int code,
    dynamic json,
    String rawBody,
  ) {
    String? errorCode;
    String? message;
    if (json is Map) {
      errorCode = json["error"]?.toString();
      message = json["message"]?.toString();
    }

    final type = switch (errorCode) {
      "noRoutesFound" ||
      "swapRouteNotFound" ||
      "txNotFound" ||
      "depositChannelNotFound" => ExchangeExceptionType.orderNotFound,
      _ => ExchangeExceptionType.generic,
    };

    return SwapKitApiException(
      "SwapKit: ${message ?? errorCode ?? "HTTP $code: $rawBody"}",
      type,
      httpCode: code,
      errorCode: errorCode,
    );
  }
}
