import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/cardano_raw_transaction.dart';

// body {0: set-tagged inputs [[hash, 1]], 1: [], 2: 175357}
final _body = [
  0xa3, // map(3)
  0x00, 0xd9, 0x01, 0x02, 0x81, 0x82, 0x58, 0x20, ...List.filled(32, 0xab),
  0x01, // inputs: tag 258 [[bytes(32), 1]]
  0x01, 0x80, // outputs: []
  0x02, 0x1a, 0x00, 0x02, 0xad, 0xfd, // fee: 175357
];

Uint8List _tx({List<int> witnessSet = const [0xa0], int header = 0x84}) =>
    Uint8List.fromList([
      header,
      ..._body,
      ...witnessSet,
      if (header == 0x84) 0xf5, // valid
      0xf6, // no auxiliary data
    ]);

void main() {
  group("CardanoRawTransaction", () {
    test("splits a transaction without re-encoding its body", () {
      final raw = CardanoRawTransaction.fromBytes(_tx());
      expect(raw.body, _body);
      expect(raw.witnessSet, [0xa0]);
      expect(raw.rest, [
        [0xf5],
        [0xf6],
      ]);
      expect(raw.hasWitnesses, isFalse);
    });

    test("splices a witness set in, keeping everything else", () {
      final bytes = _tx();
      final raw = CardanoRawTransaction.fromBytes(bytes);
      expect(raw.withWitnessSet(raw.witnessSet), bytes);

      final witnesses = Uint8List.fromList([0xa1, 0x00, 0x80]);
      final signed = CardanoRawTransaction.fromBytes(
        raw.withWitnessSet(witnesses),
      );
      expect(signed.body, _body);
      expect(signed.witnessSet, witnesses);
      expect(signed.hasWitnesses, isTrue);
    });

    test("reads the older 3-element form", () {
      final raw = CardanoRawTransaction.fromBytes(_tx(header: 0x83));
      expect(raw.rest, [
        [0xf6],
      ]);
    });

    test("rejects malformed transactions", () {
      expect(
        () => CardanoRawTransaction.fromBytes(Uint8List.fromList([0x82, 0x00])),
        throwsFormatException,
      );
      expect(
        () => CardanoRawTransaction.fromBytes(
          Uint8List.fromList([..._tx(), 0x00]),
        ),
        throwsFormatException,
      );
      expect(
        () => CardanoRawTransaction.fromBytes(
          Uint8List.fromList([0x84, 0xbf, 0xff, 0xa0, 0xf5, 0xf6]),
        ),
        throwsFormatException,
      );
    });
  });
}
