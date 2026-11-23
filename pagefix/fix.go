//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Files are mapped, not read, so even a 100+ MB library costs page cache rather than
// heap: the NAS has 1 GB of RAM. Still, nothing bigger than this is touched.
const maxFileSize = 512 << 20

// Temporary files are named .pagefix-<name>-<random> next to the file they replace.
const tmpPrefix = ".pagefix-"

type outcome int

const (
	notELF outcome = iota
	loads          // loads as it is
	fixed          // rewritten (or would be, in a dry run)
	failed         // can't be loaded and wasn't rewritten
)

// ioError marks a failure that may not happen again (disk full, I/O error, ...), as
// opposed to a file pagefix can't handle: the file is tried again at the next start.
type ioError struct{ error }

func (e ioError) Unwrap() error { return e.error }

func isIOError(err error) bool { var e ioError; return errors.As(err, &e) }

func mapFile(f *os.File, size int64) ([]byte, error) {
	if size == 0 {
		return nil, nil
	}
	return syscall.Mmap(int(f.Fd()), 0, int(size), syscall.PROT_READ, syscall.MAP_SHARED)
}

// fixFile rewrites path if it is an ELF32 file that can't be loaded with this page size.
// The reason ("misaligned", ...) is returned with fixed and failed. A dry run only plans
// the rewrite and writes nothing.
func fixFile(path string, page uint32, dry bool) (o outcome, why string, err error) {
	defer func() {
		if r := recover(); r != nil { // a bug or a fault on a mapped page: skip this file
			o, err = failed, ioError{fmt.Errorf("internal error: %v", r)}
		}
	}()
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return notELF, "", nil // gone, or not a regular file any more
	}
	defer f.Close()
	head := make([]byte, ehdrSize)
	if n, _ := f.ReadAt(head, 0); n < ehdrSize || !isELF32(head) {
		return notELF, "", nil
	}
	st, err := f.Stat()
	if err != nil {
		return failed, "", ioError{err}
	}
	if !st.Mode().IsRegular() {
		return notELF, "", nil
	}
	if st.Size() > maxFileSize {
		return failed, "", fmt.Errorf("larger than %d MB", maxFileSize>>20)
	}
	d, err := mapFile(f, st.Size())
	if err != nil {
		return failed, "", ioError{err}
	}
	defer syscall.Munmap(d)
	e, err := parse(d)
	if err != nil {
		return failed, "", err
	}
	why = problem(e, page)
	if why == "" {
		return loads, "", nil
	}
	lay, err := plan(e, page)
	if err != nil {
		return failed, why, err
	}
	if dry {
		return fixed, why, nil
	}

	dir, name := filepath.Split(path)
	tmp, err := os.CreateTemp(dir, tmpPrefix+name+"-")
	if err != nil {
		return failed, why, ioError{err}
	}
	tmpName := tmp.Name()
	defer func() {
		tmp.Close()
		os.Remove(tmpName) // gone already after the rename
	}()
	if err := lay.write(tmp); err != nil {
		return failed, why, ioError{err}
	}
	nd, err := mapFile(tmp, int64(lay.size))
	if err != nil {
		return failed, why, ioError{err}
	}
	defer syscall.Munmap(nd)
	nu, err := parse(nd)
	if err == nil {
		err = verify(e, nu, page)
	}
	if err != nil {
		return failed, why, fmt.Errorf("check of the rewrite failed: %v", err)
	}
	if err := replace(path, st, tmp); err != nil {
		return failed, why, ioError{err}
	}
	return fixed, why, nil
}

// replace renames the new content over path (so it is never half written), with path's
// owner, mode, extended attributes and times. Other hard links to the old file keep the
// old content: fixTree points them at the new file (relink).
func replace(path string, st fs.FileInfo, tmp *os.File) error {
	sys := st.Sys().(*syscall.Stat_t)
	xattrs := getXattrs(path)
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := os.Lchown(tmp.Name(), int(sys.Uid), int(sys.Gid)); err != nil {
		return err
	}
	// after chown, which drops set-id bits
	if err := os.Chmod(tmp.Name(), st.Mode()&(fs.ModePerm|fs.ModeSetuid|fs.ModeSetgid|fs.ModeSticky)); err != nil {
		return err
	}
	for k, v := range xattrs {
		syscall.Setxattr(tmp.Name(), k, v, 0) // best effort: the NAS volume refuses security.*
	}
	if err := syscall.UtimesNano(tmp.Name(), []syscall.Timespec{sys.Atim, sys.Mtim}); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// relink makes path another name of the file at target, atomically.
func relink(path, target string) error {
	tmp := filepath.Join(filepath.Dir(path), fmt.Sprintf("%slink-%d", tmpPrefix, time.Now().UnixNano()))
	if err := os.Link(target, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func getXattrs(path string) map[string][]byte {
	out := map[string][]byte{}
	sz, err := syscall.Listxattr(path, nil)
	if err != nil || sz <= 0 {
		return out
	}
	buf := make([]byte, sz)
	if sz, err = syscall.Listxattr(path, buf); err != nil {
		return out
	}
	for _, name := range bytes.Split(bytes.TrimRight(buf[:sz], "\x00"), []byte{0}) {
		n := string(name)
		if vs, err := syscall.Getxattr(path, n, nil); err == nil && vs >= 0 {
			v := make([]byte, vs)
			if vs, err = syscall.Getxattr(path, n, v); err == nil {
				out[n] = v[:vs]
			}
		}
	}
	return out
}

type report struct {
	elves, fixed, failed int
	transient            int // failures to try again (disk full, I/O errors)
	// called for each file fixed or not fixable (nil: no listing)
	each func(path, why string, o outcome, err error)
}

// fixTree fixes every ELF file under root. It doesn't follow symbolic links or go into
// other file systems. With a non-zero since, only files changed (mtime or ctime) at or
// after it are looked at. Leftovers of an interrupted run are removed.
func fixTree(root string, page uint32, dry bool, since time.Time, r *report) error {
	rootInfo, err := os.Lstat(root)
	if err != nil {
		return err
	}
	rootDev := rootInfo.Sys().(*syscall.Stat_t).Dev
	done := map[[2]uint64]string{} // file (device, inode) -> its fixed path, "" if not rewritten
	return filepath.WalkDir(root, func(p string, de fs.DirEntry, err error) error {
		if err != nil {
			if p == root {
				return err
			}
			return nil // unreadable entry: skip it
		}
		if de.IsDir() {
			if info, err := de.Info(); err != nil || info.Sys().(*syscall.Stat_t).Dev != rootDev {
				return filepath.SkipDir
			}
			return nil
		}
		if !de.Type().IsRegular() {
			return nil
		}
		if strings.HasPrefix(de.Name(), tmpPrefix) {
			if !dry {
				os.Remove(p) // left by a run that was stopped
			}
			return nil
		}
		info, err := de.Info()
		if err != nil || info.Size() < ehdrSize {
			return nil
		}
		st := info.Sys().(*syscall.Stat_t)
		if !since.IsZero() {
			mt := time.Unix(int64(st.Mtim.Sec), int64(st.Mtim.Nsec))
			ct := time.Unix(int64(st.Ctim.Sec), int64(st.Ctim.Nsec))
			if mt.Before(since) && ct.Before(since) {
				return nil
			}
		}
		key := [2]uint64{uint64(st.Dev), uint64(st.Ino)}
		if target, ok := done[key]; ok { // another name of a file already looked at
			if target != "" && !dry {
				if err := relink(p, target); err != nil {
					r.failed++
					r.transient++
				}
			}
			return nil
		}
		o, why, err := fixFile(p, page, dry)
		done[key] = ""
		switch o {
		case notELF:
			return nil
		case fixed:
			r.fixed++
			if st.Nlink > 1 {
				done[key] = p
			}
		case failed:
			r.failed++
			if isIOError(err) {
				r.transient++
			}
		}
		r.elves++
		if r.each != nil && (o == fixed || o == failed) {
			r.each(p, why, o, err)
		}
		return nil
	})
}
