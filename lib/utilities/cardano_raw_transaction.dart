/*
 * This file is part of Stack Wallet.
 *
 * Copyright (c) 2026 Cypher Stack
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

/// A serialised Cardano transaction built by someone else, e.g. a swap
/// provider, split into its top-level parts without re-encoding them.
///
/// The body must be signed and submitted exactly as it was built: encoders
/// differ (e.g. the set tag on inputs), and re-encoding the body changes its
/// hash, which is what the witnesses sign. So the body stays raw bytes, the
/// wallet signs their hash, and [withWitnessSet] splices its witness set in.
class CardanoRawTransaction {
  /// The transaction body, as built.
  final Uint8List body;

  /// The witness set, as built (normally an empty map).
  final Uint8List witnessSet;

  /// Everything after the witness set (validity flag and auxiliary data in
  /// the Alonzo+ 4-element form, auxiliary data in the older 3-element form).
  final List<Uint8List> rest;

  CardanoRawTransaction._(this.body, this.witnessSet, this.rest);

  factory CardanoRawTransaction.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException("Empty Cardano transaction");
    }
    final header = bytes.first;
    if (header != 0x83 && header != 0x84) {
      throw const FormatException("Not a Cardano transaction (array of 3/4)");
    }
    final r = _CborSkipper(bytes)..offset = 1;
    final parts = <Uint8List>[];
    for (int i = 0; i < (header & 0x1f); i++) {
      final start = r.offset;
      r.skip();
      parts.add(Uint8List.sublistView(bytes, start, r.offset));
    }
    if (r.offset != bytes.length) {
      throw const FormatException("Trailing bytes after Cardano transaction");
    }
    if (parts.first.first >> 5 != 5) {
      throw const FormatException("Cardano transaction body is not a map");
    }
    return CardanoRawTransaction._(parts[0], parts[1], parts.sublist(2));
  }

  /// Whether the witness set is anything but an empty map.
  bool get hasWitnesses => !(witnessSet.length == 1 && witnessSet[0] == 0xa0);

  /// The transaction with [witnessSet] (CBOR) instead of the original one;
  /// the body and the remaining parts are kept byte for byte.
  Uint8List withWitnessSet(Uint8List witnessSet) {
    final b = BytesBuilder()
      ..addByte(0x80 | (2 + rest.length))
      ..add(body)
      ..add(witnessSet);
    for (final part in rest) {
      b.add(part);
    }
    return b.toBytes();
  }
}

/// Skips over definite-length CBOR items.
class _CborSkipper {
  final Uint8List _b;
  int offset = 0;

  _CborSkipper(this._b);

  int _byte() {
    if (offset >= _b.length) {
      throw const FormatException("Unexpected end of Cardano transaction");
    }
    return _b[offset++];
  }

  int _argument(int info) {
    if (info < 24) return info;
    final length = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw const FormatException(
        "Indefinite-length CBOR is not supported",
      ),
    };
    int value = 0;
    for (int i = 0; i < length; i++) {
      value = (value << 8) | _byte();
    }
    return value;
  }

  void skip() {
    final initial = _byte();
    final major = initial >> 5;
    final arg = _argument(initial & 0x1f);
    switch (major) {
      case 0: // unsigned int
      case 1: // negative int
      case 7: // simple / float
        return;
      case 2: // bytes
      case 3: // text
        if (offset + arg > _b.length) {
          throw const FormatException("Unexpected end of Cardano transaction");
        }
        offset += arg;
      case 4: // array
        for (int i = 0; i < arg; i++) {
          skip();
        }
      case 5: // map
        for (int i = 0; i < arg * 2; i++) {
          skip();
        }
      case 6: // tag
        skip();
    }
  }
}
