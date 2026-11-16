import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/solana_raw_transaction.dart';

final _payer = List.filled(32, 0x11);
final _program = List.filled(32, 0x22);
final _blockhash = List.filled(32, 0x33);

/// A transaction shaped like the Chainflip ones SwapKit returns: one empty
/// signature slot for the fee payer, a v0 message, one program call.
Uint8List _tx({
  int signatureSlots = 1,
  int requiredSignatures = 1,
  int versionByte = 0x80,
  bool signed = false,
}) {
  final b = BytesBuilder()..addByte(signatureSlots);
  for (int i = 0; i < signatureSlots; i++) {
    b.add(List.filled(64, signed ? 7 : 0));
  }
  if (versionByte >= 0x80) b.addByte(versionByte);
  b
    ..add([requiredSignatures, 0, 1]) // header
    ..addByte(2) // account keys
    ..add(_payer)
    ..add(_program)
    ..add(_blockhash)
    ..addByte(1) // one instruction
    ..add([1, 1, 0, 2, 0xaa, 0xbb]); // program 1, accounts [0], data
  if (versionByte >= 0x80) b.addByte(0); // no address table lookups
  return b.toBytes();
}

void main() {
  group("SolanaRawTransaction", () {
    test("reads a v0 transaction", () {
      final tx = SolanaRawTransaction.fromBase64(base64.encode(_tx()));
      expect(tx.version, 0);
      expect(tx.requiredSignatures, 1);
      expect(tx.feePayer, _payer);
      expect(tx.accountKeys[1], _program);
      expect(tx.blockhash, _blockhash);
      expect(tx.hasSignatures, isFalse);
    });

    test("reads a legacy transaction", () {
      final tx = SolanaRawTransaction.fromBytes(_tx(versionByte: 0));
      expect(tx.version, -1);
      expect(tx.feePayer, _payer);
    });

    test("swaps the blockhash and re-serialises exactly", () {
      final bytes = _tx();
      final tx = SolanaRawTransaction.fromBytes(bytes);
      expect(SolanaRawTransaction.serialize(tx.signatures, tx.message), bytes);

      final fresh = Uint8List.fromList(List.filled(32, 0x44));
      final message = tx.withBlockhash(fresh);
      final signature = Uint8List.fromList(List.filled(64, 9));
      final signed = SolanaRawTransaction.fromBytes(
        SolanaRawTransaction.serialize([signature], message),
      );
      expect(signed.blockhash, fresh);
      expect(signed.signatures.single, signature);
      // nothing but the blockhash changed
      int changed = 0;
      for (int i = 0; i < message.length; i++) {
        if (message[i] != tx.message[i]) changed++;
      }
      expect(changed, 32);
    });

    test("flags existing signatures", () {
      expect(
        SolanaRawTransaction.fromBytes(_tx(signed: true)).hasSignatures,
        isTrue,
      );
    });

    test("rejects unsupported or inconsistent transactions", () {
      expect(
        () => SolanaRawTransaction.fromBytes(_tx(versionByte: 0x81)),
        throwsFormatException,
      );
      expect(
        () => SolanaRawTransaction.fromBytes(_tx(requiredSignatures: 2)),
        throwsFormatException,
      );
      final bytes = _tx();
      expect(
        () => SolanaRawTransaction.fromBytes(
          Uint8List.sublistView(bytes, 0, 100),
        ),
        throwsFormatException,
      );
    });
  });
}
