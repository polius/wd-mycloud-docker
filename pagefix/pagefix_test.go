//go:build linux

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBundleArg(t *testing.T) {
	for _, c := range []struct {
		args   string
		bundle string
		ok     bool
	}{
		// as containerd-shim-runc-v2 runs it
		{"--root /run/containerd/runc/moby --log /run/x/log.json --log-format json create --bundle /run/b --pid-file /run/p --console-socket /run/s c1", "/run/b", true},
		{"--root /r --systemd-cgroup create -b /x c1", "/x", true},
		{"--root=/r run --bundle=/y c1", "/y", true},
		{"--debug create c1", ".", true},
		{"--root /r state c1", "", false},
		{"--root /r exec --process /p c1", "", false},
		{"--version", "", false},
		{"", "", false},
		// "create" as the value of a global option is not the command
		{"--root create state c1", "", false},
	} {
		b, ok := bundleArg(strings.Fields(c.args))
		if b != c.bundle || ok != c.ok {
			t.Errorf("bundleArg(%q) = %q, %v; want %q, %v", c.args, b, ok, c.bundle, c.ok)
		}
	}
}

func TestContainerRoot(t *testing.T) {
	tmp := t.TempDir()
	id := strings.Repeat("ab", 32)
	vfs := filepath.Join(tmp, "data", "vfs", "dir", id)
	other := filepath.Join(tmp, "elsewhere", id)
	for _, d := range []string{vfs, other} {
		os.MkdirAll(d, 0o755)
	}
	os.Symlink(other, filepath.Join(tmp, "data", "vfs", "dir", strings.Repeat("cd", 32)))
	bundle := func(root string, env ...string) string {
		b := t.TempDir()
		e := `"` + strings.Join(env, `","`) + `"`
		if len(env) == 0 {
			e = ""
		}
		os.WriteFile(filepath.Join(b, "config.json"), []byte(`{"root":{"path":"`+root+`"},"process":{"env":[`+e+`]}}`), 0o644)
		return b
	}
	if r, out, ok := containerRoot(bundle(vfs)); !ok || out || r != vfs {
		t.Errorf("vfs folder: got %q %v %v", r, out, ok)
	}
	if _, out, ok := containerRoot(bundle(vfs, "PATH=/bin", "PAGEFIX=0")); !ok || !out {
		t.Errorf("PAGEFIX=0 in the container: got opt-out %v ok %v", out, ok)
	}
	if _, _, ok := containerRoot(bundle(other)); ok {
		t.Error("a folder outside vfs/dir was accepted")
	}
	if _, _, ok := containerRoot(bundle(filepath.Join(tmp, "data", "vfs", "dir", strings.Repeat("cd", 32)))); ok {
		t.Error("a symlink out of vfs/dir was accepted")
	}
	if _, _, ok := containerRoot(bundle("/")); ok {
		t.Error("/ was accepted")
	}
	if _, _, ok := containerRoot(t.TempDir()); ok {
		t.Error("a bundle without config.json was accepted")
	}
}

// testELF builds a small ELF32 shared object laid out like a 4 KB-page link: code at
// 0..0x1180 (R-X) and data at file 0x1180 / address 0x2180 (RW-, with bss), so the data
// segment is misaligned for 32 KB pages and shares the first page with the code.
func testELF(trailing []byte) []byte {
	const textEnd, dataOff, dataVa, dataSz, bssSz = 0x1180, 0x1180, 0x2180, 0x80, 0x200
	b := make([]byte, dataOff+dataSz)
	copy(b, "\x7fELF\x01\x01\x01")
	le.PutUint16(b[16:], 3)  // ET_DYN
	le.PutUint16(b[18:], 40) // EM_ARM
	le.PutUint32(b[20:], 1)
	le.PutUint32(b[28:], 52) // e_phoff
	le.PutUint16(b[40:], 52)
	le.PutUint16(b[42:], 32)
	le.PutUint16(b[44:], 4) // LOAD, LOAD, DYNAMIC, RELRO
	le.PutUint16(b[46:], 40)
	ph := []phdr{
		{ptLoad, 0, 0, 0, textEnd, textEnd, pfR | pfX, 0x1000},
		{ptLoad, dataOff, dataVa, dataVa, dataSz, dataSz + bssSz, pfR | pfW, 0x1000},
		{2, dataOff, dataVa, dataVa, 0x10, 0x10, pfR | pfW, 4}, // PT_DYNAMIC
		{ptRelro, dataOff, dataVa, dataVa, 0x10, 0x10, pfR, 1},
	}
	for i, p := range ph {
		for k, v := range []uint32{p.Type, p.Off, p.Vaddr, p.Paddr, p.Filesz, p.Memsz, p.Flags, p.Align} {
			le.PutUint32(b[52+i*32+k*4:], v)
		}
	}
	for i := 0x200; i < textEnd; i++ {
		b[i] = byte(i) | 1 // "code"
	}
	for i := dataOff; i < dataOff+dataSz; i++ {
		b[i] = byte(i*7) | 2 // "data"
	}
	// sections: null, .text, .data, .bss, .comment (not loaded), .shstrtab
	strtab := []byte("\x00.text\x00.data\x00.bss\x00.comment\x00.shstrtab\x00")
	comment := []byte("test compiler 1.0\x00")
	commentOff := uint32(len(b))
	b = append(b, comment...)
	strOff := uint32(len(b))
	b = append(b, strtab...)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	shoff := uint32(len(b))
	le.PutUint32(b[32:], shoff)
	le.PutUint16(b[48:], 6)
	le.PutUint16(b[50:], 5)
	for _, s := range []shdr{
		{},
		{1, 1, shfAlloc | 4, 0x200, 0x200, textEnd - 0x200, 0, 0, 4, 0},
		{7, 1, shfAlloc | 1, dataVa, dataOff, dataSz, 0, 0, 4, 0},
		{13, shtNobits, shfAlloc | 1, dataVa + dataSz, dataOff + dataSz, bssSz, 0, 0, 4, 0},
		{18, 1, 0, 0, commentOff, uint32(len(comment)), 0, 0, 1, 1},
		{27, 3, 0, 0, strOff, uint32(len(strtab)), 0, 0, 1, 0},
	} {
		for _, v := range []uint32{s.Name, s.Type, s.Flags, s.Addr, s.Off, s.Size, s.Link, s.Info, s.Addralign, s.Entsize} {
			b = le.AppendUint32(b, v)
		}
	}
	return append(b, trailing...)
}

func rewriteBytes(t *testing.T, d []byte, page uint32) ([]byte, error) {
	t.Helper()
	e, err := parse(d)
	if err != nil {
		t.Fatal(err)
	}
	lay, err := plan(e, page)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := lay.write(&buf); err != nil {
		t.Fatal(err)
	}
	nu, err := parse(buf.Bytes())
	if err != nil {
		t.Fatalf("rewritten file doesn't parse: %v", err)
	}
	if err := verify(e, nu, page); err != nil {
		t.Fatalf("verify: %v", err)
	}
	return buf.Bytes(), nil
}

func TestRewrite(t *testing.T) {
	d := testELF(nil)
	e, _ := parse(d)
	if p := problem(e, 0x8000); p != "misaligned" {
		t.Fatalf("test file: problem = %q, want misaligned", p)
	}
	if p := problem(e, 0x1000); p != "" {
		t.Fatalf("test file should load with 4 KB pages: %q", p)
	}
	out, err := rewriteBytes(t, d, 0x8000)
	if err != nil {
		t.Fatal(err)
	}
	nu, _ := parse(out)
	for _, pg := range []uint32{0x1000, 0x4000, 0x8000, 0x10000} {
		if p := problem(nu, pg); p != "" {
			t.Errorf("rewritten file, page %#x: %s", pg, p)
		}
	}
	for _, p := range nu.ph {
		if p.Type == ptRelro {
			t.Error("PT_GNU_RELRO kept")
		}
	}
	// the one 64 KB page holding code and data must be both executable and writable
	if l := nu.loads(); len(l) != 1 || l[0].Flags != pfR|pfW|pfX {
		t.Errorf("want one RWX PT_LOAD, got %+v", l)
	}
	if again, _ := parse(out); problem(again, 0x8000) != "" {
		t.Error("a second pass would rewrite again")
	}
}

func TestTrailingData(t *testing.T) {
	if _, err := rewriteBytes(t, testELF([]byte("PAYLOAD")), 0x8000); err == nil || !strings.Contains(err.Error(), "trailing") {
		t.Errorf("file with trailing data: err = %v, want a refusal", err)
	}
	if _, err := rewriteBytes(t, testELF(make([]byte, 64)), 0x8000); err != nil {
		t.Errorf("zero padding at the end must be fine: %v", err)
	}
}

func setPhdr(d []byte, i int, p phdr) {
	for k, v := range []uint32{p.Type, p.Off, p.Vaddr, p.Paddr, p.Filesz, p.Memsz, p.Flags, p.Align} {
		le.PutUint32(d[52+i*32+k*4:], v)
	}
}

func TestCraftedInputs(t *testing.T) {
	plans := func(d []byte) (err error) {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("panic: %v", r)
			}
		}()
		e, err := parse(d)
		if err != nil {
			return err
		}
		lay, err := plan(e, 0x8000)
		if err != nil {
			return err
		}
		var buf bytes.Buffer
		if err := lay.write(&buf); err != nil {
			return err
		}
		nu, err := parse(buf.Bytes())
		if err != nil {
			return err
		}
		return verify(e, nu, 0x8000)
	}
	// a huge section alignment would make the output gigabytes of zeros
	d := testELF(nil)
	e, _ := parse(d)
	le.PutUint32(d[e.shoff+4*40+32:], 0x80000000)
	if err := plans(d); err == nil || !strings.Contains(err.Error(), "alignment") {
		t.Errorf("huge section alignment: %v", err)
	}
	// a PT_LOAD with nothing in the file and a wild offset (in place of PT_GNU_RELRO)
	d = testELF(nil)
	setPhdr(d, 3, phdr{ptLoad, 0xffffff00, 0x3000, 0x3000, 0, 0x100, pfR | pfW, 0x1000})
	if err := plans(d); err != nil {
		t.Errorf("zero-size PT_LOAD with a wild offset: %v", err)
	}
	// a 64 MB hole between code and data would be written out as zeros
	d = testELF(nil)
	setPhdr(d, 1, phdr{ptLoad, 0x1180, 0x4000180, 0x4000180, 0x80, 0x280, pfR | pfW, 0x1000})
	setPhdr(d, 2, phdr{2, 0x1180, 0x4000180, 0x4000180, 0x10, 0x10, pfR | pfW, 4})
	setPhdr(d, 3, phdr{ptRelro, 0x1180, 0x4000180, 0x4000180, 0x10, 0x10, pfR, 1})
	e, _ = parse(d)
	for i := 2; i <= 3; i++ { // the sections at the moved address
		le.PutUint32(d[e.shoff+uint32(i)*40+12:], 0x4000180+uint32(i-2)*0x80)
	}
	if err := plans(d); err == nil || !strings.Contains(err.Error(), "MB") {
		t.Errorf("64 MB hole: %v", err)
	}
}

func TestFixTree(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "lib.so")
	os.WriteFile(p, testELF(nil), 0o751)
	os.Link(p, filepath.Join(dir, "lib-link.so"))
	os.WriteFile(filepath.Join(dir, ".pagefix-lib.so-123"), []byte("left by a killed run"), 0o600)
	mt := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	os.Chtimes(p, mt, mt)
	names := func() (n []string) {
		ents, _ := os.ReadDir(dir)
		for _, e := range ents {
			n = append(n, e.Name())
		}
		return n
	}

	r := &report{}
	if err := fixTree(dir, 0x8000, true, time.Time{}, r); err != nil || r.fixed != 1 || r.failed != 0 {
		t.Fatalf("dry run: %v %+v", err, r)
	}
	if b, _ := os.ReadFile(p); !bytes.Equal(b, testELF(nil)) || len(names()) != 3 {
		t.Fatalf("dry run changed something: %v", names())
	}

	r = &report{}
	if err := fixTree(dir, 0x8000, false, time.Time{}, r); err != nil || r.fixed != 1 || r.failed != 0 {
		t.Fatalf("fix: %v %+v", err, r)
	}
	if n := names(); len(n) != 2 {
		t.Errorf("want lib.so and lib-link.so only, got %v", n)
	}
	a, _ := os.Stat(p)
	b, _ := os.Stat(filepath.Join(dir, "lib-link.so"))
	if !os.SameFile(a, b) {
		t.Error("the hard link no longer points at the same file")
	}
	if a.Mode().Perm() != 0o751 || !a.ModTime().Equal(mt) {
		t.Errorf("mode %v mtime %v, want 0751 and %v", a.Mode(), a.ModTime(), mt)
	}
	if d, _ := os.ReadFile(p); d != nil {
		if e, err := parse(d); err != nil || problem(e, 0x8000) != "" {
			t.Error("not fixed")
		}
	}

	r = &report{}
	if fixTree(dir, 0x8000, false, time.Time{}, r); r.fixed != 0 || r.elves != 1 {
		t.Errorf("second pass: %+v, want nothing to fix", r)
	}
	// only files changed since: nothing
	r = &report{}
	if fixTree(dir, 0x8000, false, time.Now().Add(time.Hour), r); r.elves != 0 {
		t.Errorf("since the future: %+v, want nothing looked at", r)
	}
}
