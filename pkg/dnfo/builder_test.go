package dnfo

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGeneratePasswdAndGroup(t *testing.T) {
	users := []UserConfig{
		{UserName: "nonroot", UID: 65532, GID: 65532, HomeDir: "/home/nonroot", Shell: "/sbin/nologin"},
	}
	groups := []GroupConfig{
		{GroupName: "nonroot", GID: 65532, Members: []string{"nonroot"}},
	}

	passwd := string(GeneratePasswd(users))
	if !strings.Contains(passwd, "nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin") {
		t.Errorf("Passwd missing nonroot entry:\n%s", passwd)
	}
	if !strings.Contains(passwd, "root:x:0:0:root:/root:/bin/sh") {
		t.Errorf("Passwd missing default root entry:\n%s", passwd)
	}

	group := string(GenerateGroup(groups))
	if !strings.Contains(group, "nonroot:x:65532:nonroot") {
		t.Errorf("Group missing nonroot entry:\n%s", group)
	}
	if !strings.Contains(group, "root:x:0:") {
		t.Errorf("Group missing default root entry:\n%s", group)
	}
}

func TestBuildLayerTarAndOCI(t *testing.T) {
	cfg := &ImageConfig{
		Cmd:     "/bin/bash -l",
		WorkDir: "/app",
		Environment: map[string]string{
			"PATH": "/usr/local/bin:/usr/bin:/bin",
		},
		Accounts: AccountsConfig{
			Users: []UserConfig{
				{UserName: "nonroot", UID: 65532, GID: 65532},
			},
			Groups: []GroupConfig{
				{GroupName: "nonroot", GID: 65532},
			},
		},
		Archs: []string{"x86_64"},
	}

	rawTar, diffID, err := BuildLayerTar(cfg, map[string][]byte{
		"/app/hello.txt": []byte("Hello DNFO\n"),
	})
	if err != nil {
		t.Fatalf("BuildLayerTar failed: %v", err)
	}
	if len(rawTar) == 0 || !strings.HasPrefix(diffID, "sha256:") {
		t.Fatalf("Invalid layer tar or diffID: %s", diffID)
	}

	outDir, err := os.MkdirTemp("", "dnfo-oci-*")
	if err != nil {
		t.Fatalf("MkdirTemp failed: %v", err)
	}
	defer os.RemoveAll(outDir)

	if err := WriteOCIImage(outDir, cfg, "x86_64", rawTar, diffID); err != nil {
		t.Fatalf("WriteOCIImage failed: %v", err)
	}

	if _, err := os.Stat(filepath.Join(outDir, "oci-layout")); err != nil {
		t.Errorf("Missing oci-layout: %v", err)
	}
	if _, err := os.Stat(filepath.Join(outDir, "index.json")); err != nil {
		t.Errorf("Missing index.json: %v", err)
	}
}
