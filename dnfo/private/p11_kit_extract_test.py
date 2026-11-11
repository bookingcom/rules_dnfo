"""Unit and golden tests for p11_kit_extract."""

import contextlib
import hashlib
import io
import os
import tempfile
import unittest

from dnfo.private.p11_kit_extract import (
    extract_pems_from_raw,
    parse_p11_kit_bundle,
    process_inputs,
)

CertA_PEM = """-----BEGIN CERTIFICATE-----
MIIDATCCAemgAwIBAgIUXQHYkqStK+C1yMvdyk2cbW0tPB4wDQYJKoZIhvcNAQEL
BQAwEDEOMAwGA1UEAwwFQ2VydEEwHhcNMjYxMTExMTk0OTQyWhcNMzYxMTA4MTk0
OTQyWjAQMQ4wDAYDVQQDDAVDZXJ0QTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
AQoCggEBAL8z+sk0UEGawf/k+uapCQbh8fExdeDFmotX2HFH0VC5tZ4Gsr0OAdH4
nkbe1FmUkcm2d63hrCJxtIbvntYka/lGQbjjuZBHD/n5wrsDy0Awev3Qu3OsJf+V
ohfuqSZ+OuseKxx8Qb3oE/Yd7IlEuth7QsKHteAQzj/+p5vtxyW8SNraw80PyEW5
qrReXbZMUkep1qMzdFnaJHzs9ZRB85A9PFtGYAsle3tZBLJ1gcyi3DTXvw2XH7QP
xUcTyo/+GRIs4BCd6gqxcsLUr3EInWEXrpNWnZFmOzI7OM1ztQpRjJye60q5t7ij
BVLy55yioDN40uc8h488+9BkRiPd1vkCAwEAAaNTMFEwHQYDVR0OBBYEFNzfKUyC
jcE/JU5sAi/RSTXP9HeBMB8GA1UdIwQYMBaAFNzfKUyCjcE/JU5sAi/RSTXP9HeB
MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAF4unG7JWMUXOPbJ
x+kvrI4Mxbg9SfRJqnxbgMBI+xDxbUUAM4zSjUTRo9+S7tcvdi9fXe8eKaZrrxHn
oDxZu52tU/WKlM01bJEnjGHTMjcCexkbfTJaOWk4l/sIZ6fnP1V7NOCuc0sOXAAt
ZRqG3BT4pgbyVOJvEsb23os+KmHhB3fvNlH9wg7wkkilti0LBlBTPfnWT4l/SDrx
NnqH8HAEm5QpdF9YPPYp5CWalu28ovoBKjCyvnHHZ1nBGSmAzEiEuoeCjPi4AWOM
wsf7n12HQZevmqw8scRmeWUtCr8F6EANAXIJWrNHGa0Vkolflx+TK0InmVyhruum
SaNpxmg=
-----END CERTIFICATE-----"""

CertA_PUBKEY = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvzP6yTRQQZrB/+T65qkJ
BuHx8TF14MWai1fYcUfRULm1ngayvQ4B0fieRt7UWZSRybZ3reGsInG0hu+e1iRr
+UZBuOO5kEcP+fnCuwPLQDB6/dC7c6wl/5WiF+6pJn466x4rHHxBvegT9h3siUS6
2HtCwoe14BDOP/6nm+3HJbxI2trDzQ/IRbmqtF5dtkxSR6nWozN0WdokfOz1lEHz
kD08W0ZgCyV7e1kEsnWBzKLcNNe/DZcftA/FRxPKj/4ZEizgEJ3qCrFywtSvcQid
YReuk1adkWY7Mjs4zXO1ClGMnJ7rSrm3uKMFUvLnnKKgM3jS5zyHjzz70GRGI93W
+QIDAQAB
-----END PUBLIC KEY-----"""

CertB_PEM = """-----BEGIN CERTIFICATE-----
MIIDATCCAemgAwIBAgIUASb8J+FYmSYtwVzhIlM3l3mg3qgwDQYJKoZIhvcNAQEL
BQAwEDEOMAwGA1UEAwwFQ2VydEIwHhcNMjYxMTExMTk0OTQyWhcNMzYxMTA4MTk0
OTQyWjAQMQ4wDAYDVQQDDAVDZXJ0QjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
AQoCggEBAMaEDGHke6IovbW3l+eJdhbjIH6HEXQcN/Qqzh/pEEpcAhvZeZK6p5Jg
br4oFRyP30Wh7+DUKnDxtHZh+ySr3TVSwBK9PXnJjNBofuIcnx1zzepsAH4mSN/K
9QxaXewzgfViVGj+i7QtPsIC2roI7CHbTssXGe1gQIiqM/rW3siVpBxKnCRrCbf/
sWGl/E59bDoj6Ro1kbbFZoNn79O4ew3OijMUqX9GL5hkKvZ+IMoX94IZfQtOxXXm
ThdOKCbSW4YPNKNXw40JXhMLnYnJ1ljhUvjymeiYgjQLttd2Y8/kXMcBImpijQHJ
KAzQEfeVby9OMZaidwVu4hPUWmaS1N0CAwEAAaNTMFEwHQYDVR0OBBYEFAF2vG/k
VCqct9cC1iIqL6U4f2FHMB8GA1UdIwQYMBaAFAF2vG/kVCqct9cC1iIqL6U4f2FH
MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHitmaz0FQdnOs5c
KKjzI8Edm7jrOtA2DQ9zVJYpvLbUN4RzdzRtLH2lylYbpqVeMyPKiwIfY9Ojc7pV
b7SkoCwc4//8dzJT6CS/WgoUTLQrTiUV4X7jYsIdxYpMzLufD3pUBB9BvroHGxyG
jbICRJEvllsENEzxuT0RaW0wDg2MjJ/1pttu0ytYpm1z2onwK1BnAnKEi5ItnLXX
WL0bRPyGCzV5941CfR2Nu7puek+b72j+2z/QuJcqMeILE92P+MkZsm1+dMRKZTOp
rUIcwtuQbe/izTZU013xFBxTo99sZehvlAPrKnuMoykQWv7yY6oZxnU3qNP3ZTTf
kVNKNbE=
-----END CERTIFICATE-----"""

CertB_PUBKEY = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxoQMYeR7oii9tbeX54l2
FuMgfocRdBw39CrOH+kQSlwCG9l5krqnkmBuvigVHI/fRaHv4NQqcPG0dmH7JKvd
NVLAEr09ecmM0Gh+4hyfHXPN6mwAfiZI38r1DFpd7DOB9WJUaP6LtC0+wgLaugjs
IdtOyxcZ7WBAiKoz+tbeyJWkHEqcJGsJt/+xYaX8Tn1sOiPpGjWRtsVmg2fv07h7
Dc6KMxSpf0YvmGQq9n4gyhf3ghl9C07FdeZOF04oJtJbhg80o1fDjQleEwudicnW
WOFS+PKZ6JiCNAu213Zjz+RcxwEiamKNAckoDNAR95VvL04xlqJ3BW7iE9RaZpLU
3QIDAQAB
-----END PUBLIC KEY-----"""

CertNoEku_PEM = """-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUazUuzwsSop4/hSwhUEjX2QNpnNwwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJQ2VydE5vRWt1MB4XDTI2MTExMTE5NDk0MloXDTM2MTEw
ODE5NDk0MlowFDESMBAGA1UEAwwJQ2VydE5vRWt1MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA6NN0hECbFKRfacaNLd2FRPNgIFONh0BN2R9k0N9qTxwp
bn0MSwfaU7hPtzk2SSP+GeSYzjtiD7/lt6J5h+o1CdXII2M/6uHLyxsLTnmt6w6F
ZjlA5U85VEwTwMfgfvBgasIjZmV0ejUMe6tPAPL8VYPek/6cJbMhBa4oh7gIWTi0
XTz+yAfV8QH1nJ1q2uSObGPqnFFE+Y5qVaJkrZM4oSQdIgC0Lu1j2rzPkaI8Ml4C
vj/S2yrvP6PYyO0YICfKxUtmY4uimWPku0/0W+pr2uOh+AiGpLNm5foOdzS6oxp4
T4TwwnwmKYbfSB/iinCU//hokwM2QfkpAVIr2LjwyQIDAQABo1MwUTAdBgNVHQ4E
FgQUBB433Vfol7KnMbsXl8cSt+MUZEIwHwYDVR0jBBgwFoAUBB433Vfol7KnMbsX
l8cSt+MUZEIwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAHK/G
jp+PQNw2LQYv1LkghwKBPE0re7itTE5de1tD7zqmc5MY+9vzEZbkwAY4+Z3UaDei
VBhYo33dcOEpdLEfH5L8GWpOl9W5jLn8WQJ0w6aSaop++XoD3fm+vpR5mW4ESHpy
1A6Kf9E1f1mi3D2VLo39/wSNgVy6Zhv0wQZV5GAJpM8vUiz6y8JWwo5zlGuivDfH
uIzNhAO81uE3A2FiOFNMripZodBNIYMeEWc0vSNUP5LROjORNZ3xvyt4bZYdx9iG
AZz6XpkcRFZtKqLjMb0lEO1YTu/JTZPh0CWzKnkY445WZD5MJmkZa9ZfUVnv/7Op
vBzlnwVqUoa784+Mmw==
-----END CERTIFICATE-----"""

CertDistrusted_PEM = """-----BEGIN CERTIFICATE-----
MIIDEjCCAfqgAwIBAgITYWFvTASyU7Y0EoB4bzA1vU0A0DANBgkqhkiG9w0BAQsF
ADAZMRcwFQYDVQQDDA5DZXJ0RGlzdHJ1c3RlZDAeFw0yNjExMTExOTQ5NDJaFw0z
NjExMDgxOTQ5NDJaMBkxFzAVBgNVBAMMDkNlcnREaXN0cnVzdGVkMIIBIjANBgkq
hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmaa0ZKA5AA5DfUH+wnaMTnHwNwnQlfi/
/t3Ta3PWlFAmnIWgZBvQb4P81BVnJER8pAXXBNdAGh8Y42HTkTqhJRHz4jnGYiGO
bJyiH3+gW/KCnzI/EnP5wtIWhCz3HNr7IE/exbStK4kTFZLBSsqpvV/V80N3nA+9
zPVt7u9PMohsV+FzkEt0amCuiKrtgDsco6bhr40Pky17cu8DB4QYJoJdflTAwwsG
uzQaD6Pd175XNYRWrfi/9GsEsbiVy7E3YFpglUZFkAA/xLhxTe2T1rDmNYxSaj3f
NsVay/BmYaTAEfJocg2BA+BJAH/54I8RHU/liSZ/2IgaD7GvtarVAwIDAQABo1Mw
UTAdBgNVHQ4EFgQUrzgQkOIljys05OiTGdfVUEmVxHgwHwYDVR0jBBgwFoAUrzgQ
kOIljys05OiTGdfVUEmVxHgwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsF
AAOCAQEAU70INtsiEg2rluqYuTwGapkSLy/bttheYTeV74wCrk7wPJ7W+Ej78yvw
OZ1MxJp/9xGEg50aiH91b1Fp8C0i98KLjZyX1etSUM8e6dwRIGXdRXDnPljZaDwP
Nf1+Oyp6zDP2ftc/P+PV3qg5kZWeaLWwHspQJHRbw2n/J0nnFRgnWR8yWyRkuePT
BU58ssKjkX/MxJxZYah7VDbCimhK+kni+S/5TdOQoXeoBb9n3Kg8kPsqAta3yfdr
os8/M689mEObA+rT7IV0qjOaGEM4FGlVO/IpZfkgKj7XBIC0SjyASvoyBAP6b24P
vdpHuZ8q1lEbC1C1CJkWBhYXPzH+yg==
-----END CERTIFICATE-----"""

CertBlocklisted_PEM = """-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIUEA1WmRKjfteEKeK61CalFRE8yrYwDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPQ2VydEJsb2NrbGlzdGVkMB4XDTI2MTExMTE5NDk0MloX
DTM2MTEwODE5NDk0MlowGjEYMBYGA1UEAwwPQ2VydEJsb2NrbGlzdGVkMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3nQLwmY3+KYmVX8xrDxqKC+V98PB
wIHtgBomLB0n6aOgYhIkqiFVg/6h7oSgEQVkp0uxDir/ddF+2I8AGq3L+Z6Y4j/t
usfjw86XatfiOIzgzMNpVK0/YZXairE/yYMxAw8KvKBx5x9KB5WXnSWSHlJ3LcI+
NcEaKuJArDa9LwZ3UKnTwUOp56MswKKtEnf1rLc8J1h5GTAgqLxoecmrdvyuMPPk
JbDZmo5WSZAHKwZAATWbnbjzlZ+ip6s2pnIBQUPkaVsuJnIXi7DM84SHjg4BGUy1
QAH2fQtTWm+z8h1fOK3cYqGrjRw1acI/beG9DfbCRapDTkY/m/1doahgbQIDAQAB
o1MwUTAdBgNVHQ4EFgQUnOC6KeKbhCRbQ9ghKEehPtldj2wwHwYDVR0jBBgwFoAU
nOC6KeKbhCRbQ9ghKEehPtldj2wwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAhL8ZtkAwX00xH4AX7YARhGbk5MlNHocPnLJYEjZebVS29I0vyELL
JYZB0uSLRw2dGMQJO6X8XCd6nqWRXSopZgPi5x202pOw9mgW9XiX6RCBwvbtx4gQ
qmt5tmG4F29U50J7XdXBawYNnEEPQsttjtwnfXrseJLyV7ESYD7aXUwZVQEjbC9Q
hP+UhAyUYQP0mm5yVSk3Z6QC5YGSbkJAxyZPVCITCP/8wf2wFBywMi9g9U3nm7QY
j6zBC5N4n3aTmpWT8RH6lxfWv7oRhlzj27G4VUKfKNp13qsRjbmHa2J2jF9TdAH2
v1/I5peahraXEDqxxLS7DVOxSsF/bFOxzQ==
-----END CERTIFICATE-----"""


def find_runfile(path: str) -> str:
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "_main")
    if test_srcdir:
        candidates = [
            os.path.join(test_srcdir, test_workspace, path),
            os.path.join(test_srcdir, path),
            os.path.join(test_srcdir, "rules_dnfo", path),
        ]
        for c in candidates:
            if os.path.exists(c):
                return c
    if os.path.exists(path):
        return path
    for root, _, files in os.walk("."):
        if os.path.basename(path) in files:
            return os.path.join(root, os.path.basename(path))
    raise FileNotFoundError(f"Cannot find runfile for {path}")


class TestP11KitExtractGolden(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bundle_file = find_runfile("dnfo/private/test_ca_certificates_pki/usr/share/pki/ca-trust-source/ca-bundle.trust.p11-kit")
        with open(bundle_file, "r", encoding="utf-8") as f:
            cls.bundle_content = f.read()

    def test_golden_server_auth_count_and_fingerprints(self):
        ders = parse_p11_kit_bundle(self.bundle_content, "server-auth")
        # Real ca-certificates bundle yields exactly 118 server-auth root CAs
        self.assertEqual(len(ders), 118)

        # Verify all fingerprints are unique
        fps = set(hashlib.sha256(d).hexdigest() for d in ders)
        self.assertEqual(len(fps), 118)

        # Verify Izenpe.com root certificate is included
        has_izenpe = any(b"Izenpe" in d for d in ders)
        self.assertTrue(has_izenpe, "Expected Izenpe.com root CA to be included")

    def test_code_signing_ec_acc_skipped_with_warning(self):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            ders = parse_p11_kit_bundle(self.bundle_content, "code-signing")

        warning_output = buf.getvalue()
        self.assertIn(
            "Warning: skipping certificate 'EC-ACC' with negative serial number (Go x509 compatibility)",
            warning_output,
        )
        # Verify EC-ACC is not present in output
        self.assertFalse(any(b"EC-ACC" in d for d in ders))


class TestP11KitExtractEdgeCases(unittest.TestCase):
    def test_cert_without_eku_extension_is_trusted_for_all_purposes(self):
        p11_kit = f"""
[p11-kit-object-v1]
class: certificate
label: "Root Without EKU"
trusted: true
x-distrusted: false
{CertNoEku_PEM}
"""
        for purpose in ["server-auth", "email", "code-signing"]:
            ders = parse_p11_kit_bundle(p11_kit, purpose)
            self.assertEqual(len(ders), 1, f"Expected cert without EKU to be trusted for {purpose}")

    def test_literally_encoded_and_percent_encoded_eku_value(self):
        # Percent-encoded serverAuth OID (06 08 2b 06 01 05 05 07 03 01)
        p11_kit_pct = f"""
[p11-kit-object-v1]
class: certificate
label: "CertA"
trusted: true
x-distrusted: false
{CertA_PEM}

[p11-kit-object-v1]
class: x-certificate-extension
label: "CertA"
object-id: 2.5.29.37
value: "%30%14%06%08%2b%06%01%05%05%07%03%01"
{CertA_PUBKEY}
"""
        ders_pct = parse_p11_kit_bundle(p11_kit_pct, "server-auth")
        self.assertEqual(len(ders_pct), 1)

        # Literally-encoded value with DER bytes
        literal_val = '0\x14\x06\x08+\x06\x01\x05\x05\x07\x03\x01'
        p11_kit_literal = f"""
[p11-kit-object-v1]
class: certificate
label: "CertA"
trusted: true
x-distrusted: false
{CertA_PEM}

[p11-kit-object-v1]
class: x-certificate-extension
label: "CertA"
object-id: 2.5.29.37
value: "{literal_val}"
{CertA_PUBKEY}
"""
        ders_literal = parse_p11_kit_bundle(p11_kit_literal, "server-auth")
        self.assertEqual(len(ders_literal), 1)

    def test_eku_matched_by_public_key_when_labels_repeat(self):
        # CertA and CertB share the exact same label "Shared Label"
        # But have different public keys: CertA is server-auth, CertB is email.
        p11_kit = f"""
[p11-kit-object-v1]
class: certificate
label: "Shared Label"
trusted: true
x-distrusted: false
{CertA_PEM}

[p11-kit-object-v1]
class: x-certificate-extension
label: "Shared Label"
object-id: 2.5.29.37
value: "%30%14%06%08%2b%06%01%05%05%07%03%01"
{CertA_PUBKEY}

[p11-kit-object-v1]
class: certificate
label: "Shared Label"
trusted: true
x-distrusted: false
{CertB_PEM}

[p11-kit-object-v1]
class: x-certificate-extension
label: "Shared Label"
object-id: 2.5.29.37
value: "%30%14%06%08%2b%06%01%05%05%07%03%04"
{CertB_PUBKEY}
"""
        ders_server = parse_p11_kit_bundle(p11_kit, "server-auth")
        self.assertEqual(len(ders_server), 1)
        # Should be CertA, not CertB
        pems_server = extract_pems_from_raw(CertA_PEM)
        self.assertIn(b"CertA", ders_server[0])

        ders_email = parse_p11_kit_bundle(p11_kit, "email")
        self.assertEqual(len(ders_email), 1)
        # Should be CertB, not CertA
        self.assertIn(b"CertB", ders_email[0])

    def test_x_distrusted_excluded(self):
        p11_kit = f"""
[p11-kit-object-v1]
class: certificate
label: "Distrusted CA"
trusted: true
x-distrusted: true
{CertDistrusted_PEM}
"""
        ders = parse_p11_kit_bundle(p11_kit, "server-auth")
        self.assertEqual(len(ders), 0)

    def test_blocklist_directory_excluded(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            blocklist_dir = os.path.join(tmpdir, "blocklist")
            os.makedirs(blocklist_dir, exist_ok=True)
            with open(os.path.join(blocklist_dir, "blocked.pem"), "w") as f:
                f.write(CertBlocklisted_PEM + "\n")

            bundle_file = os.path.join(tmpdir, "test.p11-kit")
            with open(bundle_file, "w") as f:
                f.write(f"""
[p11-kit-object-v1]
class: certificate
label: "Blocked in Dir"
trusted: true
x-distrusted: false
{CertBlocklisted_PEM}

[p11-kit-object-v1]
class: certificate
label: "Allowed Cert"
trusted: true
x-distrusted: false
{CertA_PEM}
""")

            extracted_pems = process_inputs([tmpdir], "server-auth")
            # Only CertA should remain; CertBlocklisted should be excluded
            self.assertEqual(len(extracted_pems), 1)
            self.assertIn("BEGIN CERTIFICATE", extracted_pems[0])
            import base64
            der = base64.b64decode("".join(extracted_pems[0].splitlines()[1:-1]))
            self.assertIn(b"CertA", der)


if __name__ == "__main__":
    unittest.main()
