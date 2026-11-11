#!/usr/bin/env python3
"""p11_kit_extract: extracts and filters CA certificates from PKI directories or p11-kit bundles."""

import argparse
import base64
import os
import sys
import urllib.parse

# Full DER-encoded Extended Key Usage (EKU) Object Identifiers:
# 1.3.6.1.5.5.7.3.1 (serverAuth)
SERVER_AUTH_OID_DER = bytes.fromhex("06082b06010505070301")
# 1.3.6.1.5.5.7.3.4 (emailProtection)
EMAIL_OID_DER = bytes.fromhex("06082b06010505070304")
# 1.3.6.1.5.5.7.3.3 (codeSigning)
CODE_SIGNING_OID_DER = bytes.fromhex("06082b06010505070303")

PURPOSE_OIDS_DER = {
    "server-auth": SERVER_AUTH_OID_DER,
    "email": EMAIL_OID_DER,
    "code-signing": CODE_SIGNING_OID_DER,
}


def get_der_length(data: bytes, pos: int) -> tuple[int, int]:
    """Decodes ASN.1 DER length starting at pos. Returns (length, next_pos)."""
    if pos >= len(data):
        return 0, pos
    b = data[pos]
    if b < 0x80:
        return b, pos + 1
    num_bytes = b & 0x7F
    pos += 1
    length = 0
    for _ in range(num_bytes):
        if pos >= len(data):
            break
        length = (length << 8) | data[pos]
        pos += 1
    return length, pos


def extract_spki_der(cert_der: bytes) -> bytes | None:
    """Extracts SubjectPublicKeyInfo DER bytes from an X.509 Certificate DER."""
    try:
        if not cert_der or cert_der[0] != 0x30:
            return None
        pos = 1
        _, pos = get_der_length(cert_der, pos)
        # TBSCertificate SEQUENCE (0x30)
        if cert_der[pos] != 0x30:
            return None
        _, tbs_start = get_der_length(cert_der, pos + 1)
        pos = tbs_start
        # version [0] EXPLICIT (optional)
        if cert_der[pos] == 0xA0:
            v_len, pos = get_der_length(cert_der, pos + 1)
            pos += v_len
        # serialNumber INTEGER (0x02)
        if cert_der[pos] != 0x02:
            return None
        s_len, pos = get_der_length(cert_der, pos + 1)
        pos += s_len
        # signature AlgorithmIdentifier SEQUENCE (0x30)
        if cert_der[pos] != 0x30:
            return None
        sig_len, pos = get_der_length(cert_der, pos + 1)
        pos += sig_len
        # issuer Name SEQUENCE (0x30)
        if cert_der[pos] != 0x30:
            return None
        iss_len, pos = get_der_length(cert_der, pos + 1)
        pos += iss_len
        # validity Validity SEQUENCE (0x30)
        if cert_der[pos] != 0x30:
            return None
        val_len, pos = get_der_length(cert_der, pos + 1)
        pos += val_len
        # subject Name SEQUENCE (0x30)
        if cert_der[pos] != 0x30:
            return None
        sub_len, pos = get_der_length(cert_der, pos + 1)
        pos += sub_len
        # subjectPublicKeyInfo SubjectPublicKeyInfo SEQUENCE (0x30)
        spki_start = pos
        if cert_der[pos] != 0x30:
            return None
        spki_len, pos = get_der_length(cert_der, pos + 1)
        return cert_der[spki_start : pos + spki_len]
    except Exception:
        return None


def is_negative_serial(cert_der: bytes) -> bool:
    """Checks whether the certificate serial number is negative in two's complement ASN.1."""
    try:
        if not cert_der or cert_der[0] != 0x30:
            return False
        pos = 1
        _, pos = get_der_length(cert_der, pos)
        _, tbs_start = get_der_length(cert_der, pos + 1)
        pos = tbs_start
        if cert_der[pos] == 0xA0:
            v_len, pos = get_der_length(cert_der, pos + 1)
            pos += v_len
        if cert_der[pos] != 0x02:
            return False
        _, pos = get_der_length(cert_der, pos + 1)
        return bool(cert_der[pos] & 0x80)
    except Exception:
        return False


def extract_pems_from_raw(data: str) -> list[bytes]:
    """Extracts all PEM certificate blocks from raw text as DER bytes."""
    res = []
    pos = 0
    while True:
        start = data.find("-----BEGIN CERTIFICATE-----", pos)
        if start == -1:
            break
        b64_start = start + len("-----BEGIN CERTIFICATE-----")
        end = data.find("-----END CERTIFICATE-----", b64_start)
        if end == -1:
            break
        b64_content = data[b64_start:end].replace("\r", "").replace("\n", "").strip()
        try:
            der = base64.b64decode(b64_content)
            res.append(der)
        except Exception:
            pass
        pos = end + len("-----END CERTIFICATE-----")
    return res


def der_to_pem(der_bytes: bytes) -> str:
    """Converts DER bytes into canonical PEM format with 64-character lines."""
    b64 = base64.b64encode(der_bytes).decode("ascii")
    lines = [b64[i : i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----"


def parse_p11_kit_bundle(
    content: str,
    purpose: str,
    blocklisted_ders: set[bytes] | None = None,
) -> list[bytes]:
    """Parses a p11-kit bundle and returns DER certificates filtered by purpose."""
    if blocklisted_ders is None:
        blocklisted_ders = set()

    stanzas = content.split("[p11-kit-object-v1]")
    target_oid_der = PURPOSE_OIDS_DER.get(purpose)

    # 1. Index EKU extensions by SubjectPublicKeyInfo (SPKI)
    # In p11-kit format, each extension object specifies:
    # class: x-certificate-extension
    # object-id: 2.5.29.37 (EKU)
    # value: "<url-encoded DER octet string>"
    # -----BEGIN PUBLIC KEY----- ... -----END PUBLIC KEY-----
    ekus_by_spki: dict[bytes, bytes] = {}
    for s in stanzas[1:]:
        if "class: x-certificate-extension" in s and "object-id: 2.5.29.37" in s:
            if "-----BEGIN PUBLIC KEY-----" not in s:
                continue
            pk_start = s.find("-----BEGIN PUBLIC KEY-----") + len("-----BEGIN PUBLIC KEY-----")
            pk_end = s.find("-----END PUBLIC KEY-----", pk_start)
            if pk_end == -1:
                continue
            pk_b64 = s[pk_start:pk_end].replace("\r", "").replace("\n", "").strip()
            try:
                spki_der = base64.b64decode(pk_b64)
            except Exception:
                continue

            val_bytes = None
            for line in s.splitlines():
                if line.startswith("value:"):
                    raw_val = line.split(":", 1)[1].strip().strip('"')
                    try:
                        val_bytes = urllib.parse.unquote_to_bytes(raw_val)
                    except Exception:
                        val_bytes = None
                    break

            if val_bytes:
                ekus_by_spki[spki_der] = val_bytes

    # 2. Extract certificates
    matched_ders: list[bytes] = []
    for s in stanzas[1:]:
        if "-----BEGIN CERTIFICATE-----" not in s:
            continue

        lines = {
            line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
            for line in s.splitlines()
            if ":" in line and not line.startswith("#") and not line.startswith("-----")
        }

        # Check trust and distrust flags
        trusted = lines.get("trusted", "false").lower() == "true"
        if not trusted:
            continue
        if lines.get("x-distrusted", "false").lower() == "true" or lines.get("distrusted", "false").lower() == "true":
            # Record blocklisted DER
            start = s.find("-----BEGIN CERTIFICATE-----") + len("-----BEGIN CERTIFICATE-----")
            end = s.find("-----END CERTIFICATE-----", start)
            if end != -1:
                try:
                    der = base64.b64decode(s[start:end].replace("\r", "").replace("\n", "").strip())
                    blocklisted_ders.add(der)
                except Exception:
                    pass
            continue

        start = s.find("-----BEGIN CERTIFICATE-----") + len("-----BEGIN CERTIFICATE-----")
        end = s.find("-----END CERTIFICATE-----", start)
        if end == -1:
            continue
        cert_b64 = s[start:end].replace("\r", "").replace("\n", "").strip()
        try:
            cert_der = base64.b64decode(cert_b64)
        except Exception:
            continue

        label = lines.get("label", "").strip('"')

        # Check Go x509 compatibility: skip negative serial numbers with warning
        if is_negative_serial(cert_der):
            sys.stderr.write(
                f"Warning: skipping certificate '{label}' with negative serial number (Go x509 compatibility)\n"
            )
            continue

        # Match EKU by public key
        # If certificate has an EKU extension associated with its SPKI, it is only trusted
        # for purposes matching the EKU extension.
        # If certificate has NO EKU extension associated with its SPKI, it is trusted for all purposes.
        spki_der = extract_spki_der(cert_der)
        if spki_der and spki_der in ekus_by_spki:
            if target_oid_der and target_oid_der not in ekus_by_spki[spki_der]:
                continue

        matched_ders.append(cert_der)

    return [d for d in matched_ders if d not in blocklisted_ders]


def process_directory(
    dir_path: str,
    purpose: str,
    blocklisted_ders: set[bytes],
) -> list[bytes]:
    """Processes an extracted PKI directory tree, collecting certificates and blocklists."""
    # 1. First pass: load blocklist certificates if present
    for root, _, files in os.walk(dir_path):
        norm_root = root.replace("\\", "/")
        if norm_root.endswith("/blocklist") or "/blocklist/" in norm_root:
            for f in files:
                fpath = os.path.join(root, f)
                with open(fpath, "r", encoding="utf-8", errors="replace") as fp:
                    content = fp.read()
                blocklisted_ders.update(extract_pems_from_raw(content))

    # 2. Second pass: parse p11-kit bundles and anchor certificates
    matched: list[bytes] = []
    for root, _, files in os.walk(dir_path):
        norm_root = root.replace("\\", "/")
        if norm_root.endswith("/blocklist") or "/blocklist/" in norm_root:
            continue
        for f in files:
            fpath = os.path.join(root, f)
            if f.endswith(".p11-kit") or f.endswith(".p11-kit-trust"):
                with open(fpath, "r", encoding="utf-8", errors="replace") as fp:
                    content = fp.read()
                matched.extend(parse_p11_kit_bundle(content, purpose, blocklisted_ders))
            elif f.endswith(".crt") or f.endswith(".pem"):
                with open(fpath, "r", encoding="utf-8", errors="replace") as fp:
                    content = fp.read()
                matched.extend(extract_pems_from_raw(content))

    return [d for d in matched if d not in blocklisted_ders]


def process_inputs(input_paths: list[str], purpose: str) -> list[str]:
    """Extracts, filters, blocklist-checks, and deduplicates certificates from inputs."""
    blocklisted_ders: set[bytes] = set()
    raw_certs: list[bytes] = []

    for inp in input_paths:
        if os.path.isdir(inp):
            raw_certs.extend(process_directory(inp, purpose, blocklisted_ders))
        elif os.path.isfile(inp):
            with open(inp, "r", encoding="utf-8", errors="replace") as fp:
                content = fp.read()
            if "[p11-kit-object-v1]" in content:
                raw_certs.extend(parse_p11_kit_bundle(content, purpose, blocklisted_ders))
            else:
                raw_certs.extend(extract_pems_from_raw(content))

    # Filter out any blocklisted certs and deduplicate by DER bytes preserving order
    seen_der = set()
    deduped_pems: list[str] = []
    for c_der in raw_certs:
        if c_der in blocklisted_ders:
            continue
        if c_der not in seen_der:
            seen_der.add(c_der)
            deduped_pems.append(der_to_pem(c_der))

    return deduped_pems


def main():
    parser = argparse.ArgumentParser(description="Extract CA certificates from PKI directories or bundles.")
    parser.add_argument("--output", required=True, help="Output PEM file path.")
    parser.add_argument(
        "--purpose",
        default="server-auth",
        choices=["server-auth", "email", "code-signing"],
        help="Certificate purpose filter.",
    )
    parser.add_argument(
        "--input",
        dest="inputs",
        action="append",
        default=[],
        help="Path to extracted PKI directory or bundle file.",
    )

    args = parser.parse_args()

    deduped = process_inputs(args.inputs, args.purpose)
    if not deduped:
        sys.stderr.write(f"Error: no certificates found matching purpose '{args.purpose}' in {args.inputs}\n")
        sys.exit(1)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write("\n".join(deduped) + "\n")


if __name__ == "__main__":
    main()
