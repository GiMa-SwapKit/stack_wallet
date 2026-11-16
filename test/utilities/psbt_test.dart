import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/psbt.dart';

/// Builds a PSBT v0 shaped like the Chainflip vault swap PSBTs SwapKit
/// returns: one P2WPKH input (witness UTXO), outputs to the vault, an
/// OP_RETURN and change.
Uint8List _psbt({
  bool signed = false,
  int? sighash,
  int? globalVersion,
  bool badMagic = false,
}) {
  final b = BytesBuilder();
  void varInt(int n) {
    assert(n < 0xfd);
    b.addByte(n);
  }

  void entry(List<int> key, List<int> value) {
    varInt(key.length);
    b.add(key);
    varInt(value.length);
    b.add(value);
  }

  final tx = BytesBuilder();
  void txU32(int n) => tx.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void txU64(int n) => tx.add(
    (ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List(),
  );
  txU32(2); // version
  tx.addByte(1); // 1 input
  tx.add(List.generate(32, (i) => i)); // prev hash (little endian)
  txU32(1); // vout
  tx.addByte(0); // empty scriptSig
  txU32(0xffffffff); // sequence
  tx.addByte(3); // 3 outputs
  final vault = [0x51, 0x20, ...List.filled(32, 0xaa)]; // P2TR
  final opReturn = [0x6a, 0x04, 1, 2, 3, 4];
  final change = [0x00, 0x14, ...List.filled(20, 0xbb)]; // P2WPKH
  for (final (value, script) in [
    (5000000, vault),
    (0, opReturn),
    (25515214, change),
  ]) {
    txU64(value);
    tx.addByte(script.length);
    tx.add(script);
  }
  txU32(0); // locktime
  final unsignedTx = tx.toBytes();

  b.add(badMagic ? utf8.encode("psbx") : utf8.encode("psbt"));
  b.addByte(0xff);
  // global
  entry([0x00], unsignedTx);
  if (globalVersion != null) {
    entry(
      [0xfb],
      (ByteData(
        4,
      )..setUint32(0, globalVersion, Endian.little)).buffer.asUint8List(),
    );
  }
  b.addByte(0);
  // input 0: witness utxo
  final witnessUtxo = BytesBuilder()
    ..add(
      (ByteData(8)..setUint64(0, 30515619, Endian.little)).buffer.asUint8List(),
    )
    ..addByte(22)
    ..add([0x00, 0x14, ...List.filled(20, 0xcc)]);
  entry([0x01], witnessUtxo.toBytes());
  if (sighash != null) {
    entry(
      [0x03],
      (ByteData(4)..setUint32(0, sighash, Endian.little)).buffer.asUint8List(),
    );
  }
  if (signed) entry([0x02, ...List.filled(33, 2)], [0x30, 0x44]);
  b.addByte(0);
  // 3 empty output maps
  b.add([0, 0, 0]);
  return b.toBytes();
}

void main() {
  group("Psbt", () {
    test("reads the unsigned tx, inputs and outputs", () {
      final psbt = Psbt.fromBytes(_psbt());

      expect(psbt.version, 2);
      expect(psbt.locktime, 0);
      expect(psbt.outPoints.single.vout, 1);
      expect(psbt.outPoints.single.sequence, 0xffffffff);
      // txid is the reversed (big endian) hash
      expect(
        psbt.outPoints.single.txid,
        List.generate(
          32,
          (i) => (31 - i).toRadixString(16).padLeft(2, "0"),
        ).join(),
      );

      final input = psbt.inputs.single;
      expect(input.witnessUtxoValue, BigInt.from(30515619));
      expect(input.witnessUtxoScript!.length, 22);
      expect(input.hasSignatures, isFalse);
      expect(input.sighashType, isNull);

      expect(psbt.outputs.map((e) => e.value.toInt()), [5000000, 0, 25515214]);
      expect(psbt.outputs[1].scriptPubKey.first, 0x6a);
    });

    test("base64 round trip", () {
      final psbt = Psbt.fromBase64(base64.encode(_psbt()));
      expect(psbt.outputCount, 3);
    });

    test("flags signed inputs and sighash types", () {
      expect(
        Psbt.fromBytes(_psbt(signed: true)).inputs.single.hasSignatures,
        isTrue,
      );
      expect(
        Psbt.fromBytes(_psbt(sighash: 0x81)).inputs.single.sighashType,
        0x81,
      );
    });

    test("rejects malformed or unsupported data", () {
      expect(
        () => Psbt.fromBytes(_psbt(badMagic: true)),
        throwsFormatException,
      );
      expect(
        () => Psbt.fromBytes(_psbt(globalVersion: 2)),
        throwsFormatException,
      );
      final truncated = _psbt();
      expect(
        () => Psbt.fromBytes(
          Uint8List.sublistView(truncated, 0, truncated.length - 2),
        ),
        throwsFormatException,
      );
    });
  });
}
