package main

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"golang.org/x/tools/go/callgraph"
	"golang.org/x/tools/go/callgraph/cha"
	"golang.org/x/tools/go/callgraph/static"
	"golang.org/x/tools/go/callgraph/vta"
	"golang.org/x/tools/go/packages"
	"golang.org/x/tools/go/ssa"
	"golang.org/x/tools/go/ssa/ssautil"
)

func main() {
	root := "/Users/nitin/projects/groundx/ai_graph_context_poc/groundx-rnd/cashbot-go"
	algo := os.Getenv("ALGO"); if algo == "" { algo = "static" }
	withTests := os.Getenv("WITH_TESTS") == "1"
	cfg := &packages.Config{Mode: packages.LoadAllSyntax, Dir: root, Tests: withTests}
	pkgs, err := packages.Load(cfg, "./...")
	if err != nil { panic(err) }
	packages.PrintErrors(pkgs)
	prog, _ := ssautil.AllPackages(pkgs, ssa.InstantiateGenerics)
	prog.Build()

	var cg *callgraph.Graph
	switch algo {
	case "static": cg = static.CallGraph(prog)
	case "cha": cg = cha.CallGraph(prog)
	case "vta": cg = vta.CallGraph(ssautil.AllFunctions(prog), cha.CallGraph(prog))
	}

	// Identify all PrepareStep nodes (diagnostic) and pick the specific (Process).PrepareStep in summarizer.
	var targets []*callgraph.Node
	for fn, node := range cg.Nodes {
		if fn == nil || fn.Name() != "PrepareStep" { continue }
		pos := prog.Fset.Position(fn.Pos())
		sig := fn.String()
		fmt.Fprintf(os.Stderr, "PrepareStep node: %s  @ %s\n", sig, strings.TrimPrefix(pos.Filename, root+"/"))
		if strings.Contains(sig, "summarizer") && strings.Contains(sig, "Process") {
			targets = append(targets, node)
		}
	}
	if len(targets) == 0 { fmt.Fprintln(os.Stderr, "NO specific target matched"); os.Exit(1) }

	seen := map[*callgraph.Node]bool{}
	queue := append([]*callgraph.Node{}, targets...)
	for _, t := range targets { seen[t] = true }
	callers := map[*callgraph.Node]bool{}
	for len(queue) > 0 {
		n := queue[0]; queue = queue[1:]
		for _, in := range n.In {
			if c := in.Caller; !seen[c] { seen[c] = true; callers[c] = true; queue = append(queue, c) }
		}
	}
	files := map[string]bool{}
	prefix := root + "/"
	for n := range callers {
		if n.Func == nil { continue }
		pos := prog.Fset.Position(n.Func.Pos())
		if pos.Filename == "" { continue }
		f := strings.TrimPrefix(pos.Filename, prefix)
		if !strings.HasPrefix(f, "/") { files[f] = true }
	}
	var out []string
	for f := range files { out = append(out, f) }
	sort.Strings(out)
	for _, f := range out { fmt.Println(f) }
	fmt.Fprintf(os.Stderr, "ALGO=%s targets=%d caller-funcs=%d files=%d withTests=%v\n", algo, len(targets), len(callers), len(out), withTests)
}
