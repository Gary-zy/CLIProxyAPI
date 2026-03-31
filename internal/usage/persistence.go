package usage

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	log "github.com/sirupsen/logrus"
)

const (
	defaultPersistenceFilename = "usage-statistics.json"
	persistenceVersion         = 1
	persistDebounceDelay       = time.Second
)

type statisticsPersistence struct {
	mu       sync.Mutex
	saveMu   sync.Mutex
	path     string
	debounce time.Duration
	timer    *time.Timer
}

type persistedStatistics struct {
	Version int                `json:"version"`
	SavedAt time.Time          `json:"saved_at,omitempty"`
	Usage   StatisticsSnapshot `json:"usage"`
}

func newStatisticsPersistence() *statisticsPersistence {
	return &statisticsPersistence{debounce: persistDebounceDelay}
}

// DefaultPersistencePath resolves the usage statistics file path beside config.yaml.
func DefaultPersistencePath(configFilePath string) string {
	configFilePath = strings.TrimSpace(configFilePath)
	if configFilePath == "" {
		return ""
	}
	if !filepath.IsAbs(configFilePath) {
		if absPath, err := filepath.Abs(configFilePath); err == nil {
			configFilePath = absPath
		}
	}
	if info, err := os.Stat(configFilePath); err == nil && info.IsDir() {
		return filepath.Join(configFilePath, defaultPersistenceFilename)
	}
	return filepath.Join(filepath.Dir(configFilePath), defaultPersistenceFilename)
}

// ConfigureDefaultPersistence enables auto-save for the shared statistics store.
func ConfigureDefaultPersistence(configFilePath string) error {
	return defaultRequestStatistics.EnablePersistence(DefaultPersistencePath(configFilePath))
}

// FlushDefaultPersistence forces a synchronous write of the shared statistics store.
func FlushDefaultPersistence() error {
	return defaultRequestStatistics.FlushPersistence()
}

// EnablePersistence loads an existing snapshot and enables debounced auto-save.
func (s *RequestStatistics) EnablePersistence(path string) error {
	if s == nil {
		return nil
	}
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		absPath, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve usage statistics path: %w", err)
		}
		path = absPath
	}
	if s.persist == nil {
		s.persist = newStatisticsPersistence()
	}
	s.persist.setPath(path)
	return s.loadFromFile(path)
}

// FlushPersistence forces a synchronous write of the current snapshot.
func (s *RequestStatistics) FlushPersistence() error {
	if s == nil || s.persist == nil {
		return nil
	}
	return s.persist.saveNow(s, true)
}

func (s *RequestStatistics) loadFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read usage statistics file: %w", err)
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil
	}

	var payload persistedStatistics
	if err := json.Unmarshal(data, &payload); err != nil {
		return fmt.Errorf("decode usage statistics file: %w", err)
	}
	if payload.Version != 0 && payload.Version != persistenceVersion {
		return fmt.Errorf("unsupported usage statistics version %d", payload.Version)
	}
	s.MergeSnapshot(payload.Usage)
	return nil
}

func (p *statisticsPersistence) setPath(path string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.path = path
}

func (p *statisticsPersistence) schedule(stats *RequestStatistics) {
	if p == nil || stats == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.path == "" {
		return
	}
	if p.timer == nil {
		p.timer = time.AfterFunc(p.debounce, func() {
			if err := p.saveNow(stats, false); err != nil {
				log.WithError(err).Warn("usage: failed to persist usage statistics")
			}
		})
		return
	}
	p.timer.Reset(p.debounce)
}

func (p *statisticsPersistence) saveNow(stats *RequestStatistics, stopTimer bool) error {
	if p == nil || stats == nil {
		return nil
	}

	p.mu.Lock()
	path := p.path
	if stopTimer && p.timer != nil {
		p.timer.Stop()
	}
	p.timer = nil
	p.mu.Unlock()

	if path == "" {
		return nil
	}

	p.saveMu.Lock()
	defer p.saveMu.Unlock()

	payload := persistedStatistics{
		Version: persistenceVersion,
		SavedAt: time.Now().UTC(),
		Usage:   stats.Snapshot(),
	}
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("encode usage statistics file: %w", err)
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create usage statistics directory: %w", err)
	}

	tempPath := path + ".tmp"
	if err := os.WriteFile(tempPath, data, 0o600); err != nil {
		return fmt.Errorf("write usage statistics temp file: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("replace usage statistics file: %w", err)
	}
	return nil
}
