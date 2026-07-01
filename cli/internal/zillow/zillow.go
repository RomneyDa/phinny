// Package zillow fetches a Zillow "Zestimate" by driving a real browser engine
// (headless Chrome via chromedp), letting Zillow's JavaScript run, then reading
// the value out of the DOM. This mirrors ZillowScraper.swift, which used an
// offscreen WKWebView; Go has no embedded browser, so Chrome is a PEER
// DEPENDENCY the user must install.
//
// If no Chrome/Chromium is found, FetchZestimate returns a *Error with
// Code == CodeChromeNotInstalled so callers (CLI, daemon, app UI) can show a
// clear "install Chrome" message instead of a generic failure.
package zillow

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// Error codes returned via *Error.Code.
const (
	CodeChromeNotInstalled = "chrome_not_installed"
	CodeNoAddress          = "no_address"
	CodeBlocked            = "blocked"
	CodeNotFound           = "not_found"
	CodeLoadFailed         = "load_failed"
)

// Error is a typed Zillow failure carrying a machine-readable code.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

func errf(code, msg string) *Error { return &Error{Code: code, Message: msg} }

// ChromeInstallURL is the suggested download for the missing peer dependency.
const ChromeInstallURL = "https://www.google.com/chrome/"

// candidatePaths are common macOS browser locations, plus PATH lookups.
var candidatePaths = []string{
	"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
	"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
	"/Applications/Chromium.app/Contents/MacOS/Chromium",
	"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
	"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
}

// FindBrowser returns the path to an installed Chromium-family browser, or "".
func FindBrowser() string {
	if env := strings.TrimSpace(os.Getenv("PHINNY_CHROME_PATH")); env != "" {
		if _, err := os.Stat(env); err == nil {
			return env
		}
	}
	home, _ := os.UserHomeDir()
	for _, p := range candidatePaths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
		if home != "" {
			hp := home + p // also check ~/Applications/...
			if _, err := os.Stat(hp); err == nil {
				return hp
			}
		}
	}
	for _, name := range []string{"google-chrome", "chromium", "chromium-browser", "chrome"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// ChromeAvailable reports whether a usable browser is installed.
func ChromeAvailable() bool { return FindBrowser() != "" }

// Result is a Zestimate lookup result (value + diagnostics).
type Result struct {
	Value    float64 `json:"value"`
	FinalURL string  `json:"final_url"`
	Title    string  `json:"title"`
}

// FetchZestimate loads `input` (a Zillow property URL, preferred, or a plain
// address) and returns the Zestimate. Best-effort: a bot-check yields CodeBlocked.
func FetchZestimate(ctx context.Context, input string) (Result, error) {
	trimmed := strings.TrimSpace(input)
	if trimmed == "" {
		return Result{}, errf(CodeNoAddress, "Add a property address or Zillow link to this mortgage first.")
	}
	browser := FindBrowser()
	if browser == "" {
		return Result{}, errf(CodeChromeNotInstalled,
			"Zillow lookups need Google Chrome (or another Chromium browser), which was not found. Install it from "+ChromeInstallURL+" and try again.")
	}

	target := trimmed
	if !strings.HasPrefix(strings.ToLower(trimmed), "http") {
		target = searchURL(trimmed)
	}

	headless := os.Getenv("PHINNY_ZILLOW_HEADFUL") != "1"
	const ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

	allocOpts := append([]chromedp.ExecAllocatorOption{},
		chromedp.ExecPath(browser),
		chromedp.UserAgent(ua),
		chromedp.WindowSize(1200, 1400),
		chromedp.Flag("headless", headless),
		chromedp.Flag("disable-blink-features", "AutomationControlled"),
		chromedp.Flag("hide-scrollbars", false),
		chromedp.NoFirstRun,
		chromedp.NoDefaultBrowserCheck,
	)

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(ctx, allocOpts...)
	defer cancelAlloc()
	taskCtx, cancelTask := chromedp.NewContext(allocCtx)
	defer cancelTask()

	// Overall budget for the whole lookup.
	taskCtx, cancelTimeout := context.WithTimeout(taskCtx, 75*time.Second)
	defer cancelTimeout()

	// Establish a session on the homepage first (a cold property request
	// otherwise resolves to a generic metro page).
	_ = chromedp.Run(taskCtx,
		network.Enable(),
		network.SetExtraHTTPHeaders(network.Headers{"Accept-Language": "en-US,en;q=0.9"}),
		chromedp.Navigate("https://www.zillow.com/"),
		chromedp.Sleep(1500*time.Millisecond),
	)

	if err := chromedp.Run(taskCtx, chromedp.Navigate(target)); err != nil {
		if ctx.Err() != nil {
			return Result{}, errf(CodeLoadFailed, "Zillow lookup was cancelled or timed out.")
		}
		return Result{}, errf(CodeLoadFailed, "Zillow page failed to load: "+err.Error())
	}

	var res Result
	_ = chromedp.Run(taskCtx,
		chromedp.Evaluate("document.location.href", &res.FinalURL),
		chromedp.Evaluate("document.title", &res.Title),
	)

	for i := 0; i < 8; i++ {
		var value float64
		if err := chromedp.Run(taskCtx, chromedp.Evaluate(extractJS, &value)); err == nil && value > 0 {
			res.Value = value
			return res, nil
		}
		if blocked(taskCtx) {
			return Result{}, errf(CodeBlocked, "Zillow showed a bot check and couldn't be read automatically. Try again in a little while.")
		}
		select {
		case <-taskCtx.Done():
			return Result{}, errf(CodeNotFound, "Couldn't find a Zestimate for that address on Zillow.")
		case <-time.After(1600 * time.Millisecond):
		}
	}
	if blocked(taskCtx) {
		return Result{}, errf(CodeBlocked, "Zillow showed a bot check and couldn't be read automatically. Try again in a little while.")
	}
	return Result{}, errf(CodeNotFound, "Couldn't find a Zestimate for that address on Zillow.")
}

func searchURL(address string) string {
	slug := strings.Join(strings.FieldsFunc(strings.ReplaceAll(address, ",", " "), func(r rune) bool {
		return r == ' ' || r == '\t'
	}), "-")
	return "https://www.zillow.com/homes/" + slug + "_rb/"
}

func blocked(ctx context.Context) bool {
	var text string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`(document.body ? document.body.innerText.slice(0,4000) : '')`, &text)); err != nil {
		return false
	}
	t := strings.ToLower(text)
	for _, marker := range []string{"press & hold", "press and hold", "captcha", "are you a human", "verify you are"} {
		if strings.Contains(t, marker) {
			return true
		}
	}
	return false
}

// extractJS returns the Zestimate number, or 0. Mirrors the Swift extractor.
const extractJS = `(function () {
  var html = document.documentElement.innerHTML;
  var patterns = [
    /"zestimate":\s*\{\s*"?amount"?\s*:\s*([0-9]{5,})/i,
    /"zestimate"\s*:\s*([0-9]{5,})/i,
    /\\"zestimate\\":\s*\{\\?"?value\\?"?:\s*([0-9]{5,})/i
  ];
  for (var i = 0; i < patterns.length; i++) {
    var m = html.match(patterns[i]);
    if (m) return parseInt(m[1]);
  }
  var text = document.body ? document.body.innerText : "";
  var t = text.match(/zestimate[^0-9$]{0,40}\$\s*([0-9][0-9,]{4,})/i);
  if (t) return parseInt(t[1].replace(/,/g, ""));
  return 0;
})();`
