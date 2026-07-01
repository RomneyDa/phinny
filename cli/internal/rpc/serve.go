package rpc

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

// debugLog writes to stderr when PHINNY_DEBUG is set (diagnostics only).
var debugOn = os.Getenv("PHINNY_DEBUG") != ""

func debugLog(format string, args ...any) {
	if debugOn {
		fmt.Fprintf(os.Stderr, "[phinny] "+format+"\n", args...)
	}
}

// Request is one JSON-RPC-style call.
type Request struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response is one reply. Exactly one of Result/Error is set.
type Response struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Result any             `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

// dispatch runs one request with a per-call timeout and never panics out.
func (h *Handler) dispatch(base context.Context, req Request) Response {
	ctx, cancel := context.WithTimeout(base, 120*time.Second)
	defer cancel()
	result, rerr := h.Handle(ctx, req.Method, req.Params)
	if rerr != nil {
		return Response{ID: req.ID, Error: rerr}
	}
	return Response{ID: req.ID, Result: result}
}

// ServeStdio reads newline/whitespace-delimited JSON requests from r and writes
// one JSON response per request to w. Used by the Mac app, which launches
// `phinny serve --stdio` and keeps the connection (and DB) warm. Serialized:
// one request at a time, matching the single SQLite writer.
func (h *Handler) ServeStdio(ctx context.Context, r io.Reader, w io.Writer) error {
	dec := json.NewDecoder(r)
	enc := json.NewEncoder(w)
	var mu sync.Mutex
	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			if err == io.EOF {
				return nil
			}
			// Report a parse error and keep going if possible.
			mu.Lock()
			_ = enc.Encode(Response{Error: newErr("parse_error", err.Error())})
			mu.Unlock()
			return err
		}
		debugLog("recv method=%s", req.Method)
		start := time.Now()
		resp := h.dispatch(ctx, req)
		mu.Lock()
		err := enc.Encode(resp)
		mu.Unlock()
		if err != nil {
			debugLog("encode error method=%s: %v", req.Method, err)
			return err
		}
		debugLog("sent method=%s ok=%v in %s", req.Method, resp.Error == nil, time.Since(start))
	}
}

// ServeHTTP runs a loopback HTTP server: POST / with a Request body returns a
// Response. Optional, for power users / agents that want a persistent endpoint.
func (h *Handler) ServeHTTP(ctx context.Context, addr string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			_ = json.NewEncoder(w).Encode(Response{Error: newErr("bad_request", "POST a JSON request body")})
			return
		}
		var req Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			_ = json.NewEncoder(w).Encode(Response{Error: newErr("parse_error", err.Error())})
			return
		}
		_ = json.NewEncoder(w).Encode(h.dispatch(r.Context(), req))
	})
	srv := &http.Server{Addr: addr, Handler: mux}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}
