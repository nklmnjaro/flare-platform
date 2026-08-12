package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const (
	maxReachableObjects         = 250_000
	maxReachableTrees           = 100_000
	maxHistoricalAttributeBlobs = 100_000
)

type batchObject struct {
	ID      string
	Content []byte
}

type reachableObjectInventory struct {
	Trees []string
	Blobs []string
}

func rejectReachableHistoryIndirection(
	identity repositoryIdentity,
	runner *gitRunner,
) error {
	objects, err := reachableObjectIDs(identity, runner)
	if err != nil {
		return err
	}
	attributes, err := inspectReachableTrees(identity, runner, objects.Trees)
	if err != nil {
		return err
	}
	return rejectHistoricalLFSContent(identity, runner, objects.Blobs, attributes)
}

func reachableObjectIDs(
	identity repositoryIdentity,
	runner *gitRunner,
) (reachableObjectInventory, error) {
	output, err := runner.runLarge(identity.Root, nil,
		"rev-list", "--objects", "--no-object-names", "HEAD")
	if err != nil {
		return reachableObjectInventory{}, fmt.Errorf("reachable object enumeration failed: %w", err)
	}
	objectIDs, err := parseObjectIDLines(output, identity.ObjectFormat, maxReachableObjects)
	if err != nil {
		return reachableObjectInventory{}, err
	}
	input := []byte(strings.Join(objectIDs, "\n") + "\n")
	types, err := runner.runLarge(identity.Root, input,
		"cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)")
	if err != nil {
		return reachableObjectInventory{}, fmt.Errorf("reachable object type inspection failed: %w", err)
	}
	inventory, err := parseObjectTypes(types, objectIDs)
	if err != nil {
		return reachableObjectInventory{}, err
	}
	if len(inventory.Trees) > maxReachableTrees {
		return reachableObjectInventory{}, errors.New("reachable history exceeds tree-count budget")
	}
	return inventory, nil
}

func parseObjectIDLines(payload []byte, format string, limit int) ([]string, error) {
	trimmed := bytes.TrimSpace(payload)
	if len(trimmed) == 0 {
		return nil, errors.New("reachable history contains no objects")
	}
	lines := bytes.Split(trimmed, []byte{'\n'})
	if len(lines) > limit {
		return nil, errors.New("reachable history exceeds object-count budget")
	}
	objectIDs := make([]string, 0, len(lines))
	seen := make(map[string]struct{}, len(lines))
	for _, line := range lines {
		objectID := string(line)
		if !validObjectIDForFormat(objectID, format) {
			return nil, errors.New("reachable history object ID is malformed")
		}
		if _, found := seen[objectID]; found {
			return nil, errors.New("reachable history object list contains a duplicate")
		}
		seen[objectID] = struct{}{}
		objectIDs = append(objectIDs, objectID)
	}
	return objectIDs, nil
}

func validObjectIDForFormat(objectID, format string) bool {
	if !objectIDPattern.MatchString(objectID) {
		return false
	}
	return format == "sha1" && len(objectID) == 40 ||
		format == "sha256" && len(objectID) == 64
}

func parseObjectTypes(payload []byte, expected []string) (reachableObjectInventory, error) {
	lines := bytes.Split(bytes.TrimSpace(payload), []byte{'\n'})
	if len(lines) != len(expected) {
		return reachableObjectInventory{}, errors.New("reachable object type response count is not exact")
	}
	result := reachableObjectInventory{}
	for index, line := range lines {
		fields := bytes.Fields(line)
		if len(fields) != 3 || string(fields[0]) != expected[index] {
			return reachableObjectInventory{}, errors.New("reachable object type response is malformed")
		}
		size, err := strconv.ParseInt(string(fields[2]), 10, 64)
		if err != nil || size < 0 {
			return reachableObjectInventory{}, errors.New("reachable object size is malformed")
		}
		switch string(fields[1]) {
		case "tree":
			result.Trees = append(result.Trees, expected[index])
		case "blob":
			result.Blobs = append(result.Blobs, expected[index])
		case "commit", "tag":
		default:
			return reachableObjectInventory{}, errors.New(
				"reachable history contains an unsupported object type")
		}
	}
	return result, nil
}

func inspectReachableTrees(
	identity repositoryIdentity,
	runner *gitRunner,
	trees []string,
) ([]string, error) {
	input := []byte(strings.Join(trees, "\n") + "\n")
	payload, err := runner.runLarge(identity.Root, input, "cat-file", "--batch")
	if err != nil {
		return nil, fmt.Errorf("reachable tree inspection failed: %w", err)
	}
	objects, err := parseBatchObjects(payload, trees, "tree")
	if err != nil {
		return nil, err
	}
	attributes := make(map[string]struct{})
	for _, object := range objects {
		if err := inspectRawTree(object.Content, identity.ObjectFormat, attributes); err != nil {
			return nil, err
		}
	}
	if len(attributes) > maxHistoricalAttributeBlobs {
		return nil, errors.New("reachable history exceeds attribute-count budget")
	}
	result := make([]string, 0, len(attributes))
	for objectID := range attributes {
		result = append(result, objectID)
	}
	sort.Strings(result)
	return result, nil
}

func parseBatchObjects(
	payload []byte,
	expected []string,
	expectedType string,
) ([]batchObject, error) {
	objects := make([]batchObject, 0, len(expected))
	offset := 0
	for index, expectedID := range expected {
		lineEnd := bytes.IndexByte(payload[offset:], '\n')
		if lineEnd < 0 {
			return nil, errors.New("Git batch response header is incomplete")
		}
		lineEnd += offset
		fields := bytes.Fields(payload[offset:lineEnd])
		if len(fields) != 3 || string(fields[0]) != expectedID ||
			string(fields[1]) != expectedType {
			return nil, errors.New("Git batch response header is malformed")
		}
		size, err := strconv.ParseInt(string(fields[2]), 10, 64)
		if err != nil || size < 0 || size > int64(len(payload)) {
			return nil, errors.New("Git batch response size is invalid")
		}
		contentStart := lineEnd + 1
		contentEnd := contentStart + int(size)
		if contentEnd >= len(payload) || payload[contentEnd] != '\n' {
			return nil, errors.New("Git batch response content is incomplete")
		}
		objects = append(objects, batchObject{ID: expected[index], Content: payload[contentStart:contentEnd]})
		offset = contentEnd + 1
	}
	if offset != len(payload) {
		return nil, errors.New("Git batch response contains trailing data")
	}
	return objects, nil
}

func inspectRawTree(
	content []byte,
	objectFormat string,
	attributes map[string]struct{},
) error {
	rawObjectBytes := 20
	if objectFormat == "sha256" {
		rawObjectBytes = 32
	}
	for offset := 0; offset < len(content); {
		space := bytes.IndexByte(content[offset:], ' ')
		if space < 1 {
			return errors.New("reachable tree entry mode is malformed")
		}
		space += offset
		nul := bytes.IndexByte(content[space+1:], 0)
		if nul < 1 {
			return errors.New("reachable tree entry name is malformed")
		}
		nul += space + 1
		objectEnd := nul + 1 + rawObjectBytes
		if objectEnd > len(content) {
			return errors.New("reachable tree entry object ID is incomplete")
		}
		mode := string(content[offset:space])
		name := content[space+1 : nul]
		if err := inspectTreeEntry(mode, name); err != nil {
			return err
		}
		if (mode == "100644" || mode == "100755") && bytes.Equal(name, []byte(".gitattributes")) {
			attributes[hex.EncodeToString(content[nul+1:objectEnd])] = struct{}{}
		}
		offset = objectEnd
	}
	return nil
}

func inspectTreeEntry(mode string, name []byte) error {
	if len(name) == 0 || bytes.IndexByte(name, '/') >= 0 {
		return errors.New("reachable tree entry name is unsafe")
	}
	switch mode {
	case "160000":
		return errors.New("submodule gitlinks are unsupported in reachable recovery history")
	case "40000", "040000", "100644", "100755", "120000":
		return nil
	default:
		return errors.New("reachable tree entry mode is unsupported")
	}
}

func rejectHistoricalLFSContent(
	identity repositoryIdentity,
	runner *gitRunner,
	blobObjectIDs []string,
	attributeObjectIDs []string,
) error {
	if len(blobObjectIDs) == 0 {
		return nil
	}
	input := []byte(strings.Join(blobObjectIDs, "\n") + "\n")
	payload, err := runner.runLarge(identity.Root, input, "cat-file", "--batch")
	if err != nil {
		return fmt.Errorf("historical blob inspection failed: %w", err)
	}
	objects, err := parseBatchObjects(payload, blobObjectIDs, "blob")
	if err != nil {
		return err
	}
	attributes := make(map[string]struct{}, len(attributeObjectIDs))
	for _, objectID := range attributeObjectIDs {
		attributes[objectID] = struct{}{}
	}
	for _, object := range objects {
		_, isAttributes := attributes[object.ID]
		if isAttributes && containsLFSFilterAttribute(object.Content) {
			return errors.New("Git LFS attributes are unsupported in reachable recovery history")
		}
		if looksLikeLFSPointer(object.Content) {
			return errors.New("Git LFS pointer is unsupported in reachable recovery history")
		}
	}
	return nil
}

func containsLFSFilterAttribute(content []byte) bool {
	for _, line := range bytes.Split(content, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		for _, field := range bytes.Fields(line) {
			if bytes.Equal(field, []byte("filter=lfs")) {
				return true
			}
		}
	}
	return false
}

func looksLikeLFSPointer(content []byte) bool {
	if len(content) == 0 || len(content) > 4096 {
		return false
	}
	lines := bytes.Split(content, []byte{'\n'})
	if !bytes.Equal(bytes.TrimSuffix(lines[0], []byte{'\r'}),
		[]byte("version https://git-lfs.github.com/spec/v1")) {
		return false
	}
	hasObjectID := false
	hasSize := false
	for _, line := range lines[1:] {
		line = bytes.TrimSpace(line)
		if bytes.HasPrefix(line, []byte("oid sha256:")) {
			hasObjectID = bundleSHA256Pattern.Match(line[len("oid sha256:"):])
		}
		if bytes.HasPrefix(line, []byte("size ")) {
			_, err := strconv.ParseUint(string(line[len("size "):]), 10, 64)
			hasSize = err == nil
		}
	}
	return hasObjectID && hasSize
}
