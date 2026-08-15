package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const maxDetachedChecksumBytes = 512

func verifyDetachedChecksum(path string) (resultErr error) {
	pair, err := openArchiveVerificationPair(path)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, pair.close()) }()
	if err := verifyDetachedChecksumOpenFiles(
		pair.archive,
		pair.checksum,
		pair.archiveName,
	); err != nil {
		return err
	}
	return pair.verifyNames()
}

func verifyDetachedChecksumOpenFiles(archive, checksum *os.File, archiveName string) error {
	data, err := readSmallOpenFile(checksum, maxDetachedChecksumBytes)
	if err != nil {
		return fmt.Errorf("detached checksum: %w", err)
	}
	parts, err := parseDetachedChecksum(data)
	if err != nil {
		return err
	}
	if parts[1] != archiveName {
		return errors.New("detached checksum filename does not match archive")
	}
	actual, err := hashOpenFile(archive)
	if err != nil {
		return err
	}
	if parts[0] != actual {
		return errors.New("detached archive checksum mismatch")
	}
	return nil
}

func detachedChecksumData(digest, archiveName string) []byte {
	return []byte(fmt.Sprintf("%s  %s\n", digest, archiveName))
}

func parseDetachedChecksum(data []byte) ([2]string, error) {
	var result [2]string
	if !bytes.HasSuffix(data, []byte("\n")) || bytes.Count(data, []byte("\n")) != 1 {
		return result, errors.New("detached checksum must contain exactly one newline-terminated record")
	}
	line := strings.TrimSuffix(string(data), "\n")
	parts := strings.SplitN(line, "  ", 2)
	if len(parts) != 2 || !validDigest(parts[0]) || parts[1] == "" || strings.ContainsAny(parts[1], "/\\\r\n") {
		return result, errors.New("detached checksum has invalid format")
	}
	result[0], result[1] = parts[0], parts[1]
	return result, nil
}

func hashOpenFile(file *os.File) (string, error) {
	before, err := archiveState(file)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	reader := io.NewSectionReader(file, 0, before.size)
	if _, err := io.Copy(hash, reader); err != nil {
		return "", err
	}
	after, err := archiveState(file)
	if err != nil {
		return "", err
	}
	if !sameStableArchiveFile(before, after) {
		return "", errors.New("archive changed while it was hashed")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readSmallOpenFile(file *os.File, limit int64) ([]byte, error) {
	before, err := archiveState(file)
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(io.NewSectionReader(file, 0, before.size), limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	after, err := archiveState(file)
	if err != nil {
		return nil, err
	}
	if !sameStableArchiveFile(before, after) {
		return nil, errors.New("checksum changed while it was read")
	}
	return data, nil
}
