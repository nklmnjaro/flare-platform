package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	processSnapshotRetryBudget = 20 * time.Millisecond
	processSnapshotRetryPoll   = time.Millisecond
)

type processSnapshot struct {
	PID       int
	Group     int
	Starttime uint64
	State     byte
}

type processIdentity struct {
	PID       int
	Group     int
	Starttime uint64
}

type processInspector func(int) (processSnapshot, bool, error)
type processGroupLister func(int, int) ([]processSnapshot, error)
type processGroupSignaler func(int, syscall.Signal) error

type ownedProcessGroup struct {
	leader  processIdentity
	inspect processInspector
	list    processGroupLister
	signal  processGroupSignaler
}

func captureOwnedProcessGroup(pid int) (ownedProcessGroup, error) {
	return captureOwnedProcessGroupWithInspector(pid, readProcessSnapshot)
}

func captureOwnedProcessGroupWithInspector(
	pid int,
	inspect processInspector,
) (ownedProcessGroup, error) {
	deadline := time.Now().Add(processSnapshotRetryBudget)
	var snapshot processSnapshot
	for {
		observed, present, err := inspect(pid)
		if err != nil {
			return ownedProcessGroup{}, err
		}
		if present {
			snapshot = observed
			break
		}
		if !time.Now().Before(deadline) {
			return ownedProcessGroup{}, errors.New("started Git process remained absent from /proc")
		}
		time.Sleep(processSnapshotRetryPoll)
	}
	if snapshot.Group != pid {
		return ownedProcessGroup{}, fmt.Errorf(
			"started Git process group = %d, want leader PID %d", snapshot.Group, pid)
	}
	return ownedProcessGroup{
		leader: processIdentity{
			PID:       snapshot.PID,
			Group:     snapshot.Group,
			Starttime: snapshot.Starttime,
		},
		inspect: inspect,
		list:    listLiveProcessGroupMembers,
		signal:  sendProcessGroupSignal,
	}, nil
}

func readProcessSnapshot(pid int) (processSnapshot, bool, error) {
	payload, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		if processStatEntryVanished(err) {
			return processSnapshot{}, false, nil
		}
		return processSnapshot{}, false, err
	}
	snapshot, err := parseProcessSnapshot(pid, payload)
	return snapshot, true, err
}

func parseProcessSnapshot(pid int, payload []byte) (processSnapshot, error) {
	open := bytes.IndexByte(payload, '(')
	close := bytes.LastIndex(payload, []byte(") "))
	if open < 1 || close <= open {
		return processSnapshot{}, errors.New("process stat record is malformed")
	}
	recordedPID, err := strconv.Atoi(strings.TrimSpace(string(payload[:open])))
	if err != nil || recordedPID != pid {
		return processSnapshot{}, errors.New("process stat PID is malformed")
	}
	fields := bytes.Fields(payload[close+2:])
	if len(fields) < 20 || len(fields[0]) != 1 {
		return processSnapshot{}, errors.New("process stat fields are malformed")
	}
	group, err := strconv.Atoi(string(fields[2]))
	if err != nil {
		return processSnapshot{}, errors.New("process stat group is malformed")
	}
	starttime, err := strconv.ParseUint(string(fields[19]), 10, 64)
	if err != nil || starttime == 0 {
		return processSnapshot{}, errors.New("process stat starttime is malformed")
	}
	return processSnapshot{
		PID:       pid,
		Group:     group,
		Starttime: starttime,
		State:     fields[0][0],
	}, nil
}

func processStatEntryVanished(err error) bool {
	return os.IsNotExist(err) || errors.Is(err, syscall.ESRCH)
}

func (group ownedProcessGroup) leaderSnapshot() (processSnapshot, error) {
	deadline := time.Now().Add(processSnapshotRetryBudget)
	for {
		snapshot, present, err := group.inspect(group.leader.PID)
		if err != nil {
			return processSnapshot{}, err
		}
		if present {
			if snapshot.PID != group.leader.PID || snapshot.Group != group.leader.Group ||
				snapshot.Starttime != group.leader.Starttime {
				return processSnapshot{}, errors.New("owned process-group leader identity changed")
			}
			return snapshot, nil
		}
		if !time.Now().Before(deadline) {
			return processSnapshot{}, errors.New(
				"owned process-group leader remained absent before wait")
		}
		time.Sleep(processSnapshotRetryPoll)
	}
}

func processTerminal(state byte) bool {
	return state == 'Z' || state == 'X' || state == 'x'
}

func waitForLeaderTerminal(
	group ownedProcessGroup,
	budget time.Duration,
	pollEvery time.Duration,
) (bool, error) {
	deadline := time.Now().Add(budget)
	for {
		snapshot, err := group.leaderSnapshot()
		if err != nil {
			return false, err
		}
		if processTerminal(snapshot.State) {
			return false, nil
		}
		if !time.Now().Before(deadline) {
			return true, nil
		}
		time.Sleep(pollEvery)
	}
}

func listLiveProcessGroupMembers(processGroup, excludedPID int) ([]processSnapshot, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	members := make([]processSnapshot, 0)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 || pid == excludedPID {
			continue
		}
		snapshot, present, err := readProcessSnapshot(pid)
		if err != nil {
			return nil, err
		}
		if present && snapshot.Group == processGroup && !processTerminal(snapshot.State) {
			members = append(members, snapshot)
		}
	}
	sort.Slice(members, func(left, right int) bool {
		return members[left].PID < members[right].PID
	})
	return members, nil
}

func (group ownedProcessGroup) liveMembers(excludeTerminalLeader bool) ([]processSnapshot, error) {
	leader, err := group.leaderSnapshot()
	if err != nil {
		return nil, err
	}
	if excludeTerminalLeader {
		if !processTerminal(leader.State) {
			return nil, errors.New("process-group leader is not terminal")
		}
	}
	members, err := group.list(group.leader.Group, leader.PID)
	if err != nil {
		return nil, err
	}
	if !processTerminal(leader.State) {
		members = append(members, leader)
		sort.Slice(members, func(left, right int) bool {
			return members[left].PID < members[right].PID
		})
	}
	return members, nil
}

func sendProcessGroupSignal(processGroup int, signal syscall.Signal) error {
	err := syscall.Kill(-processGroup, signal)
	if err == nil || errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}

func (group ownedProcessGroup) signalIfOwned(signal syscall.Signal) error {
	if _, err := group.leaderSnapshot(); err != nil {
		return err
	}
	return group.signal(group.leader.Group, signal)
}

func waitForOwnedGroupNonlive(
	group ownedProcessGroup,
	excludeTerminalLeader bool,
	budget time.Duration,
	pollEvery time.Duration,
) (bool, error) {
	deadline := time.Now().Add(budget)
	for {
		members, err := group.liveMembers(excludeTerminalLeader)
		if err != nil {
			return false, err
		}
		if len(members) == 0 {
			return true, nil
		}
		if !time.Now().Before(deadline) {
			return false, nil
		}
		time.Sleep(pollEvery)
	}
}

func terminateOwnedProcessGroup(
	group ownedProcessGroup,
	excludeTerminalLeader bool,
	termGrace time.Duration,
	killGrace time.Duration,
	pollEvery time.Duration,
) (bool, error) {
	members, err := group.liveMembers(excludeTerminalLeader)
	if err != nil || len(members) == 0 {
		return false, err
	}
	if err := group.signalIfOwned(syscall.SIGTERM); err != nil {
		return true, err
	}
	nonlive, err := waitForOwnedGroupNonlive(
		group, excludeTerminalLeader, termGrace, pollEvery)
	if err != nil {
		return true, err
	}
	if nonlive {
		return true, nil
	}
	if err := group.signalIfOwned(syscall.SIGKILL); err != nil {
		return true, err
	}
	nonlive, err = waitForOwnedGroupNonlive(
		group, excludeTerminalLeader, killGrace, pollEvery)
	if err != nil {
		return true, err
	}
	if !nonlive {
		return true, errors.New("owned process group remained live after SIGKILL")
	}
	return true, nil
}

func confirmProcessGroupNonlive(
	processGroup int,
	pollEvery time.Duration,
	list processGroupLister,
) error {
	for sample := 0; sample < 2; sample++ {
		members, err := list(processGroup, 0)
		if err != nil {
			return err
		}
		if len(members) != 0 {
			return errors.New("process group is live after direct wait")
		}
		if sample == 0 {
			time.Sleep(pollEvery)
		}
	}
	return nil
}
