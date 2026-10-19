package httpapi

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCachedMediaConcurrentRequestsConvertOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "video.mp4")
	var calls atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			f, err := cachedMedia(context.Background(), path, func(tmp string) error {
				calls.Add(1)
				return os.WriteFile(tmp, []byte("complete"), 0o600)
			})
			if err != nil {
				t.Error(err)
				return
			}
			defer f.Close()
			data, err := io.ReadAll(f)
			if err != nil || string(data) != "complete" {
				t.Errorf("incomplete result: %q %v", data, err)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatalf("converted %d times", calls.Load())
	}
}

func TestCachedMediaFailureNeverPublishesPartialFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "audio.m4a")
	_, err := cachedMedia(context.Background(), path, func(tmp string) error {
		if err := os.WriteFile(tmp, []byte("partial"), 0o600); err != nil {
			return err
		}
		return errors.New("converter interrupted")
	})
	if err == nil {
		t.Fatal("expected failure")
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed conversion left files: %v %v", entries, err)
	}
	f, err := cachedMedia(context.Background(), path, func(tmp string) error { return os.WriteFile(tmp, []byte("retry"), 0o600) })
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	data, _ := io.ReadAll(f)
	if string(data) != "retry" {
		t.Fatalf("got %q", data)
	}
}

func TestCachedMediaHitDoesNotWaitForConverter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ready.png")
	if err := os.WriteFile(path, []byte("ready"), 0o600); err != nil {
		t.Fatal(err)
	}
	mediaConversionSlot <- struct{}{}
	defer func() { <-mediaConversionSlot }()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f, err := cachedMedia(ctx, path, func(string) error { t.Fatal("cache hit converted"); return nil })
	if err != nil {
		t.Fatal("ready file blocked on converter:", err)
	}
	f.Close()
}

func TestMediaCacheEvictsOldAndOversizedFilesWithoutBreakingOpenReaders(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	old := filepath.Join(dir, "old.png")
	part := filepath.Join(dir, ".part-interrupted.mp4")
	for _, path := range []string{old, part} {
		if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
			t.Fatal(err)
		}
		age := now.Add(-8 * 24 * time.Hour)
		os.Chtimes(path, age, age)
	}
	pruneMediaCache(dir, "", now)
	for _, path := range []string{old, part} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("stale cache survived: %s", path)
		}
	}
	path := filepath.Join(dir, "large.mp4")
	f, err := cachedMedia(context.Background(), path, func(tmp string) error {
		f, e := os.Create(tmp)
		if e != nil {
			return e
		}
		defer f.Close()
		if _, e = f.Write([]byte("ok")); e != nil {
			return e
		}
		return f.Truncate(mediaCacheBytes + 1)
	})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("oversized derived file was retained")
	}
	var data [2]byte
	if _, err := io.ReadFull(f, data[:]); err != nil || string(data[:]) != "ok" {
		t.Fatalf("eviction broke reader: %q %v", data, err)
	}
}
