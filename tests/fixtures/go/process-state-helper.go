package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

const fixtureLifetime = 30 * time.Second

func writePID(path string, pid int) error {
	return os.WriteFile(path, []byte(strconv.Itoa(pid)+"\n"), 0o600)
}

func waitForFile(path string) error {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !os.IsNotExist(err) {
			return err
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s", path)
}

func runZombie(pidFile string) error {
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM)
	defer signal.Stop(stop)
	child := exec.Command(os.Args[0], "exit")
	if err := child.Start(); err != nil {
		return err
	}
	if err := writePID(pidFile, child.Process.Pid); err != nil {
		return err
	}
	select {
	case <-stop:
	case <-time.After(fixtureLifetime):
	}
	return child.Wait()
}

func runHTTP404(portFile string) error {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	tcpListener := listener.(*net.TCPListener)
	if err := tcpListener.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return err
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil {
		return err
	}
	if err := writePID(portFile, portNumber); err != nil {
		return err
	}
	connection, err := listener.Accept()
	if err != nil {
		return err
	}
	defer connection.Close()
	_, err = io.WriteString(connection,
		"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
	return err
}

func runTermResistant(readyFile string) error {
	signal.Ignore(syscall.SIGTERM)
	if err := os.WriteFile(readyFile, []byte("ready\n"), 0o600); err != nil {
		return err
	}
	time.Sleep(fixtureLifetime)
	return nil
}

func runGroupLeader(pidFile, childReady, releaseFile string) error {
	child := exec.Command(os.Args[0], "term-resistant", childReady)
	if err := child.Start(); err != nil {
		return err
	}
	if err := waitForFile(childReady); err != nil {
		return err
	}
	if err := writePID(pidFile, child.Process.Pid); err != nil {
		return err
	}
	return waitForFile(releaseFile)
}

func run() error {
	if len(os.Args) == 2 && os.Args[1] == "exit" {
		return nil
	}
	if len(os.Args) == 3 && os.Args[1] == "zombie" {
		return runZombie(os.Args[2])
	}
	if len(os.Args) == 3 && os.Args[1] == "term-resistant" {
		return runTermResistant(os.Args[2])
	}
	if len(os.Args) == 3 && os.Args[1] == "http-404" {
		return runHTTP404(os.Args[2])
	}
	if len(os.Args) == 5 && os.Args[1] == "group-leader" {
		return runGroupLeader(os.Args[2], os.Args[3], os.Args[4])
	}
	return fmt.Errorf("invalid process-state fixture arguments")
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
