package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"os"
)

const compareBufferBytes = 64 << 10

var errNoncanonicalEncoding = errors.New("archive byte encoding is not canonical")

type canonicalComparingWriter struct {
	source io.Reader
	buffer []byte
}

func verifyCanonicalEncodingOpenFile(file *os.File, size int64, entries []archiveEntry) error {
	comparer := canonicalComparingWriter{
		source: bufio.NewReaderSize(io.NewSectionReader(file, 0, size), compareBufferBytes),
		buffer: make([]byte, compareBufferBytes),
	}
	if err := writeZip(&comparer, entries); err != nil {
		return err
	}
	var extra [1]byte
	count, err := io.ReadFull(comparer.source, extra[:])
	if count != 0 {
		return errNoncanonicalEncoding
	}
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func (writer *canonicalComparingWriter) Write(data []byte) (int, error) {
	compared := 0
	for compared < len(data) {
		chunkSize := min(len(writer.buffer), len(data)-compared)
		actual := writer.buffer[:chunkSize]
		count, err := io.ReadFull(writer.source, actual)
		if count != chunkSize || !bytes.Equal(actual, data[compared:compared+chunkSize]) {
			return compared, errNoncanonicalEncoding
		}
		if err != nil {
			return compared, err
		}
		compared += chunkSize
	}
	return compared, nil
}
