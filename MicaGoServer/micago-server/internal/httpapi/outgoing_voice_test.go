package httpapi

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestNativeVoiceConversionRemovesOnlyUnsubmittedOriginal(t *testing.T) {
	if _, err := exec.LookPath("afconvert"); err != nil {
		t.Skip("macOS afconvert required")
	}
	dir := t.TempDir()
	// A short PCM WAV, generated locally; no user message/media is read or sent.
	var wav bytes.Buffer
	wav.WriteString("RIFF")
	binary.Write(&wav, binary.LittleEndian, uint32(36+3200))
	wav.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(16), uint16(1), uint16(1), uint32(16000), uint32(32000), uint16(2), uint16(16)} {
		binary.Write(&wav, binary.LittleEndian, v)
	}
	wav.WriteString("data")
	binary.Write(&wav, binary.LittleEndian, uint32(3200))
	wav.Write(make([]byte, 3200))
	input := filepath.Join(dir, "input.wav")
	if err := os.WriteFile(input, wav.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(dir, "voice_test.m4a")
	if out, err := exec.Command("afconvert", "-f", "m4af", "-d", "aac", input, source).CombinedOutput(); err != nil {
		t.Fatalf("create fixture: %s %v", out, err)
	}
	h := &Handlers{logger: log.New(io.Discard, "", 0)}
	dest, ok := h.prepareOutgoingVoiceAttachment(context.Background(), source, "voice_test.m4a", true)
	if !ok {
		t.Fatal("native CAF conversion failed")
	}
	if _, err := os.Stat(source); !os.IsNotExist(err) {
		t.Fatal("unsubmitted original remains")
	}
	if _, err := os.Stat(input); err != nil {
		t.Fatal("unrelated file removed")
	}
	if out, err := exec.Command("afinfo", dest).CombinedOutput(); err != nil {
		t.Fatalf("invalid CAF output: %s %v", out, err)
	}
}
