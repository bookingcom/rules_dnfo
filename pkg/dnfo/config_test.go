package dnfo

import (
	"strings"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	yamlInput := `
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/x86_64/
  packages:
    - bash
    - coreutils
entrypoint:
  command: /bin/bash
cmd: "-l"
work-dir: /home
environment:
  PATH: /bin:/usr/bin
accounts:
  users:
    - username: appuser
      uid: 1000
      gid: 1000
  groups:
    - groupname: appuser
      gid: 1000
archs:
  - x86_64
`
	cfg, err := LoadConfig(strings.NewReader(yamlInput))
	if err != nil {
		t.Fatalf("LoadConfig failed: %v", err)
	}
	if len(cfg.Contents.Packages) != 2 {
		t.Errorf("Expected 2 packages, got %d", len(cfg.Contents.Packages))
	}
	if cfg.Contents.Packages[0] != "bash" {
		t.Errorf("Expected first package to be 'bash', got %s", cfg.Contents.Packages[0])
	}
	if cfg.Entrypoint.Command != "/bin/bash" {
		t.Errorf("Expected entrypoint '/bin/bash', got %s", cfg.Entrypoint.Command)
	}
	if len(cfg.Accounts.Users) != 1 || cfg.Accounts.Users[0].UserName != "appuser" {
		t.Errorf("Unexpected user accounts: %+v", cfg.Accounts.Users)
	}
}
