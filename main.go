package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	listenAddr     = envOr("LISTEN_HOST", "127.0.0.1") + ":" + envOr("PROXY_PORT", "8888")
	upstreamEP     = os.Getenv("UPSTREAM_ENDPOINT") // e.g. https://your-gateway.example.com/api
	authHeaderName = os.Getenv("AUTH_HEADER_NAME")  // e.g. token
	authHeaderVal  = os.Getenv("AUTH_HEADER_VALUE") // the auth token value
)

var reqCounter atomic.Int64

var httpClient = &http.Client{
	Transport: &http.Transport{
		ForceAttemptHTTP2:     true,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 600 * time.Second,
	},
}

var upstreamURL *url.URL

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// hop-by-hop headers that must not be forwarded
var hopByHopHeaders = map[string]bool{
	"Transfer-Encoding":   true,
	"Content-Encoding":    true,
	"Connection":          true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Upgrade":             true,
}

func copyRequestHeaders(dst, src *http.Request) {
	for k, vs := range src.Header {
		if hopByHopHeaders[k] {
			continue
		}
		for _, v := range vs {
			dst.Header.Add(k, v)
		}
	}
}

func copyResponseHeaders(w http.ResponseWriter, resp *http.Response) {
	for k, vs := range resp.Header {
		if hopByHopHeaders[k] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
}

func buildTargetURL(rawPath, rawQuery string) string {
	t := *upstreamURL
	t.Path = strings.TrimRight(t.Path, "/") + rawPath
	t.RawQuery = rawQuery
	return t.String()
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	reqID := reqCounter.Add(1)
	defer r.Body.Close()

	rawPath := r.URL.RawPath
	if rawPath == "" {
		rawPath = r.URL.Path
	}

	targetURL := buildTargetURL(rawPath, r.URL.RawQuery)

	const maxBody = 50 << 20
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		http.Error(w, `{"error":"read_body_failed"}`, http.StatusBadGateway)
		return
	}
	if len(body) > maxBody {
		http.Error(w, `{"error":"body_too_large"}`, http.StatusRequestEntityTooLarge)
		return
	}

	log.Printf("[#%d] -> %s %s (%dB)", reqID, r.Method, rawPath, len(body))

	req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, bytes.NewReader(body))
	if err != nil {
		http.Error(w, `{"error":"build_request_failed"}`, http.StatusBadGateway)
		return
	}

	// Forward all request headers, then override auth
	copyRequestHeaders(req, r)
	req.Header.Set("Host", upstreamURL.Host)
	req.Header.Set(authHeaderName, authHeaderVal)

	isStreaming := strings.Contains(rawPath, "response-stream")
	t0 := time.Now()

	resp, err := httpClient.Do(req)
	if err != nil {
		log.Printf("[#%d] upstream error after %.1fs: %v", reqID, time.Since(t0).Seconds(), err)
		http.Error(w, `{"error":"upstream_error"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		errBody, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Printf("[#%d] error reading upstream error body: %v", reqID, err)
			http.Error(w, `{"error":"upstream_read_failed"}`, http.StatusBadGateway)
			return
		}
		preview := string(errBody)
		if len(preview) > 500 {
			preview = preview[:500]
		}
		log.Printf("[#%d] <- %d in %.1fs | %s", reqID, resp.StatusCode, time.Since(t0).Seconds(), preview)
		copyResponseHeaders(w, resp)
		w.WriteHeader(resp.StatusCode)
		w.Write(errBody)
		return
	}

	if isStreaming {
		flusher, canFlush := w.(http.Flusher)
		copyResponseHeaders(w, resp)
		w.WriteHeader(resp.StatusCode)
		totalBytes := 0
		buf := make([]byte, 32*1024)
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				if _, werr := w.Write(buf[:n]); werr != nil {
					log.Printf("[#%d] downstream write error: %v", reqID, werr)
					break
				}
				if canFlush {
					flusher.Flush()
				}
				totalBytes += n
			}
			if err != nil {
				break
			}
		}
		log.Printf("[#%d] <- %d streamed %dB in %.1fs", reqID, resp.StatusCode, totalBytes, time.Since(t0).Seconds())
		return
	}

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("[#%d] error reading upstream body: %v", reqID, err)
		http.Error(w, `{"error":"upstream_read_failed"}`, http.StatusBadGateway)
		return
	}
	log.Printf("[#%d] <- %d %dB in %.1fs", reqID, resp.StatusCode, len(respBody), time.Since(t0).Seconds())
	copyResponseHeaders(w, resp)
	w.WriteHeader(resp.StatusCode)
	w.Write(respBody)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":          "ok",
		"requests_served": reqCounter.Load(),
	})
}

func main() {
	if upstreamEP == "" {
		log.Fatal("UPSTREAM_ENDPOINT is required")
	}
	if authHeaderName == "" || authHeaderVal == "" {
		log.Fatal("AUTH_HEADER_NAME and AUTH_HEADER_VALUE are required")
	}

	var err error
	upstreamURL, err = url.Parse(upstreamEP)
	if err != nil || upstreamURL.Host == "" {
		log.Fatalf("Invalid UPSTREAM_ENDPOINT: %s", upstreamEP)
	}

	log.Printf("Bedrock Auth Proxy starting on %s", listenAddr)
	log.Printf("Upstream: %s", upstreamURL.Host)
	log.Printf("Auth header: [configured]")

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/", proxyHandler)

	srv := &http.Server{
		Addr:           listenAddr,
		Handler:        mux,
		ReadTimeout:    30 * time.Second,
		WriteTimeout:   0,
		MaxHeaderBytes: 1 << 20,
	}

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		log.Printf("Received %v, shutting down...", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("Shutdown error: %v", err)
		}
	}()

	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("Server failed: %v", err)
	}
	log.Printf("Server stopped. Served %d requests.", reqCounter.Load())
}
