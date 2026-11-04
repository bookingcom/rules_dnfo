package dnfo

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// GeneratePasswd creates standard /etc/passwd contents for specified user accounts.
func GeneratePasswd(users []UserConfig) []byte {
	var buf bytes.Buffer
	// Default root entry
	buf.WriteString("root:x:0:0:root:/root:/bin/sh\n")
	hasRoot := false
	for _, u := range users {
		if u.UID == 0 {
			hasRoot = true
			break
		}
	}
	if hasRoot {
		buf.Reset()
	}
	for _, u := range users {
		home := u.HomeDir
		if home == "" {
			if u.UID == 0 {
				home = "/root"
			} else {
				home = "/home/" + u.UserName
			}
		}
		shell := u.Shell
		if shell == "" {
			shell = "/bin/sh"
		}
		fmt.Fprintf(&buf, "%s:x:%d:%d:%s:%s:%s\n", u.UserName, u.UID, u.GID, u.UserName, home, shell)
	}
	return buf.Bytes()
}

// GenerateGroup creates standard /etc/group contents for specified group accounts.
func GenerateGroup(groups []GroupConfig) []byte {
	var buf bytes.Buffer
	buf.WriteString("root:x:0:\n")
	hasRoot := false
	for _, g := range groups {
		if g.GID == 0 {
			hasRoot = true
			break
		}
	}
	if hasRoot {
		buf.Reset()
	}
	for _, g := range groups {
		members := strings.Join(g.Members, ",")
		fmt.Fprintf(&buf, "%s:x:%d:%s\n", g.GroupName, g.GID, members)
	}
	return buf.Bytes()
}

// OCI Config and Manifest structures.
type OCIIndex struct {
	SchemaVersion int             `json:"schemaVersion"`
	Manifests     []OCIDescriptor `json:"manifests"`
}

type OCIDescriptor struct {
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Size      int64  `json:"size"`
}

type OCIManifest struct {
	SchemaVersion int             `json:"schemaVersion"`
	MediaType     string          `json:"mediaType"`
	Config        OCIDescriptor   `json:"config"`
	Layers        []OCIDescriptor `json:"layers"`
	Annotations   map[string]string `json:"annotations,omitempty"`
}

type OCIContainerConfig struct {
	User       string              `json:"User,omitempty"`
	Env        []string            `json:"Env,omitempty"`
	Entrypoint []string            `json:"Entrypoint,omitempty"`
	Cmd        []string            `json:"Cmd,omitempty"`
	WorkingDir string              `json:"WorkingDir,omitempty"`
	Labels     map[string]string   `json:"Labels,omitempty"`
}

type OCIImageConfig struct {
	Architecture string             `json:"architecture"`
	OS           string             `json:"os"`
	Config       OCIContainerConfig `json:"config"`
	RootFS       OCIRootFS          `json:"rootfs"`
}

type OCIRootFS struct {
	Type    string   `json:"type"`
	DiffIDs []string `json:"diff_ids"`
}

// BuildLayerTar creates a base filesystem tarball including accounts and base directory structure.
func BuildLayerTar(cfg *ImageConfig, extraFiles map[string][]byte) ([]byte, string, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	zeroTime := time.Unix(0, 0)

	baseDirs := []string{
		"dev", "proc", "sys", "tmp", "etc", "var", "var/tmp", "home", "root",
	}
	for _, d := range baseDirs {
		mode := int64(0755)
		if d == "tmp" || d == "var/tmp" {
			mode = 01777
		}
		hdr := &tar.Header{
			Name:     d,
			Typeflag: tar.TypeDir,
			Mode:     mode,
			ModTime:  zeroTime,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, "", err
		}
	}

	// /etc/passwd and /etc/group
	passwdContent := GeneratePasswd(cfg.Accounts.Users)
	if err := tw.WriteHeader(&tar.Header{
		Name:     "etc/passwd",
		Typeflag: tar.TypeReg,
		Mode:     0644,
		Size:     int64(len(passwdContent)),
		ModTime:  zeroTime,
	}); err != nil {
		return nil, "", err
	}
	if _, err := tw.Write(passwdContent); err != nil {
		return nil, "", err
	}

	groupContent := GenerateGroup(cfg.Accounts.Groups)
	if err := tw.WriteHeader(&tar.Header{
		Name:     "etc/group",
		Typeflag: tar.TypeReg,
		Mode:     0644,
		Size:     int64(len(groupContent)),
		ModTime:  zeroTime,
	}); err != nil {
		return nil, "", err
	}
	if _, err := tw.Write(groupContent); err != nil {
		return nil, "", err
	}

	// Extra files if any
	for p, content := range extraFiles {
		rel := strings.TrimPrefix(p, "/")
		if err := tw.WriteHeader(&tar.Header{
			Name:     rel,
			Typeflag: tar.TypeReg,
			Mode:     0644,
			Size:     int64(len(content)),
			ModTime:  zeroTime,
		}); err != nil {
			return nil, "", err
		}
		if _, err := tw.Write(content); err != nil {
			return nil, "", err
		}
	}

	if err := tw.Close(); err != nil {
		return nil, "", err
	}

	rawTar := buf.Bytes()
	h := sha256.Sum256(rawTar)
	diffID := "sha256:" + hex.EncodeToString(h[:])

	return rawTar, diffID, nil
}

// WriteOCIImage writes an OCI image directory layout given configuration, diff IDs, and layer bytes.
func WriteOCIImage(outDir string, cfg *ImageConfig, arch string, rawLayer []byte, diffID string) error {
	if err := os.MkdirAll(filepath.Join(outDir, "blobs", "sha256"), 0755); err != nil {
		return fmt.Errorf("failed to create blobs dir: %w", err)
	}

	// 1. Write oci-layout
	if err := os.WriteFile(filepath.Join(outDir, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`+"\n"), 0644); err != nil {
		return err
	}

	// 2. Compress layer to gzip
	var gzBuf bytes.Buffer
	gw := gzip.NewWriter(&gzBuf)
	gw.Header.ModTime = time.Unix(0, 0)
	if _, err := gw.Write(rawLayer); err != nil {
		return err
	}
	if err := gw.Close(); err != nil {
		return err
	}
	gzLayer := gzBuf.Bytes()
	layerSum := sha256.Sum256(gzLayer)
	layerDigest := "sha256:" + hex.EncodeToString(layerSum[:])
	layerPath := filepath.Join(outDir, "blobs", "sha256", hex.EncodeToString(layerSum[:]))
	if err := os.WriteFile(layerPath, gzLayer, 0644); err != nil {
		return err
	}

	// 3. Construct Config JSON
	envList := make([]string, 0, len(cfg.Environment))
	for k, v := range cfg.Environment {
		envList = append(envList, fmt.Sprintf("%s=%s", k, v))
	}
	var entrypoint []string
	if cfg.Entrypoint.Command != "" {
		entrypoint = []string{cfg.Entrypoint.Command}
		entrypoint = append(entrypoint, cfg.Entrypoint.Args...)
	}
	var cmd []string
	if cfg.Cmd != "" {
		cmd = strings.Fields(cfg.Cmd)
	}

	targetArch := arch
	if targetArch == "" && len(cfg.Archs) > 0 {
		targetArch = cfg.Archs[0]
	}
	if targetArch == "" {
		targetArch = "amd64"
	}
	// Normalize arch
	if targetArch == "x86_64" {
		targetArch = "amd64"
	} else if targetArch == "aarch64" {
		targetArch = "arm64"
	}

	user := ""
	if len(cfg.Accounts.Users) > 0 {
		user = cfg.Accounts.Users[0].UserName
	}

	imgConfig := OCIImageConfig{
		Architecture: targetArch,
		OS:           "linux",
		Config: OCIContainerConfig{
			User:       user,
			Env:        envList,
			Entrypoint: entrypoint,
			Cmd:        cmd,
			WorkingDir: cfg.WorkDir,
			Labels:     cfg.Annotations,
		},
		RootFS: OCIRootFS{
			Type:    "layers",
			DiffIDs: []string{diffID},
		},
	}
	configBytes, err := json.MarshalIndent(imgConfig, "", "  ")
	if err != nil {
		return err
	}
	configSum := sha256.Sum256(configBytes)
	configDigest := "sha256:" + hex.EncodeToString(configSum[:])
	configPath := filepath.Join(outDir, "blobs", "sha256", hex.EncodeToString(configSum[:]))
	if err := os.WriteFile(configPath, configBytes, 0644); err != nil {
		return err
	}

	// 4. Construct Manifest JSON
	manifest := OCIManifest{
		SchemaVersion: 2,
		MediaType:     "application/vnd.oci.image.manifest.v1+json",
		Config: OCIDescriptor{
			MediaType: "application/vnd.oci.image.config.v1+json",
			Digest:    configDigest,
			Size:      int64(len(configBytes)),
		},
		Layers: []OCIDescriptor{
			{
				MediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
				Digest:    layerDigest,
				Size:      int64(len(gzLayer)),
			},
		},
		Annotations: cfg.Annotations,
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	manifestSum := sha256.Sum256(manifestBytes)
	manifestDigest := "sha256:" + hex.EncodeToString(manifestSum[:])
	manifestPath := filepath.Join(outDir, "blobs", "sha256", hex.EncodeToString(manifestSum[:]))
	if err := os.WriteFile(manifestPath, manifestBytes, 0644); err != nil {
		return err
	}

	// 5. Construct Index JSON
	index := OCIIndex{
		SchemaVersion: 2,
		Manifests: []OCIDescriptor{
			{
				MediaType: "application/vnd.oci.image.manifest.v1+json",
				Digest:    manifestDigest,
				Size:      int64(len(manifestBytes)),
			},
		},
	}
	indexBytes, err := json.MarshalIndent(index, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outDir, "index.json"), indexBytes, 0644); err != nil {
		return err
	}

	return nil
}

// CopyFile helper for copying file streams.
func CopyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}
