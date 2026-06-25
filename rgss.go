package main

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var errAlreadyPatched = errors.New("game already patched")

// ============================ RGSSAD extraction ============================

const rgssMagic = "RGSSAD\x00"

func u32(v uint32) uint32 { return v }

// extractArchive finds Game.rgss3a/rgss2a/rgssad in root and extracts every
// entry to disk (relative to root), creating parent directories as needed.
func extractArchive(root string) error {
	archive := findArchive(root)
	if archive == "" {
		return fmt.Errorf("no RGSSAD archive (Game.rgss3a/rgss2a/rgssad) found in %s", root)
	}
	Println("Decrypting", filepath.Base(archive), "...")

	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()

	header := make([]byte, 8)
	if _, err := io.ReadFull(f, header); err != nil {
		return err
	}
	if string(header[:7]) != rgssMagic {
		return fmt.Errorf("not an RGSSAD archive: %s", archive)
	}

	var count int
	switch header[7] {
	case 1, 2:
		count, err = extractV1(f, root)
	case 3:
		count, err = extractV3(f, root)
	default:
		return fmt.Errorf("unsupported RGSSAD version: %d", header[7])
	}
	if err != nil {
		return err
	}
	Println("Extracted", count, "files.")
	return nil
}

func findArchive(root string) string {
	for _, name := range []string{"Game.rgss3a", "Game.rgss2a", "Game.rgssad"} {
		p := filepath.Join(root, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}

// ---- v3 (VX Ace) ----
func extractV3(f *os.File, root string) (int, error) {
	seedBuf := make([]byte, 4)
	if _, err := io.ReadFull(f, seedBuf); err != nil {
		return 0, err
	}
	baseKey := u32(binary.LittleEndian.Uint32(seedBuf)*9 + 3)

	type entry struct {
		name         string
		offset, size uint32
		key          uint32
	}
	var entries []entry

	read4 := func() (uint32, error) {
		b := make([]byte, 4)
		if _, err := io.ReadFull(f, b); err != nil {
			return 0, err
		}
		return binary.LittleEndian.Uint32(b), nil
	}

	for {
		off, err := read4()
		if err != nil {
			return 0, err
		}
		off ^= baseKey
		size, err := read4()
		if err != nil {
			return 0, err
		}
		size ^= baseKey
		fkey, err := read4()
		if err != nil {
			return 0, err
		}
		fkey ^= baseKey
		nameLen, err := read4()
		if err != nil {
			return 0, err
		}
		nameLen ^= baseKey

		if off == 0 {
			break
		}

		nameRaw := make([]byte, nameLen)
		if _, err := io.ReadFull(f, nameRaw); err != nil {
			return 0, err
		}
		entries = append(entries, entry{
			name:   decryptNameV3(nameRaw, baseKey),
			offset: off, size: size, key: fkey,
		})
	}

	for _, e := range entries {
		data := make([]byte, e.size)
		if _, err := f.ReadAt(data, int64(e.offset)); err != nil && err != io.EOF {
			return 0, err
		}
		decryptDataV3(data, e.key)
		if err := writeEntry(root, e.name, data); err != nil {
			return 0, err
		}
	}
	return len(entries), nil
}

func decryptNameV3(raw []byte, key uint32) string {
	kb := make([]byte, 4)
	binary.LittleEndian.PutUint32(kb, key)
	out := make([]byte, len(raw))
	for i, b := range raw {
		out[i] = b ^ kb[i%4]
	}
	return string(out)
}

func decryptDataV3(data []byte, fileKey uint32) {
	key := fileKey
	kb := make([]byte, 4)
	binary.LittleEndian.PutUint32(kb, key)
	for i := range data {
		data[i] ^= kb[i%4]
		if (i+1)%4 == 0 {
			key = u32(key*7 + 3)
			binary.LittleEndian.PutUint32(kb, key)
		}
	}
}

// ---- v1 (XP / VX) ----
func extractV1(f *os.File, root string) (int, error) {
	all, err := io.ReadAll(f)
	if err != nil {
		return 0, err
	}
	pos := 0
	key := uint32(0xDEADCAFE)
	count := 0

	readU32 := func() (uint32, bool) {
		if pos+4 > len(all) {
			return 0, false
		}
		v := binary.LittleEndian.Uint32(all[pos : pos+4])
		pos += 4
		return v, true
	}

	for pos < len(all) {
		raw, ok := readU32()
		if !ok {
			break
		}
		nameLen := raw ^ key
		key = u32(key*7 + 3)

		if pos+int(nameLen) > len(all) {
			break
		}
		nameBytes := make([]byte, nameLen)
		for i := 0; i < int(nameLen); i++ {
			nameBytes[i] = all[pos+i] ^ byte(key&0xff)
			key = u32(key*7 + 3)
		}
		pos += int(nameLen)
		name := string(nameBytes)

		raw, ok = readU32()
		if !ok {
			break
		}
		size := raw ^ key
		key = u32(key*7 + 3)

		if pos+int(size) > len(all) {
			break
		}
		data := make([]byte, size)
		copy(data, all[pos:pos+int(size)])
		pos += int(size)
		decryptDataV1(data, key)

		if err := writeEntry(root, name, data); err != nil {
			return 0, err
		}
		count++
	}
	return count, nil
}

func decryptDataV1(data []byte, key uint32) {
	kb := make([]byte, 4)
	binary.LittleEndian.PutUint32(kb, key)
	j := 0
	for i := range data {
		if j == 4 {
			j = 0
			key = u32(key*7 + 3)
			binary.LittleEndian.PutUint32(kb, key)
		}
		data[i] ^= kb[j]
		j++
	}
}

func writeEntry(root, name string, data []byte) error {
	safe := strings.TrimLeft(strings.ReplaceAll(name, "\\", "/"), "/")
	for _, part := range strings.Split(safe, "/") {
		if part == ".." {
			return fmt.Errorf("unsafe path in archive: %q", name)
		}
	}
	dest := filepath.Join(root, filepath.FromSlash(safe))
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dest, data, 0o644)
}

// ===================== Scripts.rvdata2 patching =====================
//
// Scripts.rvdata2 is a Ruby Marshal dump (version 4.8) of an Array of
// [magic, name, code] triples, where `code` is the zlib-deflated script source.
// We walk the Marshal stream just far enough to locate the byte span of the
// Scene_Base entry's code string, then splice in a freshly re-deflated, patched
// version — every other byte is preserved exactly.

type mreader struct {
	b   []byte
	pos int
}

func (m *mreader) byte() (byte, error) {
	if m.pos >= len(m.b) {
		return 0, io.ErrUnexpectedEOF
	}
	c := m.b[m.pos]
	m.pos++
	return c, nil
}

func (m *mreader) take(n int) ([]byte, error) {
	if n < 0 || m.pos+n > len(m.b) {
		return nil, io.ErrUnexpectedEOF
	}
	s := m.b[m.pos : m.pos+n]
	m.pos += n
	return s, nil
}

// long decodes Ruby Marshal's variable-length integer encoding.
func (m *mreader) long() (int, error) {
	c, err := m.byte()
	if err != nil {
		return 0, err
	}
	sc := int8(c)
	switch {
	case sc == 0:
		return 0, nil
	case sc >= 1 && sc <= 4:
		val := 0
		for i := 0; i < int(sc); i++ {
			b, err := m.byte()
			if err != nil {
				return 0, err
			}
			val |= int(b) << (8 * i)
		}
		return val, nil
	case sc >= 5:
		return int(sc) - 5, nil
	case sc >= -4 && sc <= -1:
		n := int(-sc)
		val := -1
		for i := 0; i < n; i++ {
			b, err := m.byte()
			if err != nil {
				return 0, err
			}
			val &^= 0xff << (8 * i)
			val |= int(b) << (8 * i)
		}
		return val, nil
	default: // sc <= -5
		return int(sc) + 5, nil
	}
}

// skipValue advances past one Marshal value of any type we expect in Scripts.
func (m *mreader) skipValue() error {
	t, err := m.byte()
	if err != nil {
		return err
	}
	switch t {
	case '0', 'T', 'F': // nil, true, false
		return nil
	case 'i': // Fixnum
		_, err := m.long()
		return err
	case '"', ':': // String, Symbol: long length + bytes
		n, err := m.long()
		if err != nil {
			return err
		}
		_, err = m.take(n)
		return err
	case ';': // symbol link
		_, err := m.long()
		return err
	case 'I': // ivar-wrapped object (e.g. UTF-8 String)
		if err := m.skipValue(); err != nil {
			return err
		}
		cnt, err := m.long()
		if err != nil {
			return err
		}
		for k := 0; k < cnt; k++ {
			if err := m.skipValue(); err != nil { // ivar name (symbol)
				return err
			}
			if err := m.skipValue(); err != nil { // ivar value
				return err
			}
		}
		return nil
	case '[': // Array
		c, err := m.long()
		if err != nil {
			return err
		}
		for k := 0; k < c; k++ {
			if err := m.skipValue(); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unsupported Marshal type %q at offset %d", t, m.pos-1)
	}
}

// readStringValue reads a String or ivar-wrapped String and returns its bytes.
func (m *mreader) readStringValue() ([]byte, error) {
	t, err := m.byte()
	if err != nil {
		return nil, err
	}
	switch t {
	case 'I':
		s, err := m.readStringValue() // inner "..." string
		if err != nil {
			return nil, err
		}
		cnt, err := m.long()
		if err != nil {
			return nil, err
		}
		for k := 0; k < cnt; k++ {
			if err := m.skipValue(); err != nil {
				return nil, err
			}
			if err := m.skipValue(); err != nil {
				return nil, err
			}
		}
		return s, nil
	case '"':
		n, err := m.long()
		if err != nil {
			return nil, err
		}
		return m.take(n)
	default:
		return nil, fmt.Errorf("expected String, got Marshal type %q at offset %d", t, m.pos-1)
	}
}

// encodeLong encodes a non-negative integer in Ruby Marshal long format.
func encodeLong(n int) []byte {
	if n == 0 {
		return []byte{0}
	}
	if n <= 122 {
		return []byte{byte(n + 5)}
	}
	var b []byte
	v := n
	for v > 0 {
		b = append(b, byte(v&0xff))
		v >>= 8
	}
	return append([]byte{byte(len(b))}, b...)
}

// patchScriptsRvdata2 reads Scripts.rvdata2, injects the cheat payload into the
// Scene_Base script, and writes it back. Returns errAlreadyPatched if the cheat
// marker is already present.
func patchScriptsRvdata2(path, payload, marker, injectLine string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	m := &mreader{b: data}
	if len(data) < 2 || data[0] != 4 || data[1] != 8 {
		return errors.New("not a Marshal 4.8 stream")
	}
	m.pos = 2

	t, err := m.byte()
	if err != nil || t != '[' {
		return errors.New("expected top-level Array in Scripts.rvdata2")
	}
	count, err := m.long()
	if err != nil {
		return err
	}

	for i := 0; i < count; i++ {
		t, err := m.byte()
		if err != nil {
			return err
		}
		if t != '[' {
			return fmt.Errorf("expected script entry array at index %d", i)
		}
		n, err := m.long()
		if err != nil {
			return err
		}
		if n < 3 {
			return fmt.Errorf("unexpected script entry arity %d", n)
		}
		if err := m.skipValue(); err != nil { // [0] magic
			return err
		}
		nameBytes, err := m.readStringValue() // [1] name
		if err != nil {
			return err
		}
		codeStart := m.pos
		codeBytes, err := m.readStringValue() // [2] deflated code
		if err != nil {
			return err
		}
		codeEnd := m.pos
		for j := 3; j < n; j++ {
			if err := m.skipValue(); err != nil {
				return err
			}
		}

		if string(nameBytes) != "Scene_Base" {
			continue
		}

		// Found Scene_Base: inflate, patch, re-deflate, splice.
		source, err := zlibInflate(codeBytes)
		if err != nil {
			return fmt.Errorf("inflate Scene_Base: %w", err)
		}
		if strings.Contains(string(source), marker) {
			return errAlreadyPatched
		}
		patched, err := injectSceneBase(string(source), payload, injectLine)
		if err != nil {
			return err
		}
		deflated, err := zlibDeflate([]byte(patched))
		if err != nil {
			return err
		}

		var out bytes.Buffer
		out.Write(data[:codeStart])
		out.WriteByte('"')
		out.Write(encodeLong(len(deflated)))
		out.Write(deflated)
		out.Write(data[codeEnd:])
		return os.WriteFile(path, out.Bytes(), 0o644)
	}

	return errors.New("Scene_Base script not found in Scripts.rvdata2")
}

// injectSceneBase prepends the payload and inserts injectLine right after the
// first `def update`, matching the original injector's behaviour (CRLF output).
func injectSceneBase(source, payload, injectLine string) (string, error) {
	lines := strings.Split(strings.ReplaceAll(source, "\r\n", "\n"), "\n")
	injectPoint := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == "def update" {
			injectPoint = i
			break
		}
	}
	if injectPoint < 0 {
		return "", errors.New("failed to find 'def update' in Scene_Base")
	}

	var b strings.Builder
	b.WriteString(payload)
	b.WriteString(strings.Join(lines[:injectPoint+1], "\r\n"))
	b.WriteString("\r\n")
	b.WriteString(injectLine)
	b.WriteString("\r\n")
	b.WriteString(strings.Join(lines[injectPoint+1:], "\r\n"))
	return b.String(), nil
}

func zlibInflate(in []byte) ([]byte, error) {
	r, err := zlib.NewReader(bytes.NewReader(in))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}

func zlibDeflate(in []byte) ([]byte, error) {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	if _, err := w.Write(in); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
