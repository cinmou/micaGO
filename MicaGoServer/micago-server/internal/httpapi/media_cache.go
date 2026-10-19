package httpapi

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// One conversion at a time bounds native converter memory/CPU and coalesces
// concurrent requests: waiters recheck the completed file before converting.
var mediaConversionSlot = make(chan struct{}, 1)

const mediaCacheBytes int64 = 512 << 20 // per derived-media directory
const mediaCacheAge = 7 * 24 * time.Hour

// cachedMedia opens the result before releasing the slot. Eviction can unlink
// a cached file without interrupting a response already reading its descriptor.
func cachedMedia(ctx context.Context, path string, convert func(string) error) (*os.File, error) {
	// Existing previews must remain responsive while a different large video
	// is converting. Open descriptors remain valid if eviction unlinks a path.
	if f := openFreshMedia(path); f != nil {
		return f, nil
	}
	select {
	case mediaConversionSlot <- struct{}{}:
		defer func() { <-mediaConversionSlot }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	created := false
	if err != nil || info.Size() == 0 || time.Since(info.ModTime()) > mediaCacheAge {
		created = true
		pruneMediaCache(filepath.Dir(path), path, time.Now())
		// Keep the format suffix: native converters use it to infer the output.
		f, err := os.CreateTemp(filepath.Dir(path), ".part-*"+filepath.Ext(path))
		if err != nil {
			return nil, err
		}
		tmp := f.Name()
		_ = f.Close()
		_ = os.Remove(tmp) // afconvert expects a new destination
		defer os.Remove(tmp)
		if err := convert(tmp); err != nil {
			return nil, err
		}
		info, err := os.Stat(tmp)
		if err != nil {
			return nil, err
		}
		if info.Size() == 0 {
			return nil, os.ErrInvalid
		}
		if err := os.Chmod(tmp, 0o600); err != nil {
			return nil, err
		}
		if err := os.Rename(tmp, path); err != nil {
			return nil, err
		}
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	// Recently used files survive size eviction. This cache is disposable.
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	if created {
		pruneMediaCache(filepath.Dir(path), "", now)
	}
	return f, nil
}

func openFreshMedia(path string) *os.File {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || time.Since(info.ModTime()) > mediaCacheAge {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	return f
}

func pruneMediaCache(dir, keep string, now time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type candidate struct {
		path     string
		size     int64
		modified time.Time
	}
	var files []candidate
	var total int64
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if path != keep && (info.Size() == 0 || now.Sub(info.ModTime()) > mediaCacheAge ||
			(strings.Contains(entry.Name(), ".part") && now.Sub(info.ModTime()) > time.Hour)) {
			if os.Remove(path) == nil {
				continue
			}
		}
		total += info.Size()
		if path != keep {
			files = append(files, candidate{path, info.Size(), info.ModTime()})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].modified.Before(files[j].modified) })
	for _, file := range files {
		if total <= mediaCacheBytes {
			break
		}
		if os.Remove(file.path) == nil {
			total -= file.size
		}
	}
}

func serveCachedMedia(w http.ResponseWriter, r *http.Request, file *os.File) {
	info, err := file.Stat()
	if err != nil {
		writeInternalError(w)
		return
	}
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}
