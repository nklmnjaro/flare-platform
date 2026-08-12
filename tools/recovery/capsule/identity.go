package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
)

const recoverySchema = "flare-platform-recovery-v1"

var bundleSHA256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type recoveryIdentity struct {
	Schema           string `json:"schema"`
	ObjectFormat     string `json:"object_format"`
	Branch           string `json:"branch"`
	Commit           string `json:"commit"`
	Tree             string `json:"tree"`
	BundleFile       string `json:"bundle_file"`
	BundleSHA256     string `json:"bundle_sha256"`
	History          string `json:"history"`
	Worktree         string `json:"worktree"`
	HiddenIndexFlags string `json:"hidden_index_flags"`
	ReplaceRefs      string `json:"replace_refs"`
	Submodules       string `json:"submodules"`
	GitLFS           string `json:"git_lfs"`
}

func newRecoveryIdentity(repository repositoryIdentity, bundleSHA256 string) recoveryIdentity {
	return recoveryIdentity{
		Schema:           recoverySchema,
		ObjectFormat:     repository.ObjectFormat,
		Branch:           repository.Branch,
		Commit:           repository.Commit,
		Tree:             repository.Tree,
		BundleFile:       "repository.bundle",
		BundleSHA256:     bundleSHA256,
		History:          "full",
		Worktree:         "clean",
		HiddenIndexFlags: "absent",
		ReplaceRefs:      "absent",
		Submodules:       "absent",
		GitLFS:           "absent",
	}
}

func writeRecoveryIdentity(path string, identity recoveryIdentity) error {
	if err := validateRecoveryIdentity(identity); err != nil {
		return err
	}
	payload, err := json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	written, err := file.Write(payload)
	if err != nil {
		_ = file.Close()
		return err
	}
	if written != len(payload) {
		_ = file.Close()
		return io.ErrShortWrite
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func readRecoveryIdentity(path string) (recoveryIdentity, error) {
	info, err := os.Stat(path)
	if err != nil {
		return recoveryIdentity{}, err
	}
	if info.Size() > 16<<10 {
		return recoveryIdentity{}, errors.New("RECOVERY.json exceeds 16 KiB")
	}
	file, err := os.Open(path)
	if err != nil {
		return recoveryIdentity{}, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 16<<10))
	decoder.DisallowUnknownFields()
	var identity recoveryIdentity
	if err := decoder.Decode(&identity); err != nil {
		return recoveryIdentity{}, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return recoveryIdentity{}, errors.New("RECOVERY.json contains trailing data")
	}
	if err := validateRecoveryIdentity(identity); err != nil {
		return recoveryIdentity{}, err
	}
	return identity, nil
}

func validateRecoveryIdentity(identity recoveryIdentity) error {
	if identity.Schema != recoverySchema {
		return fmt.Errorf("unsupported recovery schema %q", identity.Schema)
	}
	repository := repositoryIdentity{
		ObjectFormat: identity.ObjectFormat,
		Branch:       identity.Branch,
		Commit:       identity.Commit,
		Tree:         identity.Tree,
	}
	if repository.Branch == "" || bytes.ContainsAny([]byte(repository.Branch), "\r\n\x00") {
		return errors.New("recovery branch is unsafe")
	}
	if err := validateObjectIdentity(repository); err != nil {
		return err
	}
	if identity.BundleFile != "repository.bundle" {
		return errors.New("recovery bundle filename is not canonical")
	}
	if !bundleSHA256Pattern.MatchString(identity.BundleSHA256) {
		return errors.New("recovery bundle SHA-256 is invalid")
	}
	if identity.History != "full" || identity.Worktree != "clean" {
		return errors.New("recovery source state is not complete and clean")
	}
	for label, value := range map[string]string{
		"hidden index flags": identity.HiddenIndexFlags,
		"replace refs":       identity.ReplaceRefs,
		"submodules":         identity.Submodules,
		"Git LFS":            identity.GitLFS,
	} {
		if value != "absent" {
			return fmt.Errorf("recovery %s state is unsupported", label)
		}
	}
	return nil
}
