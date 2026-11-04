package dnfo

import (
	"fmt"
	"io"
	"os"

	"gopkg.in/yaml.v3"
)

// RepositoryConfig defines a DNF/YUM repository entry.
type RepositoryConfig struct {
	ID         string `yaml:"id,omitempty" json:"id,omitempty"`
	Name       string `yaml:"name,omitempty" json:"name,omitempty"`
	BaseURL    string `yaml:"baseurl,omitempty" json:"baseurl,omitempty"`
	Metalink   string `yaml:"metalink,omitempty" json:"metalink,omitempty"`
	Mirrorlist string `yaml:"mirrorlist,omitempty" json:"mirrorlist,omitempty"`
	GPGCheck   *int   `yaml:"gpgcheck,omitempty" json:"gpgcheck,omitempty"`
	GPGKey     string `yaml:"gpgkey,omitempty" json:"gpgkey,omitempty"`
	Enabled    *int   `yaml:"enabled,omitempty" json:"enabled,omitempty"`
}

// ContentsConfig specifies packages, repositories and keyrings for image construction.
type ContentsConfig struct {
	Repositories []RepositoryConfig `yaml:"repositories,omitempty" json:"repositories,omitempty"`
	Packages     []string           `yaml:"packages,omitempty" json:"packages,omitempty"`
	Keyring      []string           `yaml:"keyring,omitempty" json:"keyring,omitempty"`
}

// UserConfig specifies a local system user.
type UserConfig struct {
	UserName string `yaml:"username" json:"username"`
	UID      int    `yaml:"uid" json:"uid"`
	GID      int    `yaml:"gid" json:"gid"`
	HomeDir  string `yaml:"homedir,omitempty" json:"homedir,omitempty"`
	Shell    string `yaml:"shell,omitempty" json:"shell,omitempty"`
}

// GroupConfig specifies a local system group.
type GroupConfig struct {
	GroupName string   `yaml:"groupname" json:"groupname"`
	GID       int      `yaml:"gid" json:"gid"`
	Members   []string `yaml:"members,omitempty" json:"members,omitempty"`
}

// AccountsConfig specifies user and group accounts created in the container.
type AccountsConfig struct {
	Users  []UserConfig  `yaml:"users,omitempty" json:"users,omitempty"`
	Groups []GroupConfig `yaml:"groups,omitempty" json:"groups,omitempty"`
}

// EntrypointConfig specifies image entrypoint execution.
type EntrypointConfig struct {
	Command  string   `yaml:"command,omitempty" json:"command,omitempty"`
	Args     []string `yaml:"args,omitempty" json:"args,omitempty"`
	Services []string `yaml:"services,omitempty" json:"services,omitempty"`
}

// ImageConfig represents the root YAML schema of a dnfo image definition.
type ImageConfig struct {
	Contents    ContentsConfig    `yaml:"contents" json:"contents"`
	Entrypoint  EntrypointConfig  `yaml:"entrypoint,omitempty" json:"entrypoint,omitempty"`
	Cmd         string            `yaml:"cmd,omitempty" json:"cmd,omitempty"`
	WorkDir     string            `yaml:"work-dir,omitempty" json:"work-dir,omitempty"`
	Environment map[string]string `yaml:"environment,omitempty" json:"environment,omitempty"`
	Accounts    AccountsConfig    `yaml:"accounts,omitempty" json:"accounts,omitempty"`
	Archs       []string          `yaml:"archs,omitempty" json:"archs,omitempty"`
	Annotations map[string]string `yaml:"annotations,omitempty" json:"annotations,omitempty"`
}

// LoadConfig reads and parses an ImageConfig from a reader.
func LoadConfig(r io.Reader) (*ImageConfig, error) {
	var cfg ImageConfig
	dec := yaml.NewDecoder(r)
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("failed to decode dnfo config: %w", err)
	}
	return &cfg, nil
}

// LoadConfigFile reads and parses an ImageConfig from a file path.
func LoadConfigFile(path string) (*ImageConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open dnfo config file %s: %w", path, err)
	}
	defer f.Close()
	return LoadConfig(f)
}
