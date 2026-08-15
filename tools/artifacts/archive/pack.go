package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sort"
	"strings"
	"syscall"
)

type archiveEntry struct {
	name string
	data []byte
	mode fs.FileMode
}

func packDirectory(source, output string) error {
	return packDirectoryWithLimits(source, output, defaultLimits)
}

func packDirectoryWithLimits(source, output string, limits archiveLimits) (resultErr error) {
	if err := limits.validate(); err != nil {
		return err
	}
	rootPath, root, err := openPinnedArchiveSource(source)
	if err != nil {
		return fmt.Errorf("pin source directory: %w", err)
	}
	defer func() { resultErr = errors.Join(resultErr, root.Close()) }()

	target, err := canonicalOutputPath(rootPath, output)
	if err != nil {
		return err
	}
	destination, err := prepareArchiveDestination(target)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, destination.parent.Close()) }()
	if err := ensurePinnedArchiveOutputOutsideSource(root, destination.parent); err != nil {
		return err
	}

	entries, err := collectEntries(root, limits)
	if err != nil {
		return err
	}
	archiveStage, digest, err := buildArchiveStage(destination, entries, limits)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, archiveStage.closeAndDiscard()) }()
	checksumStage, err := buildChecksumStage(destination, digest)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, checksumStage.closeAndDiscard()) }()

	if err := archiveStage.publish(destination.archiveName, archiveBarrierBeforeArchivePublish); err != nil {
		return err
	}
	if err := checksumStage.publish(destination.checksumName, archiveBarrierBeforeChecksumPublish); err != nil {
		return err
	}
	return verifyPublishedArchivePair(destination, archiveStage, checksumStage, digest, limits)
}

func verifyPublishedArchivePair(
	destination *archiveDestination,
	archiveStage *stagedArchiveFile,
	checksumStage *stagedArchiveFile,
	expectedDigest string,
	limits archiveLimits,
) error {
	archiveFilesystemBarrier(archiveBarrierBeforePairVerification)
	if err := destination.verifyNamedParent(); err != nil {
		return err
	}
	if err := archiveStage.ensureNamed(); err != nil {
		return fmt.Errorf("published archive: %w", err)
	}
	if err := checksumStage.ensureNamed(); err != nil {
		return fmt.Errorf("published checksum: %w", err)
	}
	if err := verifyArchiveOpenFileWithLimits(archiveStage.file, limits); err != nil {
		return fmt.Errorf("published archive self-verification failed: %w", err)
	}
	if err := verifyDetachedChecksumOpenFiles(
		archiveStage.file,
		checksumStage.file,
		destination.archiveName,
	); err != nil {
		return fmt.Errorf("detached checksum self-verification failed: %w", err)
	}
	actualDigest, err := hashOpenFile(archiveStage.file)
	if err != nil {
		return err
	}
	if actualDigest != expectedDigest {
		return errors.New("published archive differs from the collected source")
	}
	actualChecksum, err := readSmallOpenFile(checksumStage.file, maxDetachedChecksumBytes)
	if err != nil {
		return err
	}
	expectedChecksum := detachedChecksumData(expectedDigest, destination.archiveName)
	if !bytes.Equal(actualChecksum, expectedChecksum) {
		return errors.New("published checksum differs from the sealed checksum")
	}
	if err := archiveStage.ensureNamed(); err != nil {
		return fmt.Errorf("published archive: %w", err)
	}
	if err := checksumStage.ensureNamed(); err != nil {
		return fmt.Errorf("published checksum: %w", err)
	}
	return destination.verifyNamedParent()
}

func buildArchiveStage(
	destination *archiveDestination,
	entries []archiveEntry,
	limits archiveLimits,
) (_ *stagedArchiveFile, _ string, resultErr error) {
	manifest := manifestEntry(entries)
	if int64(len(manifest.data)) > limits.maxManifestBytes {
		return nil, "", fmt.Errorf("archive manifest exceeds %d bytes", limits.maxManifestBytes)
	}
	stage, err := destination.createStagedFile("zip")
	if err != nil {
		return nil, "", err
	}
	defer func() {
		if resultErr != nil {
			resultErr = errors.Join(resultErr, stage.closeAndDiscard())
		}
	}()
	if err := writeZip(stage.file, append(entries, manifest)); err != nil {
		return nil, "", err
	}
	if err := stage.seal(0o644); err != nil {
		return nil, "", err
	}
	if err := verifyArchiveOpenFileWithLimits(stage.file, limits); err != nil {
		return nil, "", fmt.Errorf("archive self-verification failed: %w", err)
	}
	digest, err := hashOpenFile(stage.file)
	if err != nil {
		return nil, "", err
	}
	return stage, digest, nil
}

func buildChecksumStage(
	destination *archiveDestination,
	digest string,
) (_ *stagedArchiveFile, resultErr error) {
	stage, err := destination.createStagedFile("sha256")
	if err != nil {
		return nil, err
	}
	defer func() {
		if resultErr != nil {
			resultErr = errors.Join(resultErr, stage.closeAndDiscard())
		}
	}()
	checksum := detachedChecksumData(digest, destination.archiveName)
	if _, err := stage.file.Write(checksum); err != nil {
		return nil, err
	}
	if err := stage.seal(0o644); err != nil {
		return nil, err
	}
	return stage, nil
}

func collectEntries(root *os.File, limits archiveLimits) ([]archiveEntry, error) {
	var entries []archiveEntry
	var payloadBytes int64
	if err := collectDirectory(root, "", limits, &payloadBytes, &entries); err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("source directory contains no regular files")
	}
	sort.Slice(entries, func(left, right int) bool { return entries[left].name < entries[right].name })
	return entries, nil
}

func collectDirectory(
	directory *os.File,
	prefix string,
	limits archiveLimits,
	payloadBytes *int64,
	entries *[]archiveEntry,
) error {
	before, err := archiveState(directory)
	if err != nil {
		return err
	}
	names, err := directory.Readdirnames(-1)
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		relative := name
		if prefix != "" {
			relative = prefix + "/" + name
		}
		if err := collectSourceEntry(
			directory, name, relative, limits, payloadBytes, entries,
		); err != nil {
			return err
		}
	}
	after, err := archiveState(directory)
	if err != nil {
		return err
	}
	if !sameStableArchiveFile(before, after) {
		return fmt.Errorf("source directory %s changed while being collected", sourceDisplayName(prefix))
	}
	return nil
}

func collectSourceEntry(
	directory *os.File,
	name string,
	relative string,
	limits archiveLimits,
	payloadBytes *int64,
	entries *[]archiveEntry,
) (resultErr error) {
	if err := validateArchivePath(relative, limits.maxPathBytes); err != nil {
		return err
	}
	reference, referenceState, err := inspectSourceEntry(directory, name, relative)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, reference.Close()) }()
	archiveFilesystemBarrier(archiveBarrierSourceEntryPinned)
	switch archiveFileType(referenceState) {
	case syscall.S_IFDIR:
		return collectSourceSubdirectory(
			directory, name, relative, referenceState, limits, payloadBytes, entries,
		)
	case syscall.S_IFREG:
		return collectSourceRegularFile(
			directory, name, relative, referenceState, limits, payloadBytes, entries,
		)
	default:
		return fmt.Errorf("special files are not allowed in durable artifacts: %s", relative)
	}
}

func inspectSourceEntry(
	directory *os.File,
	name string,
	relative string,
) (*os.File, archiveFileState, error) {
	reference, err := openArchivePathReference(directory, name)
	if err != nil {
		return nil, archiveFileState{}, fmt.Errorf("inspect source entry %s: %w", relative, err)
	}
	state, err := archiveState(reference)
	if err != nil {
		_ = reference.Close()
		return nil, archiveFileState{}, err
	}
	if archiveFileType(state) == syscall.S_IFLNK {
		_ = reference.Close()
		return nil, archiveFileState{}, fmt.Errorf(
			"symlinks are not allowed in durable artifacts: %s", relative,
		)
	}
	return reference, state, nil
}

func collectSourceSubdirectory(
	directory *os.File,
	name string,
	relative string,
	referenceState archiveFileState,
	limits archiveLimits,
	payloadBytes *int64,
	entries *[]archiveEntry,
) error {
	child, err := openArchiveDirectoryAt(directory, name)
	if err != nil {
		return fmt.Errorf("source directory %s changed while being opened: %w", relative, err)
	}
	openedState, stateErr := archiveState(child)
	if stateErr != nil || !sameStableArchiveFile(referenceState, openedState) {
		_ = child.Close()
		if stateErr != nil {
			return stateErr
		}
		return fmt.Errorf("source directory %s changed while being opened", relative)
	}
	collectErr := collectDirectory(child, relative, limits, payloadBytes, entries)
	return errors.Join(collectErr, child.Close())
}

func collectSourceRegularFile(
	directory *os.File,
	name string,
	relative string,
	referenceState archiveFileState,
	limits archiveLimits,
	payloadBytes *int64,
	entries *[]archiveEntry,
) error {
	if len(*entries) >= limits.maxEntries {
		return fmt.Errorf("archive entry count exceeds %d", limits.maxEntries)
	}
	file, err := openArchiveRegularAt(directory, name)
	if err != nil {
		return fmt.Errorf("source file %s changed while being opened: %w", relative, err)
	}
	openedState, stateErr := archiveState(file)
	if stateErr != nil || !sameStableArchiveFile(referenceState, openedState) {
		_ = file.Close()
		if stateErr != nil {
			return stateErr
		}
		return fmt.Errorf("source file %s changed while being opened", relative)
	}
	data, readErr := readPinnedSourceFile(file, openedState, limits.maxEntryBytes)
	closeErr := file.Close()
	if readErr != nil || closeErr != nil {
		return fmt.Errorf("read %s: %w", relative, errors.Join(readErr, closeErr))
	}
	if int64(len(data)) > limits.maxPayloadBytes-*payloadBytes {
		return fmt.Errorf("archive payload exceeds %d bytes", limits.maxPayloadBytes)
	}
	if containsHomePath(data) {
		return fmt.Errorf("absolute workstation home path detected in %s", relative)
	}
	if relative == manifestName {
		return fmt.Errorf("source must not contain reserved file %s", manifestName)
	}
	*payloadBytes += int64(len(data))
	*entries = append(*entries, archiveEntry{
		name: relative,
		data: data,
		mode: normalizedMode(archiveFileMode(openedState)),
	})
	return nil
}

func readPinnedSourceFile(file *os.File, before archiveFileState, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	archiveFilesystemBarrier(archiveBarrierSourceFileRead)
	after, err := archiveState(file)
	if err != nil {
		return nil, err
	}
	if !sameStableArchiveFile(before, after) {
		return nil, errors.New("source file changed while being read")
	}
	return data, nil
}

func sourceDisplayName(prefix string) string {
	if prefix == "" {
		return "."
	}
	return prefix
}

func manifestEntry(entries []archiveEntry) archiveEntry {
	var manifest strings.Builder
	for _, entry := range entries {
		digest := sha256.Sum256(entry.data)
		fmt.Fprintf(&manifest, "%s  %s\n", hex.EncodeToString(digest[:]), entry.name)
	}
	return archiveEntry{name: manifestName, data: []byte(manifest.String()), mode: 0o644}
}

func writeZip(target io.Writer, entries []archiveEntry) error {
	writer := zip.NewWriter(target)
	sort.Slice(entries, func(left, right int) bool { return entries[left].name < entries[right].name })
	for _, entry := range entries {
		if err := writeZipEntry(writer, entry); err != nil {
			_ = writer.Close()
			return err
		}
	}
	return writer.Close()
}

func writeZipEntry(writer *zip.Writer, entry archiveEntry) error {
	header := &zip.FileHeader{Name: entry.name, Method: zip.Store, ModifiedDate: 33, ModifiedTime: 0}
	header.SetMode(entry.mode)
	header.Extra = nil
	file, err := writer.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = file.Write(entry.data)
	return err
}
