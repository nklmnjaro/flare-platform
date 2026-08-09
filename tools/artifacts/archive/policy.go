package main

import (
	"errors"
	"io/fs"
	"regexp"
)

const manifestName = "MANIFEST.sha256"

const (
	defaultMaxEntries       = 4096
	defaultMaxPathBytes     = 1024
	defaultMaxEntryBytes    = 64 << 20
	defaultMaxPayloadBytes  = 128 << 20
	defaultMaxManifestBytes = 8 << 20
	defaultMaxArchiveBytes  = 152 << 20
)

type archiveLimits struct {
	maxEntries       int
	maxPathBytes     int
	maxEntryBytes    int64
	maxPayloadBytes  int64
	maxManifestBytes int64
	maxArchiveBytes  int64
}

var defaultLimits = archiveLimits{
	maxEntries:       defaultMaxEntries,
	maxPathBytes:     defaultMaxPathBytes,
	maxEntryBytes:    defaultMaxEntryBytes,
	maxPayloadBytes:  defaultMaxPayloadBytes,
	maxManifestBytes: defaultMaxManifestBytes,
	maxArchiveBytes:  defaultMaxArchiveBytes,
}

var homePath = regexp.MustCompile(
	`(?i)(^|[^[:alnum:]_])(/(home|users)/[^/\x00[:space:]]+|/` +
		`root([^[:alnum:]_.-]|$)|[a-z]:[\\/]+users[\\/]+[^\\/\x00[:space:]]+)`,
)

func (limits archiveLimits) validate() error {
	if limits.maxEntries < 1 || limits.maxPathBytes < 1 || limits.maxEntryBytes < 1 ||
		limits.maxPayloadBytes < 1 || limits.maxManifestBytes < 1 || limits.maxArchiveBytes < 1 {
		return errors.New("archive limits must be positive")
	}
	return nil
}

func containsHomePath(data []byte) bool {
	return homePath.Find(data) != nil
}

func normalizedMode(mode fs.FileMode) fs.FileMode {
	if mode&0o111 != 0 {
		return 0o755
	}
	return 0o644
}
