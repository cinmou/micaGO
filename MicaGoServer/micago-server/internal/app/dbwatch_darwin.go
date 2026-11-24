//go:build darwin

package app

import (
	"context"
	"errors"
	"log"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const (
	// oEvtonly is macOS O_EVTONLY: opens a descriptor for event notifications
	// only, without blocking SQLite locks or volume unmounts.
	oEvtonly = 0x8000

	kqueueWakeIdent uint64 = 1

	vnodeWatchFlags  uint32 = syscall.NOTE_WRITE | syscall.NOTE_EXTEND | syscall.NOTE_ATTRIB | syscall.NOTE_DELETE | syscall.NOTE_RENAME | syscall.NOTE_REVOKE
	vnodeDeleteFlags uint32 = syscall.NOTE_DELETE | syscall.NOTE_RENAME | syscall.NOTE_REVOKE

	defaultDBWatchDebounce         = 25 * time.Millisecond
	defaultDBWatchFallbackInterval = 30 * time.Second
)

type dbWatchOptions struct {
	debounce         time.Duration
	fallbackInterval time.Duration
	onReady          func()
}

type watchedTarget struct {
	path  string
	fd    int
	dev   int32
	ino   uint64
	isDir bool
}

func runDBWatchLoop(
	ctx context.Context,
	dbPath string,
	diagnostics *syncDiagnostics,
	trigger func(string),
) {
	opts := dbWatchOptions{
		debounce:         defaultDBWatchDebounce,
		fallbackInterval: defaultDBWatchFallbackInterval,
	}
	if err := runDBKqueueWatchLoop(ctx, dbPath, opts, diagnostics, trigger); err != nil && ctx.Err() == nil {
		log.Printf("chat.db kqueue watcher failed (%v); falling back to mtime polling", err)
		runDBMtimeSyncLoop(ctx, dbPath, 750*time.Millisecond, diagnostics, trigger)
	}
}

func runDBKqueueWatchLoop(
	ctx context.Context,
	dbPath string,
	opts dbWatchOptions,
	diagnostics *syncDiagnostics,
	trigger func(string),
) error {
	if ctx.Err() != nil {
		return nil
	}
	if opts.debounce <= 0 {
		opts.debounce = defaultDBWatchDebounce
	}
	if opts.fallbackInterval <= 0 {
		opts.fallbackInterval = defaultDBWatchFallbackInterval
	}

	kq, err := syscall.Kqueue()
	if err != nil {
		return err
	}
	syscall.CloseOnExec(kq)

	var kqMu sync.Mutex
	kqClosed := false

	wakeReg := []syscall.Kevent_t{{
		Ident:  kqueueWakeIdent,
		Filter: syscall.EVFILT_USER,
		Flags:  syscall.EV_ADD | syscall.EV_CLEAR,
	}}
	if err := keventRegister(kq, wakeReg); err != nil {
		_ = syscall.Close(kq)
		return err
	}

	byPath := make(map[string]*watchedTarget, 4)
	byFD := make(map[int]*watchedTarget, 4)

	stopWake := context.AfterFunc(ctx, func() {
		kqMu.Lock()
		defer kqMu.Unlock()
		if kqClosed {
			return
		}
		ev := []syscall.Kevent_t{{
			Ident:  kqueueWakeIdent,
			Filter: syscall.EVFILT_USER,
			Fflags: syscall.NOTE_TRIGGER,
		}}
		_, _ = syscall.Kevent(kq, ev, nil, nil)
	})

	defer func() {
		stopWake()
		for _, w := range byPath {
			_ = syscall.Close(w.fd)
		}
		kqMu.Lock()
		kqClosed = true
		_ = syscall.Close(kq)
		kqMu.Unlock()
	}()

	dirPath := filepath.Dir(dbPath)
	targets := []string{dirPath, dbPath, dbPath + "-wal", dbPath + "-shm"}

	detachTarget := func(w *watchedTarget) {
		delete(byPath, w.path)
		delete(byFD, w.fd)
		_ = syscall.Close(w.fd)
	}

	attachTarget := func(path string, isDir bool) (bool, error) {
		fd, err := syscall.Open(path, oEvtonly|syscall.O_CLOEXEC, 0)
		if err != nil {
			if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR) {
				return false, nil
			}
			return false, err
		}
		var st syscall.Stat_t
		if err := syscall.Fstat(fd, &st); err != nil {
			_ = syscall.Close(fd)
			return false, err
		}
		change := []syscall.Kevent_t{{
			Ident:  uint64(fd),
			Filter: syscall.EVFILT_VNODE,
			Flags:  syscall.EV_ADD | syscall.EV_CLEAR,
			Fflags: vnodeWatchFlags,
		}}
		if err := keventRegister(kq, change); err != nil {
			_ = syscall.Close(fd)
			return false, err
		}
		w := &watchedTarget{
			path:  path,
			fd:    fd,
			dev:   st.Dev,
			ino:   st.Ino,
			isDir: isDir,
		}
		byPath[path] = w
		byFD[fd] = w
		return true, nil
	}

	syncWatches := func(initial bool) (bool, error) {
		newlyAttachedFile := false
		for _, p := range targets {
			isDir := p == dirPath
			if w, ok := byPath[p]; ok {
				var st syscall.Stat_t
				if err := syscall.Stat(p, &st); err != nil {
					detachTarget(w)
					continue
				}
				if st.Dev != w.dev || st.Ino != w.ino {
					detachTarget(w)
					attached, err := attachTarget(p, isDir)
					if err != nil && initial && isDir {
						return false, err
					}
					if attached && !isDir {
						newlyAttachedFile = true
					}
				}
				continue
			}
			attached, err := attachTarget(p, isDir)
			if err != nil && initial && isDir {
				return false, err
			}
			if attached && !isDir {
				newlyAttachedFile = true
			}
		}
		return newlyAttachedFile, nil
	}

	if _, err := syncWatches(true); err != nil {
		return err
	}
	if byPath[dirPath] == nil {
		return syscall.ENOENT
	}

	var lastChatDB, lastWAL, lastSHM int64
	checkMtimes := func(updateBaseline bool) bool {
		chatDB, wal, shm := messageDBMtimes(dbPath)
		if diagnostics != nil {
			diagnostics.recordDBMtime(chatDB, wal, shm)
		}
		changed := (chatDB != nil && *chatDB > lastChatDB) ||
			(wal != nil && *wal > lastWAL) ||
			(shm != nil && *shm > lastSHM)
		if updateBaseline {
			if chatDB != nil {
				lastChatDB = *chatDB
			}
			if wal != nil {
				lastWAL = *wal
			}
			if shm != nil {
				lastSHM = *shm
			}
		}
		return changed
	}
	checkMtimes(true)
	if opts.onReady != nil {
		opts.onReady()
	}

	processEvents := func(evs []syscall.Kevent_t) (dirty bool, wakeExit bool) {
		needSyncWatches := false
		dirTriggered := false
		for _, ev := range evs {
			if ev.Filter == syscall.EVFILT_USER && ev.Ident == kqueueWakeIdent {
				if ctx.Err() != nil {
					return false, true
				}
				continue
			}
			if ev.Filter != syscall.EVFILT_VNODE {
				continue
			}
			w, ok := byFD[int(ev.Ident)]
			if !ok {
				continue
			}
			if w.isDir {
				dirTriggered = true
				needSyncWatches = true
				if ev.Fflags&vnodeDeleteFlags != 0 {
					detachTarget(w)
				}
			} else {
				dirty = true
				if ev.Fflags&vnodeDeleteFlags != 0 {
					detachTarget(w)
					needSyncWatches = true
				}
			}
		}
		if needSyncWatches {
			newlyAttached, _ := syncWatches(false)
			if newlyAttached {
				dirty = true
			} else if dirTriggered && !dirty {
				if checkMtimes(false) {
					dirty = true
				}
			}
		}
		return dirty, false
	}

	events := make([]syscall.Kevent_t, 16)
	pendingDebounce := false
	var debounceDeadline time.Time
	nextFallback := time.Now().Add(opts.fallbackInterval)

	for {
		if ctx.Err() != nil {
			return nil
		}

		now := time.Now()
		if pendingDebounce && !now.Before(debounceDeadline) {
			// Non-blocking drain to process any pending DELETE/RENAME events.
			zeroTS := syscall.NsecToTimespec(0)
			for {
				n, err := syscall.Kevent(kq, nil, events, &zeroTS)
				if err != nil {
					if errors.Is(err, syscall.EINTR) {
						continue
					}
					break
				}
				if n == 0 {
					break
				}
				_, wakeExit := processEvents(events[:n])
				if wakeExit || ctx.Err() != nil {
					return nil
				}
			}
			pendingDebounce = false
			checkMtimes(true)
			trigger("chatdb_kqueue")
			nextFallback = time.Now().Add(opts.fallbackInterval)
			continue
		}

		if !pendingDebounce && !now.Before(nextFallback) {
			newlyAttached, _ := syncWatches(false)
			mtimeAdvanced := checkMtimes(true)
			if newlyAttached || mtimeAdvanced {
				trigger("chatdb_mtime")
			}
			nextFallback = time.Now().Add(opts.fallbackInterval)
			continue
		}

		waitUntil := nextFallback
		if pendingDebounce && debounceDeadline.Before(waitUntil) {
			waitUntil = debounceDeadline
		}
		waitDur := time.Until(waitUntil)
		if waitDur < time.Millisecond {
			waitDur = time.Millisecond
		}
		ts := syscall.NsecToTimespec(waitDur.Nanoseconds())
		n, err := syscall.Kevent(kq, nil, events, &ts)
		if err != nil {
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if n > 0 {
			dirty, wakeExit := processEvents(events[:n])
			if wakeExit || ctx.Err() != nil {
				return nil
			}
			if dirty && !pendingDebounce {
				pendingDebounce = true
				debounceDeadline = time.Now().Add(opts.debounce)
			}
		}
	}
}

func keventRegister(kq int, changes []syscall.Kevent_t) error {
	for {
		_, err := syscall.Kevent(kq, changes, nil, nil)
		if err != nil && errors.Is(err, syscall.EINTR) {
			continue
		}
		return err
	}
}
