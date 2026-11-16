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

/// Minimal reader for BIP-174 partially signed bitcoin transactions (PSBT
/// version 0), as returned by swap providers that build the deposit
/// transaction for the user.
///
/// Only what is needed to sign the transaction with the wallet's own keys is
/// read: the unsigned transaction and, per input, the previous output being
/// spent. Signing and finalising happen in the wallet; the PSBT itself is
/// never re-serialised.
class Psbt {
  static const _magic = [0x70, 0x73, 0x62, 0x74, 0xff]; // "psbt" 0xff

  // global key types
  static const _globalUnsignedTx = 0x00;
  static const _globalVersion = 0xfb;

  // input key types
  static const _inNonWitnessUtxo = 0x00;
  static const _inWitnessUtxo = 0x01;
  static const _inPartialSig = 0x02;
  static const _inSighashType = 0x03;
  static const _inFinalScriptSig = 0x07;
  static const _inFinalScriptWitness = 0x08;

  /// The unsigned transaction: no scriptSigs, no witnesses.
  final Uint8List unsignedTx;

  /// Previous outpoints spent by [unsignedTx], in input order.
  final List<PsbtOutPoint> outPoints;

  /// One entry per input of [unsignedTx].
  final List<PsbtInput> inputs;

  /// Outputs of [unsignedTx], in order.
  final List<PsbtTxOut> outputs;

  /// Version and locktime of [unsignedTx].
  final int version;
  final int locktime;

  int get outputCount => outputs.length;

  Psbt._({
    required this.unsignedTx,
    required this.outPoints,
    required this.inputs,
    required this.outputs,
    required this.version,
    required this.locktime,
  });

  factory Psbt.fromBase64(String data) =>
      Psbt.fromBytes(base64.decode(data.trim()));

  factory Psbt.fromBytes(Uint8List bytes) {
    final r = _Reader(bytes);

    for (final b in _magic) {
      if (r.byte() != b) {
        throw const FormatException("Not a PSBT: bad magic bytes");
      }
    }

    // ---- global map
    Uint8List? unsignedTx;
    for (final (key, value) in r.map()) {
      switch (key[0]) {
        case _globalUnsignedTx:
          if (key.length != 1) throw const FormatException("Bad PSBT key");
          unsignedTx = value;
        case _globalVersion:
          final version = value.length == 4
              ? ByteData.sublistView(value).getUint32(0, Endian.little)
              : -1;
          if (version != 0) {
            throw FormatException("Unsupported PSBT version $version");
          }
      }
    }
    if (unsignedTx == null) {
      throw const FormatException("PSBT has no unsigned transaction");
    }

    final tx = _UnsignedTxShape.parse(unsignedTx);

    // ---- input maps
    final inputs = <PsbtInput>[];
    for (int i = 0; i < tx.outPoints.length; i++) {
      Uint8List? nonWitnessUtxo;
      BigInt? witnessValue;
      Uint8List? witnessScript;
      int? sighashType;
      bool hasSignatures = false;

      for (final (key, value) in r.map()) {
        switch (key[0]) {
          case _inNonWitnessUtxo:
            nonWitnessUtxo = value;
          case _inWitnessUtxo:
            final vr = _Reader(value);
            witnessValue = vr.uint64();
            witnessScript = vr.slice(vr.varInt());
          case _inSighashType:
            sighashType = ByteData.sublistView(value)
                .getUint32(0, Endian.little);
          case _inPartialSig:
          case _inFinalScriptSig:
          case _inFinalScriptWitness:
            hasSignatures = true;
        }
      }

      inputs.add(
        PsbtInput(
          nonWitnessUtxo: nonWitnessUtxo,
          witnessUtxoValue: witnessValue,
          witnessUtxoScript: witnessScript,
          sighashType: sighashType,
          hasSignatures: hasSignatures,
        ),
      );
    }

    // ---- output maps (contents not needed, but they must be well formed)
    for (int i = 0; i < tx.outputs.length; i++) {
      r.map().length;
    }

    return Psbt._(
      unsignedTx: unsignedTx,
      outPoints: tx.outPoints,
      outputs: tx.outputs,
      version: tx.version,
      locktime: tx.locktime,
      inputs: List.unmodifiable(inputs),
    );
  }
}

class PsbtTxOut {
  /// Value in the coin's smallest unit.
  final BigInt value;
  final Uint8List scriptPubKey;

  const PsbtTxOut(this.value, this.scriptPubKey);
}

class PsbtOutPoint {
  /// Previous transaction id as usually displayed (big endian hex).
  final String txid;
  final int vout;
  final int sequence;

  const PsbtOutPoint(this.txid, this.vout, this.sequence);

  @override
  String toString() => "$txid:$vout";
}

class PsbtInput {
  /// Full previous transaction (`PSBT_IN_NON_WITNESS_UTXO`), if present.
  final Uint8List? nonWitnessUtxo;

  /// Value and script of the spent output (`PSBT_IN_WITNESS_UTXO`).
  final BigInt? witnessUtxoValue;
  final Uint8List? witnessUtxoScript;

  /// `PSBT_IN_SIGHASH_TYPE`, if the creator asked for a specific one.
  final int? sighashType;

  /// True if the input already carries (partial or final) signatures.
  final bool hasSignatures;

  const PsbtInput({
    required this.nonWitnessUtxo,
    required this.witnessUtxoValue,
    required this.witnessUtxoScript,
    required this.sighashType,
    required this.hasSignatures,
  });
}

/// Parts of a serialised transaction without witness data (the PSBT unsigned
/// tx format) that signing needs.
class _UnsignedTxShape {
  final int version;
  final List<PsbtOutPoint> outPoints;
  final List<PsbtTxOut> outputs;
  final int locktime;

  _UnsignedTxShape(this.version, this.outPoints, this.outputs, this.locktime);

  static _UnsignedTxShape parse(Uint8List tx) {
    final r = _Reader(tx);
    final version = ByteData.sublistView(r.slice(4)).getInt32(0, Endian.little);
    final inCount = r.varInt();
    if (inCount == 0) {
      // 0x00 here would be a segwit marker: unsigned txs have no witnesses
      throw const FormatException("PSBT unsigned tx has no inputs");
    }
    final outPoints = <PsbtOutPoint>[];
    for (int i = 0; i < inCount; i++) {
      final hash = r.slice(32);
      final vout = r.uint32();
      final scriptSigLength = r.varInt();
      if (scriptSigLength != 0) {
        throw const FormatException("PSBT unsigned tx has a scriptSig");
      }
      final sequence = r.uint32();
      final txid = hash.reversed
          .map((b) => b.toRadixString(16).padLeft(2, "0"))
          .join();
      outPoints.add(PsbtOutPoint(txid, vout, sequence));
    }
    final outCount = r.varInt();
    final outputs = <PsbtTxOut>[];
    for (int i = 0; i < outCount; i++) {
      final value = r.uint64();
      final script = Uint8List.fromList(r.slice(r.varInt()));
      outputs.add(PsbtTxOut(value, script));
    }
    final locktime = r.uint32();
    if (!r.atEnd) {
      throw const FormatException("Trailing bytes after PSBT unsigned tx");
    }
    return _UnsignedTxShape(
      version,
      List.unmodifiable(outPoints),
      List.unmodifiable(outputs),
      locktime,
    );
  }
}

class _Reader {
  final Uint8List _bytes;
  int _offset = 0;

  _Reader(this._bytes);

  bool get atEnd => _offset == _bytes.length;

  void _need(int n) {
    if (_offset + n > _bytes.length) {
      throw const FormatException("Unexpected end of PSBT data");
    }
  }

  int byte() {
    _need(1);
    return _bytes[_offset++];
  }

  Uint8List slice(int n) {
    _need(n);
    final s = Uint8List.sublistView(_bytes, _offset, _offset + n);
    _offset += n;
    return s;
  }

  int uint32() => ByteData.sublistView(slice(4)).getUint32(0, Endian.little);

  BigInt uint64() {
    final b = slice(8);
    BigInt v = BigInt.zero;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | BigInt.from(b[i]);
    }
    return v;
  }

  int varInt() {
    final first = byte();
    if (first < 0xfd) return first;
    if (first == 0xfd) {
      return ByteData.sublistView(slice(2)).getUint16(0, Endian.little);
    }
    if (first == 0xfe) return uint32();
    final v = uint64();
    if (v > BigInt.from(0x7fffffff)) {
      throw const FormatException("PSBT length too large");
    }
    return v.toInt();
  }

  /// Reads one key-value map up to and including its 0x00 separator.
  List<(Uint8List, Uint8List)> map() {
    final entries = <(Uint8List, Uint8List)>[];
    final seen = <String>{};
    while (true) {
      final keyLength = varInt();
      if (keyLength == 0) return entries;
      final key = slice(keyLength);
      final value = slice(varInt());
      if (!seen.add(base64.encode(key))) {
        throw const FormatException("Duplicate key in PSBT map");
      }
      entries.add((key, value));
    }
  }
}
