//go:build linux

package main

// ELF32 re-layout for kernels with memory pages larger than 4 KB.
//
// A program built for 4 KB pages can't be loaded when the page size is bigger:
//   - "misaligned": a PT_LOAD whose file offset and address differ modulo the page size
//     can't be mmap'ed (glibc: "ELF load command address/offset not page-aligned"; the
//     kernel kills an interpreter it can't map with SIGSEGV);
//   - "shared-page": two PT_LOADs in one large page: the second mapping replaces the first
//     there, so e.g. the end of the code loses its execute permission.
//
// The fix changes no address, so no code or relocation changes: the file is laid out so
// that file offset == address - base for every loadable byte (any page size up to 64 KB
// then maps it), and the loaded range is cut into page-sized runs whose permissions are
// the union of what shared each page. PT_GNU_RELRO is dropped: its mprotect could take
// execute away from a page shared with code.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sort"
)

const (
	ptLoad  = 1
	ptPhdr  = 6
	ptRelro = 0x6474e552
	pfX     = 1
	pfW     = 2
	pfR     = 4

	shtNobits = 8
	shfAlloc  = 2

	align64K = 0x10000
	ehdrSize = 52
)

var le = binary.LittleEndian

var errNotELF = errors.New("not an ELF32 little-endian executable or shared object")

type phdr struct{ Type, Off, Vaddr, Paddr, Filesz, Memsz, Flags, Align uint32 }
type shdr struct{ Name, Type, Flags, Addr, Off, Size, Link, Info, Addralign, Entsize uint32 }

type elf32 struct {
	data         []byte
	phoff, shoff uint32
	phnum, shnum int
	ph           []phdr
	sh           []shdr
}

// isELF32 says whether the first bytes of a file are those of a file parse handles.
func isELF32(h []byte) bool {
	if len(h) < ehdrSize || !bytes.Equal(h[:4], []byte("\x7fELF")) || h[4] != 1 || h[5] != 1 {
		return false
	}
	t := le.Uint16(h[16:])
	return t == 2 || t == 3 // executables and shared objects
}

func parse(d []byte) (*elf32, error) {
	if !isELF32(d) {
		return nil, errNotELF
	}
	e := &elf32{data: d, phoff: le.Uint32(d[28:]), shoff: le.Uint32(d[32:]),
		phnum: int(le.Uint16(d[44:])), shnum: int(le.Uint16(d[48:]))}
	if le.Uint16(d[42:]) != 32 || (e.shnum > 0 && le.Uint16(d[46:]) != 40) {
		return nil, errors.New("unexpected header entry size")
	}
	if uint64(e.phoff)+uint64(e.phnum)*32 > uint64(len(d)) {
		return nil, errors.New("program headers out of range")
	}
	for i := 0; i < e.phnum; i++ {
		b := d[int(e.phoff)+i*32:]
		e.ph = append(e.ph, phdr{le.Uint32(b), le.Uint32(b[4:]), le.Uint32(b[8:]), le.Uint32(b[12:]),
			le.Uint32(b[16:]), le.Uint32(b[20:]), le.Uint32(b[24:]), le.Uint32(b[28:])})
	}
	if e.shoff != 0 {
		if e.shnum == 0 {
			return nil, errors.New("extended section numbering")
		}
		if uint64(e.shoff)+uint64(e.shnum)*40 > uint64(len(d)) {
			return nil, errors.New("section headers out of range")
		}
		for i := 0; i < e.shnum; i++ {
			b := d[int(e.shoff)+i*40:]
			s := shdr{le.Uint32(b), le.Uint32(b[4:]), le.Uint32(b[8:]), le.Uint32(b[12:]), le.Uint32(b[16:]),
				le.Uint32(b[20:]), le.Uint32(b[24:]), le.Uint32(b[28:]), le.Uint32(b[32:]), le.Uint32(b[36:])}
			if s.Type != shtNobits && uint64(s.Off)+uint64(s.Size) > uint64(len(d)) {
				return nil, fmt.Errorf("section %d out of range", i)
			}
			e.sh = append(e.sh, s)
		}
	}
	for _, p := range e.ph {
		if p.Filesz > 0 && uint64(p.Off)+uint64(p.Filesz) > uint64(len(d)) {
			return nil, errors.New("segment out of range")
		}
	}
	return e, nil
}

func (e *elf32) loads() []phdr {
	var l []phdr
	for _, p := range e.ph {
		if p.Type == ptLoad {
			l = append(l, p)
		}
	}
	sort.SliceStable(l, func(i, j int) bool { return l[i].Vaddr < l[j].Vaddr })
	return l
}

// problem says why the file can't be loaded with this page size ("" = it loads).
func problem(e *elf32, page uint32) string {
	l := e.loads()
	for _, p := range l {
		if (p.Vaddr-p.Off)%page != 0 {
			return "misaligned"
		}
	}
	for i := 1; i < len(l); i++ {
		a, b := l[i-1], l[i]
		if a.Memsz > 0 && (a.Vaddr+a.Memsz-1)/page >= b.Vaddr/page {
			return "shared-page"
		}
	}
	for _, p := range l {
		if p.Align%page != 0 { // glibc < 2.35 refuses p_align below the page size
			return "small-align"
		}
	}
	return ""
}

// layout is the rewritten file: the flat image of the loaded range, then the
// non-allocated sections, then the section headers.
type layout struct {
	e      *elf32
	base   uint32
	imgLen uint32 // bytes of flat image at the start of the file
	ph     []phdr // new program header table (same number of entries)
	sh     []shdr // new section headers
	shoff  uint32
	size   uint32 // total file size
}

func plan(e *elf32, page uint32) (*layout, error) {
	l := e.loads()
	if len(l) == 0 {
		return nil, errors.New("no PT_LOAD")
	}
	if l[0].Off != 0 {
		return nil, errors.New("first PT_LOAD not at file offset 0")
	}
	base := l[0].Vaddr
	T := uint32(align64K) // output alignment: also right for 64 KB kernels when possible
	if base%T != 0 {
		T = page
	}
	if base%T != 0 {
		return nil, fmt.Errorf("base address %#x not page-aligned", base)
	}
	var memEnd, fileEnd uint32
	for i, p := range l {
		if p.Filesz > p.Memsz {
			return nil, errors.New("PT_LOAD file size above memory size")
		}
		if i > 0 && p.Vaddr < l[i-1].Vaddr+l[i-1].Memsz {
			return nil, errors.New("overlapping PT_LOADs")
		}
		if uint64(p.Vaddr)+uint64(p.Memsz) > 1<<32-align64K {
			return nil, errors.New("PT_LOAD at the top of the address space")
		}
		memEnd = max(memEnd, p.Vaddr+p.Memsz)
		fileEnd = max(fileEnd, p.Vaddr+p.Filesz)
	}
	if memEnd-base > 1<<30 {
		return nil, errors.New("loaded range above 1 GB")
	}
	if e.phoff < ehdrSize || uint64(e.phoff)+uint64(e.phnum)*32 > uint64(l[0].Filesz) || e.phoff > 1<<20 {
		return nil, errors.New("program headers not right after the ELF header")
	}
	// Data after everything the headers describe (self-extracting archives, appended
	// payloads) may be found by absolute offset: leave such files alone.
	known := e.phoff + uint32(e.phnum)*32
	for _, p := range e.ph {
		if p.Filesz > 0 {
			known = max(known, p.Off+p.Filesz)
		}
	}
	for _, s := range e.sh {
		if s.Type != shtNobits {
			known = max(known, s.Off+s.Size)
		}
	}
	if e.shoff != 0 {
		known = max(known, e.shoff+uint32(e.shnum)*40)
	}
	if known < uint32(len(e.data)) && bytes.IndexFunc(e.data[known:], func(r rune) bool { return r != 0 }) >= 0 {
		return nil, fmt.Errorf("%d bytes of trailing data", uint32(len(e.data))-known)
	}

	// Union of permissions per T-sized page, then runs of pages with equal permissions.
	pages := map[uint32]uint32{}
	for _, p := range l {
		if p.Memsz == 0 {
			continue
		}
		for pg := p.Vaddr / T; pg <= (p.Vaddr+p.Memsz-1)/T; pg++ {
			pages[pg] |= p.Flags & (pfR | pfW | pfX)
		}
	}
	idx := make([]uint32, 0, len(pages))
	for pg := range pages {
		idx = append(idx, pg)
	}
	sort.Slice(idx, func(i, j int) bool { return idx[i] < idx[j] })
	type run struct{ start, end, flags uint32 }
	var runs []run
	for _, pg := range idx {
		if n := len(runs); n > 0 && runs[n-1].end == pg*T && runs[n-1].flags == pages[pg] {
			runs[n-1].end = (pg + 1) * T
			continue
		}
		runs = append(runs, run{pg * T, (pg + 1) * T, pages[pg]})
	}
	runs[len(runs)-1].end = memEnd

	// The new PT_LOADs go in the slots of the old PT_LOAD and PT_GNU_RELRO entries.
	var slots []int
	for i, p := range e.ph {
		if p.Type == ptLoad || p.Type == ptRelro {
			slots = append(slots, i)
		}
	}
	for len(runs) > len(slots) { // not enough entries: merge the last two runs
		n := len(runs)
		runs[n-2] = run{runs[n-2].start, runs[n-1].end, runs[n-2].flags | runs[n-1].flags}
		runs = runs[:n-1]
	}

	lay := &layout{e: e, base: base}
	lay.ph = append([]phdr(nil), e.ph...)
	for i, p := range lay.ph {
		switch {
		case p.Type == ptLoad || p.Type == ptRelro:
			lay.ph[i] = phdr{} // PT_NULL unless a run takes the slot
		case p.Type == ptPhdr:
			lay.ph[i].Off = e.phoff
		}
	}
	for k, r := range runs {
		// Only the last run keeps a bss part (memsz > filesz): the loaders zero-fill it,
		// which needs a writable run and a non-empty file part (musl maps it unconditionally).
		fs := r.end - r.start
		if k == len(runs)-1 && r.flags&pfW != 0 {
			if fileEnd > r.start {
				fs = min(fileEnd-r.start, fs)
			} else {
				fs = min(T, fs)
			}
		}
		lay.ph[slots[k]] = phdr{ptLoad, r.start - base, r.start, r.start - l[0].Vaddr + l[0].Paddr, fs, r.end - r.start, r.flags, T}
		lay.imgLen = max(lay.imgLen, r.start-base+fs)
	}
	for i, p := range e.ph {
		if p.Type == ptLoad || p.Type == ptRelro || p.Type == ptPhdr || p.Filesz == 0 {
			continue
		}
		if p.Vaddr < base || p.Vaddr-base+p.Filesz > lay.imgLen {
			return nil, fmt.Errorf("segment type %#x outside the loaded range", p.Type)
		}
		lay.ph[i].Off = p.Vaddr - base
	}

	off := uint64(lay.imgLen)
	alignUp := func(a uint32) {
		if a > 1 {
			off = (off + uint64(a) - 1) / uint64(a) * uint64(a)
		}
	}
	lay.sh = append([]shdr(nil), e.sh...)
	for i, s := range lay.sh {
		switch {
		case i == 0:
		case s.Flags&shfAlloc != 0:
			if s.Type != shtNobits && s.Size > 0 && (s.Addr < base || s.Addr-base+s.Size > lay.imgLen) {
				return nil, fmt.Errorf("allocated section %d outside the loaded range", i)
			}
			if s.Addr >= base {
				lay.sh[i].Off = s.Addr - base
			}
		case s.Type != shtNobits:
			if s.Addralign > align64K || s.Addralign&(s.Addralign-1) != 0 {
				return nil, fmt.Errorf("section %d alignment %#x", i, s.Addralign)
			}
			alignUp(s.Addralign)
			lay.sh[i].Off = uint32(off)
			off += uint64(s.Size)
		}
	}
	if len(lay.sh) > 0 {
		alignUp(4)
		lay.shoff = uint32(off)
		off += uint64(len(lay.sh)) * 40
	}
	// Normally a little larger than the original. Much larger means big holes between
	// segments, written out as zeros: not worth it, and not what a real program looks like.
	if off > 2*uint64(len(e.data))+1<<20 {
		return nil, fmt.Errorf("the rewrite would be %d MB", off>>20)
	}
	lay.size = uint32(off)
	return lay, nil
}

// write streams the new file to w (which must start empty).
func (lay *layout) write(w io.Writer) error {
	e := lay.e
	bw := &countWriter{w: w}
	zeros := func(n uint32) {
		var z [4096]byte
		for n > 0 && bw.err == nil {
			k := min(n, uint32(len(z)))
			bw.Write(z[:k])
			n -= k
		}
	}
	// header + program headers are patched in a copy of the first bytes
	head := append([]byte(nil), e.data[:e.phoff+uint32(e.phnum)*32]...)
	le.PutUint32(head[32:], lay.shoff)
	for i, p := range lay.ph {
		b := head[int(e.phoff)+i*32:]
		for k, v := range []uint32{p.Type, p.Off, p.Vaddr, p.Paddr, p.Filesz, p.Memsz, p.Flags, p.Align} {
			le.PutUint32(b[k*4:], v)
		}
	}
	// flat image: every old PT_LOAD's file bytes at address - base, zeros between
	for _, p := range e.loads() {
		if p.Filesz == 0 {
			continue // nothing in the file (its offset may be anything)
		}
		at := p.Vaddr - lay.base
		if at >= lay.imgLen {
			break
		}
		zeros(at - min(at, uint32(bw.n)))
		n := min(p.Filesz, lay.imgLen-at)
		chunk := e.data[p.Off : p.Off+n]
		if at < uint32(len(head)) { // the header lives in the first segment
			k := min(uint32(len(head))-at, n)
			bw.Write(head[at : at+k])
			chunk = chunk[k:]
		}
		bw.Write(chunk)
	}
	zeros(lay.imgLen - min(lay.imgLen, uint32(bw.n)))
	for i, s := range lay.sh {
		if i == 0 || s.Flags&shfAlloc != 0 || s.Type == shtNobits {
			continue
		}
		zeros(s.Off - uint32(bw.n))
		old := e.sh[i]
		bw.Write(e.data[old.Off : old.Off+old.Size])
	}
	if len(lay.sh) > 0 {
		zeros(lay.shoff - uint32(bw.n))
		b := make([]byte, 40)
		for _, s := range lay.sh {
			for k, v := range []uint32{s.Name, s.Type, s.Flags, s.Addr, s.Off, s.Size, s.Link, s.Info, s.Addralign, s.Entsize} {
				le.PutUint32(b[k*4:], v)
			}
			bw.Write(b)
		}
	}
	if bw.err == nil && bw.n != uint64(lay.size) {
		return fmt.Errorf("wrote %d bytes, planned %d", bw.n, lay.size)
	}
	return bw.err
}

type countWriter struct {
	w   io.Writer
	n   uint64
	err error
}

func (c *countWriter) Write(b []byte) (int, error) {
	if c.err != nil {
		return 0, c.err
	}
	n, err := c.w.Write(b)
	c.n += uint64(n)
	c.err = err
	return n, err
}

// verify simulates loading both files: every byte of every old segment must read the
// same, with at least the old permissions; segments read by file offset (interpreter
// path, dynamic section, TLS, unwind index) and sections must be unchanged; and the new
// file must load with this page size (and with 64 KB pages when its base allows it).
func verify(old, nu *elf32, page uint32) error {
	if p := problem(nu, page); p != "" {
		return fmt.Errorf("still %s", p)
	}
	if nu.loads()[0].Vaddr%align64K == 0 {
		if p := problem(nu, align64K); p != "" {
			return fmt.Errorf("still %s with 64 KB pages", p)
		}
	}
	if len(old.ph) != len(nu.ph) || len(old.sh) != len(nu.sh) {
		return errors.New("header count changed")
	}
	base := old.loads()[0].Vaddr
	// the ELF header and program header table are rewritten on purpose
	skip := [][2]uint32{{base, base + ehdrSize}, {base + old.phoff, base + old.phoff + uint32(old.phnum)*32}}
	nl := nu.loads()
	const chunk = 1 << 20
	for _, p := range old.loads() {
		for v := p.Vaddr; v < p.Vaddr+p.Memsz; {
			var q *phdr
			for i := range nl {
				if v >= nl[i].Vaddr && v < nl[i].Vaddr+nl[i].Memsz {
					q = &nl[i]
					break
				}
			}
			if q == nil {
				return fmt.Errorf("address %#x not loaded", v)
			}
			if q.Flags&p.Flags != p.Flags&(pfR|pfW|pfX) {
				return fmt.Errorf("address %#x lost permissions", v)
			}
			end := min(p.Vaddr+p.Memsz, q.Vaddr+q.Memsz, v+chunk)
			a, c := mem(old.data, p, v, end), mem(nu.data, *q, v, end)
			for _, s := range skip {
				for o := max(s[0], v); o < min(s[1], end); o++ {
					a[o-v], c[o-v] = 0, 0
				}
			}
			if !bytes.Equal(a, c) {
				return fmt.Errorf("memory at %#x..%#x differs", v, end)
			}
			v = end
		}
	}
	for i, p := range old.ph {
		q := nu.ph[i]
		if p.Type == ptLoad || p.Type == ptRelro || p.Type == ptPhdr || p.Filesz == 0 {
			continue
		}
		if q.Type != p.Type || q.Filesz != p.Filesz || q.Vaddr != p.Vaddr ||
			!bytes.Equal(old.data[p.Off:p.Off+p.Filesz], nu.data[q.Off:q.Off+q.Filesz]) {
			return fmt.Errorf("segment %d (type %#x) differs", i, p.Type)
		}
	}
	for i, s := range old.sh {
		t := nu.sh[i]
		if t.Name != s.Name || t.Type != s.Type || t.Addr != s.Addr || t.Size != s.Size {
			return fmt.Errorf("section header %d differs", i)
		}
		if s.Type == shtNobits || s.Size == 0 {
			continue
		}
		if !bytes.Equal(old.data[s.Off:s.Off+s.Size], nu.data[t.Off:t.Off+t.Size]) {
			return fmt.Errorf("section %d content differs", i)
		}
	}
	return nil
}

// mem returns what a loader puts at [from,to) for segment p: file bytes, then zeros.
func mem(d []byte, p phdr, from, to uint32) []byte {
	b := make([]byte, to-from)
	if from < p.Vaddr+p.Filesz {
		copy(b, d[p.Off+from-p.Vaddr:p.Off+min(to, p.Vaddr+p.Filesz)-p.Vaddr])
	}
	return b
}
