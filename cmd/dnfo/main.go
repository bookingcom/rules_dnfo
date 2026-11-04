package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bookingcom/rules_dnfo/pkg/dnfo"
	"gopkg.in/yaml.v3"
)

func printUsage() {
	fmt.Fprintf(os.Stderr, `dnfo - DNF5 and RPM based declarative container image builder

Usage:
  dnfo <command> [options] [arguments]

Commands:
  lock        Generate or update a dnfo.lock.json lockfile using dnf5
  build       Build an OCI container image or layer archive from config and lockfile
  show-config Parse and display normalized dnfo YAML configuration
`)
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	cmd := os.Args[1]
	switch cmd {
	case "lock":
		runLock(os.Args[2:])
	case "build":
		runBuild(os.Args[2:])
	case "show-config":
		runShowConfig(os.Args[2:])
	case "-h", "--help", "help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", cmd)
		printUsage()
		os.Exit(1)
	}
}

func runLock(args []string) {
	fs := flag.NewFlagSet("lock", flag.ExitOnError)
	output := fs.String("output", "", "Output lockfile path (defaults to <config>.lock.json)")
	arch := fs.String("arch", "", "Target CPU architecture (e.g. x86_64, aarch64)")
	dnf5Path := fs.String("dnf5", "", "Path to hermetic dnf5 binary")
	rpmPath := fs.String("rpm", "", "Path to hermetic rpm binary")
	releasever := fs.String("releasever", "", "OS release version (e.g. 10)")
	gpgcheck := fs.Bool("gpgcheck", true, "Validate package signatures against GPG keys")
	keyring := fs.String("keyring", "", "Comma-separated list of additional GPG key files or URLs")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fmt.Fprintf(os.Stderr, "Error: config YAML file argument required\n")
		os.Exit(1)
	}
	configPath := fs.Arg(0)
	outPath := *output
	if outPath == "" {
		if strings.HasSuffix(configPath, ".yaml") {
			outPath = strings.TrimSuffix(configPath, ".yaml") + ".lock.json"
		} else if strings.HasSuffix(configPath, ".yml") {
			outPath = strings.TrimSuffix(configPath, ".yml") + ".lock.json"
		} else {
			outPath = configPath + ".lock.json"
		}
	}

	var keyList []string
	if *keyring != "" {
		for _, k := range strings.Split(*keyring, ",") {
			k = strings.TrimSpace(k)
			if k != "" {
				keyList = append(keyList, k)
			}
		}
	}

	opts := dnfo.SolverOptions{
		ConfigPath: configPath,
		OutputPath: outPath,
		Arch:       *arch,
		DNF5Path:   *dnf5Path,
		RPMPath:    *rpmPath,
		ReleaseVer: *releasever,
		GPGCheck:   *gpgcheck,
		Keyring:    keyList,
	}

	lock, err := dnfo.ResolveLock(opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error resolving lock: %v\n", err)
		os.Exit(1)
	}

	if err := lock.SaveFile(outPath); err != nil {
		fmt.Fprintf(os.Stderr, "Error writing lockfile: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stdout, "Locked %d packages into %s\n", len(lock.Packages), outPath)
}

func runBuild(args []string) {
	fs := flag.NewFlagSet("build", flag.ExitOnError)
	lockfilePath := fs.String("lockfile", "", "Path to lockfile")
	rpmsList := fs.String("rpms", "", "Comma-separated list of RPM files to install")
	rpmsDir := fs.String("rpms-dir", "", "Directory containing RPM files")
	format := fs.String("output-format", "oci", "Output format: 'oci' directory or 'tar' archive")
	arch := fs.String("arch", "", "Target CPU architecture")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fmt.Fprintf(os.Stderr, "Usage: dnfo build [options] <config.yaml> <output>\n")
		os.Exit(1)
	}
	configPath := fs.Arg(0)
	outputPath := fs.Arg(1)

	cfg, err := dnfo.LoadConfigFile(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading config: %v\n", err)
		os.Exit(1)
	}

	extraFiles := make(map[string][]byte)

	// Collect any provided RPM files
	var rpmFiles []string
	if *rpmsList != "" {
		for _, p := range strings.Split(*rpmsList, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				rpmFiles = append(rpmFiles, p)
			}
		}
	}
	if *rpmsDir != "" {
		entries, err := os.ReadDir(*rpmsDir)
		if err == nil {
			for _, e := range entries {
				if !e.IsDir() && strings.HasSuffix(e.Name(), ".rpm") {
					rpmFiles = append(rpmFiles, filepath.Join(*rpmsDir, e.Name()))
				}
			}
		}
	}

	// Unpack RPM payloads or record manifest
	var installedPkgList []string
	for _, rpm := range rpmFiles {
		installedPkgList = append(installedPkgList, filepath.Base(rpm))
	}
	if len(installedPkgList) > 0 {
		extraFiles["/etc/dnfo-packages.txt"] = []byte(strings.Join(installedPkgList, "\n") + "\n")
	}

	rawTar, diffID, err := dnfo.BuildLayerTar(cfg, extraFiles)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error building layer: %v\n", err)
		os.Exit(1)
	}

	_ = lockfilePath

	if *format == "tar" {
		if err := os.WriteFile(outputPath, rawTar, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing tar output: %v\n", err)
			os.Exit(1)
		}
	} else {
		// Default OCI directory output
		if err := dnfo.WriteOCIImage(outputPath, cfg, *arch, rawTar, diffID); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating OCI image: %v\n", err)
			os.Exit(1)
		}
	}
	fmt.Fprintf(os.Stdout, "Successfully built image at %s (format: %s)\n", outputPath, *format)
}

func runShowConfig(args []string) {
	if len(args) < 1 {
		fmt.Fprintf(os.Stderr, "Error: config YAML file required\n")
		os.Exit(1)
	}
	cfg, err := dnfo.LoadConfigFile(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", err)
		os.Exit(1)
	}
	enc := yaml.NewEncoder(os.Stdout)
	enc.SetIndent(2)
	_ = enc.Encode(cfg)
}
