package main

// Reads Claude Code's statusLine JSON from stdin, renders a rich status bar:
//   Line 1: emoji  Name · Model · dir · ctx% · $cost · rate limits
//   Line 2+: one line per PR (#number TICKET-123 title), with 24-bit gradients
//
// Compiles and installs to ~/.claude/statusline via install.sh.
// Falls back to the Python scripts if Go is unavailable.

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ─── ANSI helpers ─────────────────────────────────────────────────────────────

func rgb(r, g, b int) string {
	return fmt.Sprintf("\033[38;2;%d;%d;%dm", r, g, b)
}

const (
	ansiReset = "\033[0m"
	ansiDim   = "\033[2m"
)

func gradient(text string, left, right [3]int) string {
	runes := []rune(text)
	n := len(runes)
	var sb strings.Builder
	for i, ch := range runes {
		t := 0.0
		if n > 1 {
			t = float64(i) / float64(n-1)
		}
		r := left[0] + int(t*float64(right[0]-left[0]))
		g := left[1] + int(t*float64(right[1]-left[1]))
		b := left[2] + int(t*float64(right[2]-left[2]))
		sb.WriteString(rgb(r, g, b))
		sb.WriteRune(ch)
	}
	sb.WriteString(ansiReset)
	return sb.String()
}

func osc8(url, text string) string {
	return fmt.Sprintf("\033]8;;%s\033\\%s\033]8;;\033\\", url, text)
}

// ─── Status colors ────────────────────────────────────────────────────────────

var statusColor = map[string][3]int{
	"passing":           {70, 210, 110},
	"approved":          {70, 210, 110},
	"failing":           {220, 70, 70},
	"changes_requested": {220, 70, 70},
	"pending":           {200, 155, 50},
	"review_required":   {200, 155, 50},
	"merged":            {160, 90, 220},
	"unknown":           {110, 110, 110},
}

func colorFor(status string) [3]int {
	if c, ok := statusColor[status]; ok {
		return c
	}
	return statusColor["unknown"]
}

// ─── Ticket colors ────────────────────────────────────────────────────────────

var ticketPalette = [][3]int{
	{100, 180, 255},
	{180, 130, 255},
	{255, 180, 80},
	{80, 210, 200},
	{255, 130, 160},
	{130, 220, 130},
}

func ticketColor(project string) [3]int {
	h := 0
	for _, c := range project {
		h = h*31 + int(c)
	}
	if h < 0 {
		h = -h
	}
	return ticketPalette[h%len(ticketPalette)]
}

// ─── Config ───────────────────────────────────────────────────────────────────

type ticketPatternCfg struct {
	Pattern     string `json:"pattern"`
	URLTemplate string `json:"url_template"`
}

type Config struct {
	StripPatterns  []string           `json:"strip_patterns"`
	TicketPatterns []ticketPatternCfg `json:"ticket_patterns"`
	StatusTTL      float64            `json:"status_ttl"`
}

func loadConfig() Config {
	cfg := Config{StatusTTL: 120}
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".claude", "statusline-config.json"))
	if err == nil {
		json.Unmarshal(data, &cfg) //nolint
	}
	if cfg.StatusTTL <= 0 {
		cfg.StatusTTL = 120
	}
	return cfg
}

// ─── Compiled patterns ────────────────────────────────────────────────────────

type compiledTicket struct {
	re     *regexp.Regexp
	rawPat string
	urlTpl string
}

func compileTickets(cfg Config) []compiledTicket {
	var out []compiledTicket
	for _, tp := range cfg.TicketPatterns {
		if tp.Pattern == "" {
			continue
		}
		re, err := regexp.Compile(`\b(` + tp.Pattern + `)\b`)
		if err != nil {
			continue
		}
		out = append(out, compiledTicket{re: re, rawPat: tp.Pattern, urlTpl: tp.URLTemplate})
	}
	return out
}

func compileStrip(cfg Config) []*regexp.Regexp {
	var out []*regexp.Regexp
	for _, pat := range cfg.StripPatterns {
		re, err := regexp.Compile(`(?i)` + pat)
		if err != nil {
			continue
		}
		out = append(out, re)
	}
	return out
}

// ─── Title processing ─────────────────────────────────────────────────────────

var multiSpace = regexp.MustCompile(`\s{2,}`)

func applyStrip(text string, res []*regexp.Regexp) string {
	for _, re := range res {
		text = strings.TrimSpace(re.ReplaceAllString(text, ""))
	}
	return text
}

func extractTickets(text string, patterns []compiledTicket) []string {
	seen := map[string]struct{}{}
	var order []string
	for _, cp := range patterns {
		for _, m := range cp.re.FindAllStringSubmatch(text, -1) {
			if _, ok := seen[m[1]]; !ok {
				seen[m[1]] = struct{}{}
				order = append(order, m[1])
			}
		}
	}
	return order
}

func stripTickets(text string, patterns []compiledTicket) string {
	for _, cp := range patterns {
		bracketRE, err := regexp.Compile(`[\(\[]\s*` + cp.rawPat + `\s*[\)\]]`)
		if err == nil {
			text = bracketRE.ReplaceAllString(text, "")
		}
		text = cp.re.ReplaceAllString(text, "")
	}
	text = multiSpace.ReplaceAllString(text, " ")
	return strings.Trim(text, " -–()[]")
}

func ticketURL(tid string, patterns []compiledTicket) string {
	for _, cp := range patterns {
		if cp.re.MatchString(tid) && cp.urlTpl != "" {
			return strings.ReplaceAll(cp.urlTpl, "{ticket}", tid)
		}
	}
	return ""
}

func renderTickets(tickets []string, patterns []compiledTicket) string {
	var parts []string
	for _, tid := range tickets {
		project := tid
		if i := strings.Index(tid, "-"); i > 0 {
			project = tid[:i]
		}
		c := ticketColor(project)
		url := ticketURL(tid, patterns)
		if url != "" {
			parts = append(parts, rgb(c[0], c[1], c[2])+osc8(url, tid)+ansiReset)
		} else {
			parts = append(parts, rgb(c[0], c[1], c[2])+tid+ansiReset)
		}
	}
	return strings.Join(parts, " ")
}

// ─── PR status ────────────────────────────────────────────────────────────────

type PRStatus struct{ CI, Review string }

func parsePRStatus(raw []byte) PRStatus {
	status := PRStatus{CI: "unknown", Review: "unknown"}
	var d struct {
		State         string        `json:"state"`
		ReviewDecision string       `json:"reviewDecision"`
		StatusCheckRollup []struct {
			Typename   string `json:"__typename"`
			State      string `json:"state"`
			Status     string `json:"status"`
			Conclusion string `json:"conclusion"`
			Name       string `json:"name"`
		} `json:"statusCheckRollup"`
	}
	if err := json.Unmarshal(raw, &d); err != nil {
		return status
	}
	if strings.ToUpper(d.State) == "MERGED" {
		return PRStatus{CI: "merged", Review: "merged"}
	}

	states := map[string]bool{}
	for _, c := range d.StatusCheckRollup {
		switch c.Typename {
		case "StatusContext":
			if s := strings.ToUpper(c.State); s != "" {
				states[s] = true
			}
		case "CheckRun":
			if strings.Contains(strings.ToLower(c.Name), "review") {
				continue
			}
			switch strings.ToUpper(c.Status) {
			case "IN_PROGRESS", "QUEUED", "WAITING":
				states["PENDING"] = true
			default:
				if cl := strings.ToUpper(c.Conclusion); cl != "" {
					states[cl] = true
				}
			}
		}
	}

	switch {
	case len(states) == 0:
		status.CI = "unknown"
	case states["FAILURE"] || states["ERROR"] || states["CANCELLED"]:
		status.CI = "failing"
	case states["PENDING"]:
		status.CI = "pending"
	default:
		status.CI = "passing"
	}

	switch strings.ToUpper(d.ReviewDecision) {
	case "APPROVED":
		status.Review = "approved"
	case "CHANGES_REQUESTED":
		status.Review = "changes_requested"
	case "REVIEW_REQUIRED":
		status.Review = "review_required"
	}
	return status
}

func fetchPRStatus(number int, repo string) PRStatus {
	out, err := exec.Command("gh", "pr", "view", strconv.Itoa(number),
		"--repo", repo,
		"--json", "reviewDecision,statusCheckRollup,state").Output()
	if err != nil {
		return PRStatus{CI: "unknown", Review: "unknown"}
	}
	return parsePRStatus(out)
}

// ─── Context file ─────────────────────────────────────────────────────────────

type PREntry struct {
	Number   int     `json:"number"`
	Title    string  `json:"title"`
	URL      string  `json:"url"`
	Repo     string  `json:"repo"`
	CI       string  `json:"ci,omitempty"`
	Review   string  `json:"review,omitempty"`
	StatusAt float64 `json:"status_at,omitempty"`
}

type TicketEntry struct {
	ID    string `json:"id"`
	Title string `json:"title,omitempty"`
}

type SessionCtx struct {
	Name    string       `json:"name,omitempty"`
	Emoji   string       `json:"emoji,omitempty"`
	PRs     []PREntry    `json:"prs,omitempty"`
	Tickets []TicketEntry `json:"tickets,omitempty"`
}

func loadSessionCtx(path string) SessionCtx {
	var ctx SessionCtx
	data, err := os.ReadFile(path)
	if err == nil {
		json.Unmarshal(data, &ctx) //nolint
	}
	return ctx
}

func saveSessionCtx(path string, ctx SessionCtx) {
	data, _ := json.MarshalIndent(ctx, "", "  ")
	os.WriteFile(path, data, 0644) //nolint
}

func restoreFromDurableStore(sessionID string) (name, emoji string) {
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".claude", "session-names.json"))
	if err != nil {
		return
	}
	var db map[string]struct {
		Name  string `json:"name"`
		Emoji string `json:"emoji"`
	}
	if err := json.Unmarshal(data, &db); err != nil {
		return
	}
	if e, ok := db[sessionID]; ok {
		name, emoji = e.Name, e.Emoji
	}
	return
}

// ─── Git / auto-detect PRs ────────────────────────────────────────────────────

func currentBranch(cwd string) string {
	cmd := exec.Command("git", "-c", "core.hooksPath=/dev/null", "rev-parse", "--abbrev-ref", "HEAD")
	if cwd != "" {
		cmd.Dir = cwd
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func openPRsForBranch(branch string) []PREntry {
	out, err := exec.Command("gh", "pr", "list",
		"--head", branch, "--state", "open",
		"--json", "number,title,url,repository", "--limit", "3").Output()
	if err != nil {
		return nil
	}
	var raw []struct {
		Number     int    `json:"number"`
		Title      string `json:"title"`
		URL        string `json:"url"`
		Repository struct {
			NameWithOwner string `json:"nameWithOwner"`
		} `json:"repository"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil
	}
	var prs []PREntry
	for _, r := range raw {
		prs = append(prs, PREntry{Number: r.Number, Title: r.Title, URL: r.URL, Repo: r.Repository.NameWithOwner})
	}
	return prs
}

// ─── Model shorthand ─────────────────────────────────────────────────────────

var nonAlnum = regexp.MustCompile(`[^a-zA-Z0-9]`)

func modelShort(model string) string {
	var parts []string
	for _, w := range strings.Fields(model) {
		clean := nonAlnum.ReplaceAllString(w, "")
		if clean == "" {
			continue
		}
		if (clean[0] >= 'a' && clean[0] <= 'z') || (clean[0] >= 'A' && clean[0] <= 'Z') {
			parts = append(parts, string(clean[0]))
		} else {
			parts = append(parts, clean)
		}
	}
	if len(parts) == 0 {
		return model
	}
	return strings.Join(parts, "")
}

// ─── Claude Code stdin ────────────────────────────────────────────────────────

type ClaudeInput struct {
	Model     struct{ DisplayName string `json:"display_name"` } `json:"model"`
	Workspace struct{ CurrentDir string `json:"current_dir"` }   `json:"workspace"`
	CWD       string  `json:"cwd"`
	SessionID string  `json:"session_id"`
	ContextWindow struct {
		UsedPercentage float64 `json:"used_percentage"`
	} `json:"context_window"`
	RateLimits struct {
		FiveHour struct{ UsedPercentage float64 `json:"used_percentage"` } `json:"five_hour"`
		SevenDay struct{ UsedPercentage float64 `json:"used_percentage"` } `json:"seven_day"`
	} `json:"rate_limits"`
	Cost struct{ TotalCostUSD float64 `json:"total_cost_usd"` } `json:"cost"`
}

// ─── Line 1 helpers ───────────────────────────────────────────────────────────

const (
	cModel  = "\033[38;5;213m"
	cDir    = "\033[38;5;75m"
	cCtxLo  = "\033[38;5;149m"
	cCtxMid = "\033[38;5;215m"
	cCtxHi  = "\033[38;5;203m"
	cCost   = "\033[38;5;215m"
	cRate   = "\033[38;5;203m"
	cSep    = "\033[38;5;240m"
	cName   = "\033[38;5;183m"
	sep     = "\033[38;5;240m · \033[0m"
)

func dirShort(cwd string) string {
	parts := strings.Split(strings.TrimRight(cwd, "/"), "/")
	n := len(parts)
	if n >= 2 {
		return parts[n-2] + "/" + parts[n-1]
	}
	if n == 1 {
		return parts[0]
	}
	return ""
}

func ctxColor(pct float64) string {
	switch {
	case pct >= 80:
		return cCtxHi
	case pct >= 50:
		return cCtxMid
	default:
		return cCtxLo
	}
}

// ─── Main ─────────────────────────────────────────────────────────────────────

func main() {
	inputData, _ := io.ReadAll(os.Stdin)
	var input ClaudeInput
	json.Unmarshal(inputData, &input) //nolint

	sessionID := input.SessionID
	cwd := input.Workspace.CurrentDir
	if cwd == "" {
		cwd = input.CWD
	}

	cfg := loadConfig()
	stripREs := compileStrip(cfg)
	ticketPatterns := compileTickets(cfg)

	// Session context
	ctxPath := fmt.Sprintf("/tmp/claude-custom-context-%s.json", sessionID)
	if sessionID == "" {
		ctxPath = fmt.Sprintf("/tmp/claude-custom-context-%d.json", os.Getppid())
	}
	ctx := loadSessionCtx(ctxPath)

	// Restore name/emoji from durable store if missing
	if ctx.Name == "" || ctx.Emoji == "" {
		name, emoji := restoreFromDurableStore(sessionID)
		if ctx.Name == "" {
			ctx.Name = name
		}
		if ctx.Emoji == "" {
			ctx.Emoji = emoji
		}
		if (ctx.Name != "" || ctx.Emoji != "") && ctxPath != "" {
			saveSessionCtx(ctxPath, ctx)
		}
	}

	// Fallback emoji from session_id hash
	if ctx.Emoji == "" && sessionID != "" {
		h := 0
		for _, c := range sessionID {
			h = h*31 + int(c)
		}
		if h < 0 {
			h = -h
		}
		ctx.Emoji = string(rune(0x1F300 + h%(0x1F9FF-0x1F300+1)))
	}

	// ── Line 1 ───────────────────────────────────────────────────────────────
	var parts []string

	nameStr := ctx.Emoji
	if ctx.Name != "" {
		nameStr += "  " + cName + ctx.Name + ansiReset
	}
	if nameStr != "" {
		parts = append(parts, nameStr)
	}

	if m := modelShort(input.Model.DisplayName); m != "" {
		parts = append(parts, cModel+m+ansiReset)
	}
	if d := dirShort(cwd); d != "" {
		parts = append(parts, cDir+d+ansiReset)
	}
	if pct := input.ContextWindow.UsedPercentage; pct > 0 {
		parts = append(parts, fmt.Sprintf("%s%d%%ctx%s", ctxColor(pct), int(pct+0.5), ansiReset))
	}
	if cost := input.Cost.TotalCostUSD; cost > 0 {
		parts = append(parts, fmt.Sprintf("%s$%.3f%s", cCost, cost, ansiReset))
	}
	var rateParts []string
	if v := input.RateLimits.FiveHour.UsedPercentage; v > 0 {
		rateParts = append(rateParts, fmt.Sprintf("5h:%d%%", int(v+0.5)))
	}
	if v := input.RateLimits.SevenDay.UsedPercentage; v > 0 {
		rateParts = append(rateParts, fmt.Sprintf("7d:%d%%", int(v+0.5)))
	}
	if len(rateParts) > 0 {
		parts = append(parts, cRate+strings.Join(rateParts, " ")+ansiReset)
	}

	fmt.Println(strings.Join(parts, sep))

	// ── PR lines ─────────────────────────────────────────────────────────────
	prs := ctx.PRs
	ctxDirty := false
	isPRsFromCtx := len(prs) > 0

	if !isPRsFromCtx {
		if branch := currentBranch(cwd); branch != "" && branch != "HEAD" {
			prs = openPRsForBranch(branch)
		}
	}

	// Fetch stale statuses in parallel
	now := float64(time.Now().UnixNano()) / 1e9
	var staleIdxs []int
	for i, p := range prs {
		if now-p.StatusAt > cfg.StatusTTL {
			staleIdxs = append(staleIdxs, i)
		}
	}

	if len(staleIdxs) > 0 {
		type result struct {
			idx    int
			status PRStatus
		}
		ch := make(chan result, len(staleIdxs))
		var wg sync.WaitGroup
		for _, idx := range staleIdxs {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				p := prs[i]
				ch <- result{idx: i, status: fetchPRStatus(p.Number, p.Repo)}
			}(idx)
		}
		wg.Wait()
		close(ch)
		for r := range ch {
			prs[r.idx].CI = r.status.CI
			prs[r.idx].Review = r.status.Review
			prs[r.idx].StatusAt = now
		}
		if isPRsFromCtx {
			ctx.PRs = prs
			ctxDirty = true
		}
	}

	for _, p := range prs {
		url := p.URL
		if url == "" && p.Repo != "" {
			url = fmt.Sprintf("https://github.com/%s/pull/%d", p.Repo, p.Number)
		}
		ciC := colorFor(p.CI)
		revC := colorFor(p.Review)
		numStr := gradient(fmt.Sprintf("#%d", p.Number), ciC, revC)

		tickets := extractTickets(p.Title, ticketPatterns)
		cleanTitle := stripTickets(applyStrip(p.Title, stripREs), ticketPatterns)
		ticketStr := renderTickets(tickets, ticketPatterns)

		if ticketStr != "" {
			fmt.Printf("%s %s %s\n", numStr, ticketStr, osc8(url, cleanTitle))
		} else {
			fmt.Printf("%s %s\n", numStr, osc8(url, cleanTitle))
		}
	}

	if ctxDirty {
		saveSessionCtx(ctxPath, ctx)
	}

	// ── Manual ticket lines ───────────────────────────────────────────────────
	for _, t := range ctx.Tickets {
		label := applyStrip(t.Title, stripREs)
		if label == "" {
			label = t.ID
		}
		url := ticketURL(t.ID, ticketPatterns)
		if url != "" {
			fmt.Printf("%s%s%s %s\n", ansiDim, t.ID, ansiReset, osc8(url, label))
		} else {
			fmt.Printf("%s%s%s %s\n", ansiDim, t.ID, ansiReset, label)
		}
	}
}
