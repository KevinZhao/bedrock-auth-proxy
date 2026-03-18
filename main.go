package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
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

var (
	reqCounter   atomic.Int64
	requestCount atomic.Int64
)

var httpClient = &http.Client{
	Transport: &http.Transport{
		ForceAttemptHTTP2:     true,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 600 * time.Second,
	},
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var skipHeaders = map[string]bool{
	"Transfer-Encoding": true,
	"Content-Encoding":  true,
	"Connection":        true,
}

func copyResponseHeaders(w http.ResponseWriter, resp *http.Response) {
	for k, vs := range resp.Header {
		if skipHeaders[k] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	reqID := reqCounter.Add(1)
	requestCount.Add(1)

	rawPath := r.URL.RawPath
	if rawPath == "" {
		rawPath = r.URL.Path
	}

	targetURL := strings.TrimRight(upstreamEP, "/") + rawPath
	if q := r.URL.RawQuery; q != "" {
		targetURL += "?" + q
	}

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

	ct := r.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/json"
	}
	req.Header.Set("Content-Type", ct)
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
		errBody, _ := io.ReadAll(resp.Body)
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

	respBody, _ := io.ReadAll(resp.Body)
	log.Printf("[#%d] <- %d %dB in %.1fs", reqID, resp.StatusCode, len(respBody), time.Since(t0).Seconds())
	copyResponseHeaders(w, resp)
	w.WriteHeader(resp.StatusCode)
	w.Write(respBody)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok","requests_served":` + fmt.Sprint(requestCount.Load()) + `}`))
}

func main() {
	if upstreamEP == "" {
		log.Fatal("UPSTREAM_ENDPOINT is required")
	}
	if authHeaderName == "" || authHeaderVal == "" {
		log.Fatal("AUTH_HEADER_NAME and AUTH_HEADER_VALUE are required")
	}

	log.Printf("Bedrock Auth Proxy starting on %s", listenAddr)
	log.Printf("Upstream: %s", upstreamEP)
	log.Printf("Auth header: %s", authHeaderName)

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
		srv.Shutdown(ctx)
	}()

	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("Server failed: %v", err)
	}
	log.Printf("Server stopped. Served %d requests.", requestCount.Load())
}
