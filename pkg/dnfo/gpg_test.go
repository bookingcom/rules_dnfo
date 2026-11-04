package dnfo

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

const sampleArmoredPGPKey = `-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGHncu8BEAC2dhocMZkdapnP9o/MvAnKOczaSpF4Cj9yqt49bxLPJCY57jz9
2ZkJ5iGk6kpBt4rPTh18aAl30T+nPP8VMQjMhvHJKfZmBtaJJ5RpvvpK5mj1UgRJ
4DQX7gqAbT0s/uZZcouZsJzXo3c7GNMrim1C+ScfGG6BoB6GVBK74jFeJNMsxZ2Y
5q+eI80xG44fLg/fQ3+f4Y+5Y/u/lH7zL+dF+t9D+a8d+f4+f4=
-----END PGP PUBLIC KEY BLOCK-----`

func TestKeyringParsing(t *testing.T) {
	kr := NewKeyring()
	// Test parsing the real Oracle Linux 9 key from /tmp/RPM-GPG-KEY-oracle-ol9 if available
	keyData, err := os.ReadFile("/tmp/RPM-GPG-KEY-oracle-ol9")
	if err == nil {
		if err := kr.AddKey(keyData); err != nil {
			t.Fatalf("AddKey failed on real key: %v", err)
		}
		// Expect primary key bc4d06a08d8b756f
		if !kr.HasKey("bc4d06a08d8b756f") {
			t.Errorf("Expected keyring to contain bc4d06a08d8b756f, keys present: %+v", kr.Keys)
		}
	}
}

func TestRPMValidationWithFixture(t *testing.T) {
	rpmPath := "../dnf5-prebuilt/e2e/smoke_test/testdata/ol9_repo/curl-7.76.1-40.el9_8.8.x86_64.rpm"
	// Check relative from workspace or test runfiles
	absPath, err := filepath.Abs(rpmPath)
	if err != nil {
		t.Skip("Cannot resolve path to test fixture RPM")
	}
	f, err := os.Open(absPath)
	if err != nil {
		t.Skipf("Test fixture RPM not found at %s: %v", absPath, err)
	}
	defer f.Close()

	keyID, err := ExtractRPMSignatureKeyID(f)
	if err != nil {
		t.Fatalf("ExtractRPMSignatureKeyID failed: %v", err)
	}
	if keyID != "bc4d06a08d8b756f" {
		t.Errorf("Expected key ID bc4d06a08d8b756f, got %s", keyID)
	}

	// Test with trusted keyring
	kr := NewKeyring()
	kr.Keys["bc4d06a08d8b756f"] = GPGKey{KeyID: "bc4d06a08d8b756f"}
	verifiedID, err := ValidateRPMSignature(f, kr)
	if err != nil {
		t.Fatalf("ValidateRPMSignature failed: %v", err)
	}
	if verifiedID != "bc4d06a08d8b756f" {
		t.Errorf("Expected verified ID bc4d06a08d8b756f, got %s", verifiedID)
	}

	// Test with untrusted keyring (negative test)
	badKr := NewKeyring()
	badKr.Keys["1234567890abcdef"] = GPGKey{KeyID: "1234567890abcdef"}
	_, err = ValidateRPMSignature(f, badKr)
	if err == nil {
		t.Fatalf("Expected validation error for untrusted key, but got nil")
	}
}

func TestInvalidRPMLead(t *testing.T) {
	kr := NewKeyring()
	invalidRPM := bytes.NewReader([]byte("not an rpm file"))
	_, err := ValidateRPMSignature(invalidRPM, kr)
	if err == nil {
		t.Fatalf("Expected error for non-RPM data, got nil")
	}
}
