package dnfo

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// LockedPackage defines a resolved and locked RPM package artifact.
type LockedPackage struct {
	Name            string   `json:"name"`
	Version         string   `json:"version"`
	Arch            string   `json:"arch"`
	Nevra           string   `json:"nevra,omitempty"`
	URL             string   `json:"url"`
	Integrity       string   `json:"integrity"`
	Checksum        string   `json:"checksum"`
	GPGKeyID        string   `json:"gpg_key_id,omitempty"`
	SignatureStatus string   `json:"signature_status,omitempty"`
	Dependencies    []string `json:"dependencies,omitempty"`
	Recommends      []string `json:"recommends,omitempty"`
}

// LockFile represents the JSON structure of a dnfo lockfile.
type LockFile struct {
	Version   int             `json:"version"`
	Arch      string          `json:"arch"`
	Config    string          `json:"config,omitempty"`
	Requested []string        `json:"requested"`
	Packages  []LockedPackage `json:"packages"`
}

// LoadLockFile parses a LockFile from a reader.
func LoadLockFile(r io.Reader) (*LockFile, error) {
	var lock LockFile
	dec := json.NewDecoder(r)
	if err := dec.Decode(&lock); err != nil {
		return nil, fmt.Errorf("failed to decode lockfile: %w", err)
	}
	return &lock, nil
}

// LoadLockFilePath parses a LockFile from a filesystem path.
func LoadLockFilePath(path string) (*LockFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open lockfile %s: %w", path, err)
	}
	defer f.Close()
	return LoadLockFile(f)
}

// Save writes the LockFile in formatted JSON to the specified writer.
func (lf *LockFile) Save(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(lf); err != nil {
		return fmt.Errorf("failed to encode lockfile: %w", err)
	}
	return nil
}

// SaveFile writes the LockFile to a file path.
func (lf *LockFile) SaveFile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("failed to create lockfile %s: %w", path, err)
	}
	defer f.Close()
	return lf.Save(f)
}
