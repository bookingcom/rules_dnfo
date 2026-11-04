package dnfo

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
)

// GPGKey represents an OpenPGP public key or subkey.
type GPGKey struct {
	KeyID       string // 16-hex characters lowercase
	Fingerprint string // 40-hex characters lowercase
	IsSubkey    bool
}

// Keyring manages a set of trusted GPG keys.
type Keyring struct {
	Keys map[string]GPGKey // Keyed by 16-char KeyID
}

// NewKeyring creates an empty Keyring.
func NewKeyring() *Keyring {
	return &Keyring{
		Keys: make(map[string]GPGKey),
	}
}

// HasKey returns true if the Key ID is in the keyring.
func (kr *Keyring) HasKey(keyID string) bool {
	keyID = strings.ToLower(keyID)
	_, exists := kr.Keys[keyID]
	return exists
}

// AddKey parses ASCII-armored or raw binary OpenPGP public key data and adds all keys/subkeys.
func (kr *Keyring) AddKey(data []byte) error {
	content := string(data)
	if strings.Contains(content, "-----BEGIN PGP PUBLIC KEY BLOCK-----") {
		// ASCII armored
		re := regexp.MustCompile(`(?s)-----BEGIN PGP PUBLIC KEY BLOCK-----(.*?)-----END PGP PUBLIC KEY BLOCK-----`)
		matches := re.FindAllStringSubmatch(content, -1)
		if len(matches) == 0 {
			return fmt.Errorf("no valid PGP PUBLIC KEY BLOCK found in armored data")
		}
		for _, m := range matches {
			blockText := m[1]
			var b64Buf bytes.Buffer
			for _, line := range strings.Split(blockText, "\n") {
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "=") || strings.Contains(line, ":") {
					continue
				}
				b64Buf.WriteString(line)
			}
			raw, err := base64.StdEncoding.DecodeString(b64Buf.String())
			if err != nil {
				return fmt.Errorf("failed to decode base64 PGP block: %w", err)
			}
			if err := kr.parseBinaryPackets(raw); err != nil {
				return err
			}
		}
		return nil
	}
	// Raw binary OpenPGP packets
	return kr.parseBinaryPackets(data)
}

func (kr *Keyring) parseBinaryPackets(data []byte) error {
	idx := 0
	for idx < len(data) {
		b := data[idx]
		if (b & 0x80) == 0 {
			break
		}
		idx++

		var tag int
		var pktLen int

		if (b & 0x40) != 0 {
			// New format header
			tag = int(b & 0x3f)
			if idx >= len(data) {
				break
			}
			firstLen := int(data[idx])
			idx++
			if firstLen < 192 {
				pktLen = firstLen
			} else if firstLen < 224 {
				if idx >= len(data) {
					break
				}
				pktLen = ((firstLen - 192) << 8) + int(data[idx]) + 192
				idx++
			} else if firstLen == 255 {
				if idx+4 > len(data) {
					break
				}
				pktLen = int(binary.BigEndian.Uint32(data[idx : idx+4]))
				idx += 4
			} else {
				pktLen = len(data) - idx
			}
		} else {
			// Old format header
			tag = int((b >> 2) & 0x0f)
			lenType := b & 0x03
			switch lenType {
			case 0:
				if idx >= len(data) {
					break
				}
				pktLen = int(data[idx])
				idx++
			case 1:
				if idx+2 > len(data) {
					break
				}
				pktLen = int(binary.BigEndian.Uint16(data[idx : idx+2]))
				idx += 2
			case 2:
				if idx+4 > len(data) {
					break
				}
				pktLen = int(binary.BigEndian.Uint32(data[idx : idx+4]))
				idx += 4
			case 3:
				pktLen = len(data) - idx
			}
		}

		if idx+pktLen > len(data) {
			break
		}
		body := data[idx : idx+pktLen]
		idx += pktLen

		// Tag 6 is Public-Key Packet, Tag 14 is Public-Subkey Packet
		if tag == 6 || tag == 14 {
			if len(body) > 0 && body[0] == 4 { // Version 4 key
				h := sha1.New()
				prefix := []byte{0x99, byte(len(body) >> 8), byte(len(body) & 0xff)}
				h.Write(prefix)
				h.Write(body)
				fpBytes := h.Sum(nil)
				fpHex := hex.EncodeToString(fpBytes)
				keyID := fpHex[len(fpHex)-16:]
				kr.Keys[keyID] = GPGKey{
					KeyID:       keyID,
					Fingerprint: fpHex,
					IsSubkey:    (tag == 14),
				}
			}
		}
	}
	return nil
}

// AddKeyFromURLOrFile fetches key from HTTP(S) URL or reads from local file.
func (kr *Keyring) AddKeyFromURLOrFile(urlOrPath string) error {
	if strings.HasPrefix(urlOrPath, "http://") || strings.HasPrefix(urlOrPath, "https://") {
		resp, err := http.Get(urlOrPath)
		if err != nil {
			return fmt.Errorf("failed to fetch GPG key from %s: %w", urlOrPath, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("HTTP error %d fetching GPG key from %s", resp.StatusCode, urlOrPath)
		}
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("failed reading GPG key response from %s: %w", urlOrPath, err)
		}
		return kr.AddKey(data)
	}

	data, err := os.ReadFile(urlOrPath)
	if err != nil {
		return fmt.Errorf("failed reading GPG key file %s: %w", urlOrPath, err)
	}
	return kr.AddKey(data)
}

// ExtractRPMSignatureKeyID parses the RPM lead and signature header to extract the signing Key ID.
func ExtractRPMSignatureKeyID(r io.ReaderAt) (string, error) {
	lead := make([]byte, 96)
	if _, err := r.ReadAt(lead, 0); err != nil {
		return "", fmt.Errorf("failed reading RPM lead: %w", err)
	}
	if !bytes.Equal(lead[:4], []byte{0xed, 0xab, 0xee, 0xdb}) {
		return "", fmt.Errorf("invalid RPM lead magic")
	}

	hdrInfo := make([]byte, 16)
	if _, err := r.ReadAt(hdrInfo, 96); err != nil {
		return "", fmt.Errorf("failed reading signature header magic: %w", err)
	}
	if !bytes.Equal(hdrInfo[:3], []byte{0x8e, 0xad, 0xe8}) {
		return "", fmt.Errorf("invalid RPM header magic: %x", hdrInfo[:3])
	}

	nindex := binary.BigEndian.Uint32(hdrInfo[8:12])
	nbytes := binary.BigEndian.Uint32(hdrInfo[12:16])

	indexBuf := make([]byte, nindex*16)
	if _, err := r.ReadAt(indexBuf, 96+16); err != nil {
		return "", fmt.Errorf("failed reading signature index entries: %w", err)
	}

	dataOffset := int64(96 + 16 + nindex*16)
	dataBuf := make([]byte, nbytes)
	if _, err := r.ReadAt(dataBuf, dataOffset); err != nil {
		return "", fmt.Errorf("failed reading signature data section: %w", err)
	}

	for i := uint32(0); i < nindex; i++ {
		entry := indexBuf[i*16 : (i+1)*16]
		tag := binary.BigEndian.Uint32(entry[0:4])
		offset := binary.BigEndian.Uint32(entry[8:12])
		count := binary.BigEndian.Uint32(entry[12:16])

		// 268 = RPMTAG_RSAHEADER, 1002 = RPMTAG_SIGPGP
		if tag == 268 || tag == 1002 {
			if offset+count > nbytes {
				continue
			}
			sigPkt := dataBuf[offset : offset+count]
			keyID := parseSigPacketKeyID(sigPkt)
			if keyID != "" {
				return keyID, nil
			}
		}
	}

	return "", fmt.Errorf("no OpenPGP signature found in RPM header")
}

func parseSigPacketKeyID(sigPkt []byte) string {
	if len(sigPkt) < 10 {
		return ""
	}
	b0 := sigPkt[0]
	idx := 1
	if (b0 & 0x40) != 0 {
		// New format packet
		firstLen := int(sigPkt[idx])
		idx++
		if firstLen < 192 {
			// 1-byte length
		} else if firstLen < 224 {
			idx++
		} else if firstLen == 255 {
			idx += 4
		}
	} else {
		// Old format packet
		lenType := b0 & 0x03
		idx += (1 << lenType)
	}

	if idx >= len(sigPkt) || sigPkt[idx] != 4 {
		return ""
	}
	idx++ // version (4)
	if idx+4 > len(sigPkt) {
		return ""
	}
	idx += 3 // sig type (1), pubkey algo (1), hash algo (1)

	// Hashed subpackets
	hashedLen := int(binary.BigEndian.Uint16(sigPkt[idx : idx+2]))
	idx += 2
	if idx+hashedLen > len(sigPkt) {
		return ""
	}
	hashedData := sigPkt[idx : idx+hashedLen]
	idx += hashedLen

	// Check hashed subpackets first
	if k := scanSubpacketsForKeyID(hashedData); k != "" {
		return k
	}

	// Unhashed subpackets
	if idx+2 > len(sigPkt) {
		return ""
	}
	unhashedLen := int(binary.BigEndian.Uint16(sigPkt[idx : idx+2]))
	idx += 2
	if idx+unhashedLen > len(sigPkt) {
		return ""
	}
	unhashedData := sigPkt[idx : idx+unhashedLen]

	return scanSubpacketsForKeyID(unhashedData)
}

func scanSubpacketsForKeyID(subData []byte) string {
	uIdx := 0
	for uIdx < len(subData) {
		sLen := int(subData[uIdx])
		if sLen == 0 || uIdx+1 >= len(subData) {
			break
		}
		sType := subData[uIdx+1] & 0x7f
		if uIdx+1+sLen > len(subData) {
			break
		}
		sBody := subData[uIdx+2 : uIdx+1+sLen]

		// Type 16 (0x10) is Issuer Key ID (8 bytes)
		if sType == 16 && len(sBody) == 8 {
			return strings.ToLower(hex.EncodeToString(sBody))
		}
		// Type 33 (0x21) is Issuer Fingerprint (1 byte version + 20 bytes for V4)
		if sType == 33 && len(sBody) >= 21 && sBody[0] == 4 {
			fp := sBody[1:21]
			return strings.ToLower(hex.EncodeToString(fp[12:20]))
		}

		uIdx += 1 + sLen
	}
	return ""
}

// ValidateRPMSignature extracts the Key ID from an RPM and checks it against the Keyring.
func ValidateRPMSignature(r io.ReaderAt, kr *Keyring) (string, error) {
	keyID, err := ExtractRPMSignatureKeyID(r)
	if err != nil {
		return "", err
	}
	if !kr.HasKey(keyID) {
		return keyID, fmt.Errorf("package signature key ID %s is not present in trusted keyring", keyID)
	}
	return keyID, nil
}
