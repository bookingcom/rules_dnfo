package dnfo

import (
	"bytes"
	"strings"
	"testing"
)

func TestLockFileSerialization(t *testing.T) {
	jsonInput := `{
  "version": 1,
  "arch": "x86_64",
  "requested": ["bash"],
  "packages": [
    {
      "name": "bash",
      "version": "5.2.26-3.el10",
      "arch": "x86_64",
      "url": "https://yum.oracle.com/bash.rpm",
      "integrity": "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
      "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }
  ]
}`
	lock, err := LoadLockFile(strings.NewReader(jsonInput))
	if err != nil {
		t.Fatalf("LoadLockFile failed: %v", err)
	}
	if lock.Arch != "x86_64" {
		t.Errorf("Expected arch x86_64, got %s", lock.Arch)
	}
	if len(lock.Packages) != 1 || lock.Packages[0].Name != "bash" {
		t.Errorf("Unexpected packages: %+v", lock.Packages)
	}

	var buf bytes.Buffer
	if err := lock.Save(&buf); err != nil {
		t.Fatalf("Save failed: %v", err)
	}
	if !strings.Contains(buf.String(), `"name": "bash"`) {
		t.Errorf("Serialized output missing package name: %s", buf.String())
	}
}
