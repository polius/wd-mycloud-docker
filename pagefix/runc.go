//go:build linux

package main

// The runc wrapper. On the ARM app, engine/runc is this program and Docker's runc is
// engine/runc.real. containerd runs "runc" for everything a container does; this hands
// every call straight to runc.real, except that before "create" and "run" it fixes the
// container's files (Docker gives every container its own copy with the vfs storage
// driver, so images are never touched). It writes nothing to stdout, stderr or any log,
// and nothing it does can keep a container from starting: the fixing runs in a child
// process with no output and a time limit, and whatever happens to it (an error, a
// crash, running out of memory), runc.real runs next.
//
// Fixing is on when the page size is above 4 KB, unless PAGEFIX=0 is in the environment
// (dockerctl.sh passes PAGEFIX from dockerctl.conf to dockerd, whose children inherit it)
// or in the container's own environment (docker run -e PAGEFIX=0).

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Bump when fixing changes, so containers fixed by an older version are scanned again.
const stampVersion = "pagefix 1"

// The longest a container start waits for fixing. When it runs out, the container starts
// anyway; files fixed so far stay fixed, and the next start carries on.
const fixTimeout = 10 * time.Minute

// argv[0] of the child process that does the fixing (see main.go)
const childName = "pagefix-runc-fix"

func runcMain() {
	real := "runc.real"
	if exe, err := os.Executable(); err == nil {
		real = filepath.Join(filepath.Dir(exe), "runc.real")
	}
	func() {
		defer func() { recover() }() // never in the way of the container
		if os.Getenv("PAGEFIX") == "0" || pageSize() <= 4096 {
			return
		}
		bundle, ok := bundleArg(os.Args[1:])
		if !ok {
			return
		}
		exe, err := os.Executable()
		if err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), fixTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, exe, bundle)
		cmd.Args[0] = childName // stdin, stdout and stderr: /dev/null; no other files
		cmd.Run()
	}()
	err := syscall.Exec(real, append([]string{os.Args[0]}, os.Args[1:]...), os.Environ())
	os.Stderr.WriteString("runc: cannot run " + real + ": " + err.Error() + "\n")
	os.Exit(127)
}

// childMain is the fixing child: runcMain waits for it, then runs runc.real.
func childMain(bundle string) {
	debug.SetPanicOnFault(true) // a fault on a mapped file: a panic fixFile recovers
	defer func() { recover() }()
	fixBundle(bundle, pageSize())
}

// pageSize is the kernel's page size; PAGEFIX_PAGE_SIZE overrides it (for tests).
func pageSize() uint32 {
	if v, err := strconv.ParseUint(os.Getenv("PAGEFIX_PAGE_SIZE"), 10, 32); err == nil && v >= 4096 && v <= align64K && v&(v-1) == 0 {
		return uint32(v)
	}
	return uint32(os.Getpagesize())
}

// runc's global options that take a value (runc [global options] command [options] id).
var runcValueFlags = map[string]bool{"--root": true, "--log": true, "--log-format": true, "--criu": true, "--rootless": true}

// bundleArg returns the bundle folder of a "runc create" or "runc run" command line.
func bundleArg(args []string) (string, bool) {
	i := 0
	for ; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			break
		}
		if runcValueFlags[a] {
			i++ // its value
		}
	}
	if i >= len(args) || (args[i] != "create" && args[i] != "run") {
		return "", false
	}
	bundle := "."
	for j := i + 1; j < len(args); j++ {
		a := args[j]
		switch {
		case a == "--bundle" || a == "-b":
			if j+1 < len(args) {
				bundle = args[j+1]
			}
			j++
		case strings.HasPrefix(a, "--bundle="):
			bundle = strings.TrimPrefix(a, "--bundle=")
		case strings.HasPrefix(a, "-b="):
			bundle = strings.TrimPrefix(a, "-b=")
		}
	}
	return bundle, true
}

// A container's own folder with the vfs storage driver: <data-root>/vfs/dir/<64 hex>.
var vfsDirName = regexp.MustCompile(`^[0-9a-f]{64}$`)

// containerRoot returns the root folder named in the bundle's config.json, if it is a
// container's own vfs folder, and whether the container asked for no fixing.
func containerRoot(bundle string) (root string, optOut bool, ok bool) {
	b, err := os.ReadFile(filepath.Join(bundle, "config.json"))
	if err != nil {
		return "", false, false
	}
	var spec struct {
		Root    struct{ Path string }  `json:"root"`
		Process struct{ Env []string } `json:"process"`
	}
	if json.Unmarshal(b, &spec) != nil || spec.Root.Path == "" {
		return "", false, false
	}
	for _, e := range spec.Process.Env {
		if e == "PAGEFIX=0" {
			optOut = true
		}
	}
	root = spec.Root.Path
	if !filepath.IsAbs(root) {
		root = filepath.Join(bundle, root)
	}
	if root, err = filepath.EvalSymlinks(root); err != nil {
		return "", optOut, false
	}
	dir := filepath.Dir(root)
	if !vfsDirName.MatchString(filepath.Base(root)) || filepath.Base(dir) != "dir" || filepath.Base(filepath.Dir(dir)) != "vfs" {
		return "", optOut, false // not a vfs container folder: never touch it
	}
	if fi, err := os.Lstat(root); err != nil || !fi.IsDir() {
		return "", optOut, false
	}
	return root, optOut, true
}

// fixBundle fixes the container's files. A stamp per container folder, in
// <data-root>/pagefix/, remembers when it was last done: after the first full scan,
// a start only looks at files changed since (packages installed in the container).
func fixBundle(bundle string, page uint32) {
	root, optOut, ok := containerRoot(bundle)
	if !ok || optOut {
		return
	}
	dataRoot := filepath.Dir(filepath.Dir(filepath.Dir(root)))
	stamps := filepath.Join(dataRoot, "pagefix")
	stamp := filepath.Join(stamps, filepath.Base(root))
	want := stampVersion + " page " + strconv.Itoa(int(page)) + "\n"

	var since time.Time
	if b, err := os.ReadFile(stamp); err == nil && string(b) == want {
		if fi, err := os.Stat(stamp); err == nil {
			since = fi.ModTime()
		}
	}
	r := &report{}
	if fixTree(root, page, false, since, r) != nil || r.transient > 0 {
		return // no stamp: the next start looks at everything again
	}
	if os.MkdirAll(stamps, 0o700) != nil {
		return
	}
	tmp := stamp + ".tmp"
	if os.WriteFile(tmp, []byte(want), 0o600) == nil {
		os.Rename(tmp, stamp)
	}
	// forget containers that no longer exist
	if ents, err := os.ReadDir(stamps); err == nil {
		vfsDirs := filepath.Dir(root)
		for _, e := range ents {
			n := e.Name()
			if !vfsDirName.MatchString(n) {
				continue
			}
			if _, err := os.Lstat(filepath.Join(vfsDirs, n)); os.IsNotExist(err) {
				os.Remove(filepath.Join(stamps, n))
			}
		}
	}
}
