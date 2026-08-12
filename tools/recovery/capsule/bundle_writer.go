package main

import (
	"io"
	"os"
	"sync"
)

type drainingCappedWriter struct {
	mutex    sync.Mutex
	file     *os.File
	limit    int64
	written  int64
	overflow bool
}

func newDrainingCappedWriter(file *os.File, limit int64) *drainingCappedWriter {
	return &drainingCappedWriter{file: file, limit: limit}
}

func (writer *drainingCappedWriter) Write(data []byte) (int, error) {
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	requested := len(data)
	if requested == 0 {
		return 0, nil
	}
	remaining := writer.limit - writer.written
	if remaining <= 0 {
		writer.overflow = true
		return requested, nil
	}
	accepted := requested
	if int64(accepted) > remaining {
		accepted = int(remaining)
	}
	written, err := writer.file.Write(data[:accepted])
	writer.written += int64(written)
	if err != nil {
		return written, err
	}
	if written != accepted {
		return written, io.ErrShortWrite
	}
	if accepted != requested {
		writer.overflow = true
	}
	return requested, nil
}

func (writer *drainingCappedWriter) overflowedLimit() bool {
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	return writer.overflow
}

func (writer *drainingCappedWriter) bytesWritten() int64 {
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	return writer.written
}
