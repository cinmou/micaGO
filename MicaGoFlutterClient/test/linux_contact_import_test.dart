import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/contacts/contact_identity.dart';
import 'package:mica_go/features/contacts/linux_contact_import.dart';

String card(String name, String fields) =>
    'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:$name\r\n$fields\r\nEND:VCARD\r\n';

void main() {
  test('overlapping UID-less cards keep identity across repeated imports', () {
    final first = mergeLinuxVCard(
      card('Alice', 'EMAIL:Alice@example.test') +
          card('Alice', 'EMAIL:ALICE@example.test\r\nTEL:+19995551234'),
      [],
    );
    final index = ContactIndex.fromContacts(first.contacts);
    expect(
      index.contactIdFor('alice@example.test'),
      index.contactIdFor('+19995551234'),
    );
    final next = mergeLinuxVCard(
      card('Alice renamed', 'TEL:+19995551234\r\nEMAIL:new@example.test'),
      first.contacts,
    );
    final updated = ContactIndex.fromContacts(next.contacts);
    expect(
      updated.contactIdFor('new@example.test'),
      index.contactIdFor('alice@example.test'),
    );
    expect(updated.displayNameFor('alice@example.test'), 'Alice renamed');
  });

  test('same names do not merge different people', () {
    final result = mergeLinuxVCard(
      card('Alex', 'EMAIL:a@example.test') +
          card('Alex', 'EMAIL:b@example.test'),
      [],
    );
    final index = ContactIndex.fromContacts(result.contacts);
    expect(
      index.contactIdFor('a@example.test'),
      isNot(index.contactIdFor('b@example.test')),
    );
  });

  test(
    'UID and URI addresses are stable across files and renamed contacts',
    () {
      final first = mergeLinuxVCard(
        card('A', 'UID:person-1\r\nEMAIL:mailto:a@example.test'),
        [],
      );
      final next = mergeLinuxVCard(
        card('B', 'UID:person-1\r\nTEL:tel:+19995551234'),
        first.contacts,
      );
      final index = ContactIndex.fromContacts(next.contacts);
      expect(
        index.contactIdFor('a@example.test'),
        index.contactIdFor('+19995551234'),
      );
      expect(index.displayNameFor('a@example.test'), 'B');
    },
  );

  test('invalid files cannot replace the previously imported contacts', () {
    expect(() => mergeLinuxVCard('not a vCard', []), throwsFormatException);
    expect(
      () => mergeLinuxVCard(card('No addresses', ''), []),
      throwsFormatException,
    );
  });

  test('bad records and broken photos do not discard good contacts', () {
    final result = mergeLinuxVCard(
      [
        card('Alice', 'TEL:+19995551234\r\nPHOTO;ENCODING=b:invalid-base64'),
        'BEGIN:VCARD\nVERSION:3.0\nFN;ENCODING=QUOTED-PRINTABLE:=FF\n'
            'TEL:+19995559999\nEND:VCARD\n',
        card('No addresses', ''),
        card('Bob', 'EMAIL:bob@example.test'),
      ].join(),
      [],
    );
    expect(result.imported, 2);
    expect(result.skipped, 2);
    expect(result.photoErrors, 1);
    final index = ContactIndex.fromContacts(result.contacts);
    expect(index.displayNameFor('+19995551234'), 'Alice');
    expect(index.displayNameFor('bob@example.test'), 'Bob');
  });

  test('CR-only exports and quoted-printable soft breaks retain names', () {
    final result = mergeLinuxVCard(
      'BEGIN:VCARD\rVERSION:2.1\r'
      'FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=E5=BC=A0=\r=E4=B8=89\r'
      'TEL:tel:+19995551234\rEND:VCARD\r',
      [],
    );
    expect(
      ContactIndex.fromContacts(result.contacts).displayNameFor('+19995551234'),
      '张三',
    );
  });

  test('empty and truncated cards do not hide adjacent records', () {
    final result = mergeLinuxVCard(
      [
        'BEGIN:VCARD\nEND:VCARD\n'
            'BEGIN:VCARD\nFN:Alice\nTEL:+19995551234\n',
        card('Bob', 'EMAIL:bob@example.test'),
      ].join(),
      [],
    );
    expect(result.imported, 2);
    expect(result.skipped, 1);
  });

  test('streaming file import accepts exports larger than 10 MiB', () async {
    final directory = await Directory.systemTemp.createTemp(
      'micago-large-vcf-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/contacts.vcf');
    final output = file.openWrite();
    output.write(
      'BEGIN:VCARD\nVERSION:3.0\nFN:Alice\nPHOTO;ENCODING=b:ignored\n',
    );
    final photoLine = ' ${'A' * 65536}\n';
    for (var i = 0; i < 176; i++) {
      output.write(photoLine);
    }
    output.write('TEL:+19995551234\nEND:VCARD\n');
    await output.close();
    expect(await file.length(), greaterThan(10 * 1024 * 1024));
    final result = await mergeLinuxVCardFile(file.path, []);
    expect(result.imported, 1);
    expect(result.skipped, 0);
    expect(
      ContactIndex.fromContacts(result.contacts).displayNameFor('+19995551234'),
      'Alice',
    );
  });
}
