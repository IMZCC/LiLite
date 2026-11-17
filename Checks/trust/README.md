# Apple profile trust anchors

The PEM bundle contains only Apple's three public root certificates, obtained from [Apple PKI](https://www.apple.com/certificateauthority/). These are verification inputs; they are not added to the operating system trust store and contain no private keys or developer identities

| Official public certificate | DER SHA-256 |
|---|---|
| https://www.apple.com/appleca/AppleIncRootCertificate.cer | b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024 |
| https://www.apple.com/certificateauthority/AppleRootCA-G2.cer | c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050 |
| https://www.apple.com/certificateauthority/AppleRootCA-G3.cer | 63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179 |

Checks/review_delivery.py checks the complete set of DER fingerprints before asking OpenSSL to validate the provisioning-profile CMS against these anchors, with both the system certificate path and store disabled. It additionally requires Apple's profile-signing purpose (OID 1.2.840.113635.100.6.58), a current development certificate authorized by that profile, and the explicit target device in ProvisionedDevices

Certificate validity and chain/signature checks are local. Device installation also applies Apple's current revocation and provisioning policy
