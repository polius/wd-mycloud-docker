//go:build linux

// pagefix makes programs built for 4 KB memory pages load on kernels with bigger pages,
// such as the WD My Cloud EX2 Ultra's (32 KB). See elf.go for how, and runc.go for how
// the ARM app runs it on every container start.
//
// One program, three names:
//
//	runc (engine/runc in the ARM app)  the runc wrapper (runc.go)
//	pagefix-runc-fix BUNDLE            the wrapper's fixing child (runc.go)
//	pagefix [-n] [-v] [-page N] PATH...  fix (or with -n, check) the files under PATH
//
// dockerctl.sh --pagefix-check <container> runs the last one as  pagefix -n -v.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"
)

func main() {
	switch filepath.Base(os.Args[0]) {
	case "pagefix":
		debug.SetPanicOnFault(true)
		os.Exit(toolMain(os.Args[1:]))
	case childName:
		if len(os.Args) == 2 {
			childMain(os.Args[1])
		}
	default:
		runcMain()
	}
}

func toolMain(args []string) int {
	fl := flag.NewFlagSet("pagefix", flag.ContinueOnError)
	pageFlag := fl.Int("page", 0, "page size to fix for (default: this system's)")
	dry := fl.Bool("n", false, "check only: list what would be fixed, change nothing")
	verbose := fl.Bool("v", false, "list every file fixed or not fixable")
	fl.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: pagefix [-n] [-v] [-page N] PATH...\n")
		fl.PrintDefaults()
	}
	if fl.Parse(args) != nil || fl.NArg() == 0 {
		fl.Usage()
		return 2
	}
	page := uint32(*pageFlag)
	if page == 0 {
		page = pageSize()
	}
	if page&(page-1) != 0 || page < 4096 || page > align64K {
		fmt.Fprintf(os.Stderr, "pagefix: bad page size %d\n", page)
		return 2
	}
	status := 0
	for _, root := range fl.Args() {
		r := &report{}
		if *verbose {
			r.each = func(p, why string, o outcome, err error) {
				rel := strings.TrimPrefix(p, strings.TrimSuffix(root, "/"))
				if rel == "" {
					rel = p
				}
				if why != "" {
					why = " (" + why + ")"
				}
				switch {
				case o == fixed && *dry:
					fmt.Printf("would fix   %s%s\n", rel, why)
				case o == fixed:
					fmt.Printf("fixed       %s%s\n", rel, why)
				default:
					fmt.Printf("can't fix   %s%s: %v\n", rel, why, err)
				}
			}
		}
		start := time.Now()
		if err := fixTree(root, page, *dry, time.Time{}, r); err != nil {
			fmt.Fprintf(os.Stderr, "pagefix: %v\n", err)
			status = 1
			continue
		}
		verb := "fixed"
		if *dry {
			verb = "would fix"
		}
		fmt.Printf("%s: page size %d: %d ELF files, %s %d, can't fix %d (%.1fs)\n",
			root, page, r.elves, verb, r.fixed, r.failed, time.Since(start).Seconds())
		if r.failed > 0 || (*dry && r.fixed > 0) {
			status = 1
		}
	}
	return status
}
