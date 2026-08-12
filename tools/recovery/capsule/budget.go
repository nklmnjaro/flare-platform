package main

import (
	"bytes"
	"errors"
	"fmt"
	"strconv"
)

const (
	maxRecoveredFiles     = 100_000
	maxRecoveredFileBytes = 16 << 20
	maxRecoveredTreeBytes = 128 << 20
	maxRecoveredPathBytes = 4 << 10
)

func verifyRecoveredTreeBudget(repository string, runner *gitRunner) error {
	output, err := runner.runLarge(repository, nil, "ls-tree", "-r", "-l", "-z", "HEAD")
	if err != nil {
		return fmt.Errorf("recovered tree inspection failed: %w", err)
	}
	entries := bytes.Split(output, []byte{0})
	fileCount := 0
	totalBytes := int64(0)
	for _, entry := range entries {
		if len(entry) == 0 {
			continue
		}
		size, path, err := parseTreeEntry(entry)
		if err != nil {
			return err
		}
		fileCount++
		if fileCount > maxRecoveredFiles {
			return errors.New("recovered tree exceeds file-count budget")
		}
		if len(path) > maxRecoveredPathBytes {
			return errors.New("recovered tree path exceeds length budget")
		}
		if size > maxRecoveredFileBytes {
			return fmt.Errorf("recovered file %q exceeds size budget", path)
		}
		totalBytes += size
		if totalBytes > maxRecoveredTreeBytes {
			return errors.New("recovered tree exceeds total-size budget")
		}
	}
	return nil
}

func parseTreeEntry(entry []byte) (int64, string, error) {
	header, pathBytes, found := bytes.Cut(entry, []byte{'\t'})
	if !found || len(pathBytes) == 0 {
		return 0, "", errors.New("recovered tree entry is malformed")
	}
	fields := bytes.Fields(header)
	if len(fields) != 4 || string(fields[1]) != "blob" {
		return 0, "", errors.New("recovered tree contains an unsupported entry")
	}
	size, err := strconv.ParseInt(string(fields[3]), 10, 64)
	if err != nil || size < 0 {
		return 0, "", errors.New("recovered tree entry size is invalid")
	}
	return size, string(pathBytes), nil
}
