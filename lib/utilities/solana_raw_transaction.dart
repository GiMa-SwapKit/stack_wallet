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

/// A serialised Solana transaction (legacy or version 0) built by someone
/// else, e.g. a swap provider, for this wallet to sign.
///
/// Only the parts needed to check and sign it are read: the signature slots,
/// the message header, the static account keys and the recent blockhash. The
/// instructions and address table lookups are kept as raw bytes, so the
/// signed transaction is exactly the one that was built, apart from the
/// blockhash, which can be refreshed with [withBlockhash].
class SolanaRawTransaction {
  /// -1 for a legacy message, otherwise the version (only 0 is supported).
  final int version;

  /// Signatures required by the message header, fee payer first.
  final int requiredSignatures;

  /// The message's static account keys (32 bytes each), fee payer first.
  final List<Uint8List> accountKeys;

  /// The signature slots present in the transaction, as given.
  final List<Uint8List> signatures;

  /// The serialised message (what is signed).
  final Uint8List message;

  final int _blockhashOffset;

  SolanaRawTransaction._({
    required this.version,
    required this.requiredSignatures,
    required this.accountKeys,
    required this.signatures,
    required this.message,
    required int blockhashOffset,
  }) : _blockhashOffset = blockhashOffset;

  factory SolanaRawTransaction.fromBase64(String data) =>
      SolanaRawTransaction.fromBytes(base64.decode(data.trim()));

  factory SolanaRawTransaction.fromBytes(Uint8List bytes) {
    final r = _Reader(bytes);

    final signatureCount = r.compactU16();
    final signatures = [
      for (int i = 0; i < signatureCount; i++) Uint8List.fromList(r.slice(64)),
    ];
    final message = Uint8List.fromList(r.rest());

    final m = _Reader(message);
    int version = -1;
    if (message.isNotEmpty && message.first & 0x80 != 0) {
      version = m.byte() & 0x7f;
      if (version != 0) {
        throw FormatException(
          "Unsupported Solana transaction version $version",
        );
      }
    }
    final requiredSignatures = m.byte();
    m.byte(); // read-only signed accounts
    m.byte(); // read-only unsigned accounts
    final keyCount = m.compactU16();
    final accountKeys = [
      for (int i = 0; i < keyCount; i++) Uint8List.fromList(m.slice(32)),
    ];
    final blockhashOffset = m.offset;
    m.slice(32); // recent blockhash
    if (m.atEnd) {
      throw const FormatException("Solana transaction has no instructions");
    }

    if (requiredSignatures == 0 ||
        requiredSignatures != signatureCount ||
        requiredSignatures > keyCount) {
      throw const FormatException(
        "Solana transaction signature count mismatch",
      );
    }

    return SolanaRawTransaction._(
      version: version,
      requiredSignatures: requiredSignatures,
      accountKeys: List.unmodifiable(accountKeys),
      signatures: List.unmodifiable(signatures),
      message: message,
      blockhashOffset: blockhashOffset,
    );
  }

  /// The account paying the fee, which must sign.
  Uint8List get feePayer => accountKeys.first;

  /// The recent blockhash the message was built with.
  Uint8List get blockhash =>
      Uint8List.sublistView(message, _blockhashOffset, _blockhashOffset + 32);

  /// Whether any signature slot already holds a signature.
  bool get hasSignatures => signatures.any((s) => s.any((b) => b != 0));

  /// The message with [blockhash] (32 bytes) instead of the original one.
  /// A blockhash is only valid for about a minute, so a transaction built in
  /// advance is refreshed right before signing.
  Uint8List withBlockhash(Uint8List blockhash) {
    if (blockhash.length != 32) {
      throw ArgumentError.value(blockhash.length, "blockhash", "not 32 bytes");
    }
    return Uint8List.fromList(message)
      ..setRange(_blockhashOffset, _blockhashOffset + 32, blockhash);
  }

  /// Serialises [message] with [signatures] (64 bytes each).
  static Uint8List serialize(List<Uint8List> signatures, Uint8List message) {
    final b = BytesBuilder();
    var n = signatures.length;
    // compact-u16
    while (true) {
      if (n < 0x80) {
        b.addByte(n);
        break;
      }
      b.addByte((n & 0x7f) | 0x80);
      n >>= 7;
    }
    for (final s in signatures) {
      if (s.length != 64) {
        throw ArgumentError.value(s.length, "signature", "not 64 bytes");
      }
      b.add(s);
    }
    b.add(message);
    return b.toBytes();
  }
}

class _Reader {
  final Uint8List _bytes;
  int offset = 0;

  _Reader(this._bytes);

  bool get atEnd => offset == _bytes.length;

  int byte() {
    if (offset >= _bytes.length) {
      throw const FormatException("Unexpected end of Solana transaction");
    }
    return _bytes[offset++];
  }

  Uint8List slice(int n) {
    if (offset + n > _bytes.length) {
      throw const FormatException("Unexpected end of Solana transaction");
    }
    final s = Uint8List.sublistView(_bytes, offset, offset + n);
    offset += n;
    return s;
  }

  Uint8List rest() => slice(_bytes.length - offset);

  int compactU16() {
    int value = 0;
    for (int i = 0; i < 3; i++) {
      final b = byte();
      value |= (b & 0x7f) << (7 * i);
      if (b & 0x80 == 0) return value;
    }
    throw const FormatException("Bad compact-u16 in Solana transaction");
  }
}
