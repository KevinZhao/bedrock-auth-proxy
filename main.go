package main

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

var (
	listenAddr     = envOr("LISTEN_HOST", "127.0.0.1") + ":" + envOr("PROXY_PORT", "8888")
	upstreamEP     = os.Getenv("UPSTREAM_ENDPOINT")
	authHeaderName = os.Getenv("AUTH_HEADER_NAME")
	authHeaderVal  = os.Getenv("AUTH_HEADER_VALUE")
	debug          = os.Getenv("DEBUG") != "0"
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

var upstreamURL *url.URL

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func debugLog(format string, args ...interface{}) {
	if debug {
		log.Printf("[DEBUG] "+format, args...)
	}
}

func maskValue(v string) string {
	if len(v) <= 8 {
		return "***"
	}
	return v[:4] + "..." + v[len(v)-4:]
}

func logHeaders(prefix string, h http.Header) {
	if !debug {
		return
	}
	for k, vs := range h {
		val := strings.Join(vs, ", ")
		if strings.EqualFold(k, authHeaderName) || strings.EqualFold(k, "authorization") {
			val = maskValue(val)
		}
		log.Printf("[DEBUG] %s header: %s: %s", prefix, k, val)
	}
}

var hopByHopHeaders = map[string]bool{
	"Transfer-Encoding":   true,
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
		if hopByHopHeaders[k] || k == "Authorization" || strings.HasPrefix(k, "X-Amz-") {
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

// rewritePath strips the model ID from Bedrock-style paths.
// /model/{model-id}/invoke → /model/invoke
// /model/{model-id}/invoke-with-response-stream → /model/invoke-with-response-stream
func rewritePath(rawPath string) string {
	if !strings.HasPrefix(rawPath, "/model/") {
		return rawPath
	}
	rest := rawPath[len("/model/"):] // "claude-opus-4-6/invoke-with-response-stream"
	idx := strings.Index(rest, "/")
	if idx < 0 {
		return rawPath
	}
	rewritten := "/model" + rest[idx:]
	debugLog("rewrite path: %s → %s", rawPath, rewritten)
	return rewritten
}

func buildTargetURL(rawPath, rawQuery string) string {
	t := *upstreamURL
	basePath := strings.TrimRight(t.Path, "/")
	t.RawPath = basePath + rawPath
	t.Path, _ = url.PathUnescape(t.RawPath)
	t.RawQuery = rawQuery
	return t.String()
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	start := time.Now()

	rawPath := r.URL.RawPath
	if rawPath == "" {
		rawPath = r.URL.Path
	}
	rawPath = rewritePath(rawPath)

	debugLog(">>> %s %s (content-length: %d)", r.Method, rawPath, r.ContentLength)
	if debug {
		logHeaders("req-in", r.Header)
	}

	const maxBody = 50 << 20
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		debugLog("read body failed: %v", err)
		http.Error(w, `{"error":"read_body_failed"}`, http.StatusBadGateway)
		return
	}
	if len(body) > maxBody {
		http.Error(w, `{"error":"body_too_large"}`, http.StatusRequestEntityTooLarge)
		return
	}

	targetURL := buildTargetURL(rawPath, r.URL.RawQuery)
	debugLog("target: %s (body: %d bytes)", targetURL, len(body))

	req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, bytes.NewReader(body))
	if err != nil {
		debugLog("build request failed: %v", err)
		http.Error(w, `{"error":"build_request_failed"}`, http.StatusBadGateway)
		return
	}

	copyRequestHeaders(req, r)
	req.Header.Set(authHeaderName, authHeaderVal)
	if debug {
		logHeaders("req-out", req.Header)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		log.Printf("upstream error: %s %s -> %v (%.0fms)", r.Method, rawPath, err, time.Since(start).Seconds()*1000)
		http.Error(w, `{"error":"upstream_error"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	debugLog("<<< %d %s (%.0fms)", resp.StatusCode, rawPath, time.Since(start).Seconds()*1000)
	if debug {
		logHeaders("resp", resp.Header)
	}

	copyResponseHeaders(w, resp)

	if resp.StatusCode >= 400 {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		log.Printf("upstream %d: %s %s (%.0fms) body: %s", resp.StatusCode, r.Method, rawPath, time.Since(start).Seconds()*1000, string(errBody))
		w.WriteHeader(resp.StatusCode)
		w.Write(errBody)
		return
	}

	w.WriteHeader(resp.StatusCode)

	if strings.Contains(rawPath, "response-stream") {
		flusher, canFlush := w.(http.Flusher)
		buf := make([]byte, 32*1024)
		var totalBytes int64
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				totalBytes += int64(n)
				if _, werr := w.Write(buf[:n]); werr != nil {
					debugLog("stream write error after %d bytes: %v", totalBytes, werr)
					break
				}
				if canFlush {
					flusher.Flush()
				}
			}
			if err != nil {
				if err != io.EOF {
					debugLog("stream read error after %d bytes: %v", totalBytes, err)
				}
				break
			}
		}
		debugLog("stream done: %s %s (%d bytes, %.0fms)", r.Method, rawPath, totalBytes, time.Since(start).Seconds()*1000)
		return
	}

	n, _ := io.Copy(w, resp.Body)
	debugLog("response done: %s %s (%d bytes, %.0fms)", r.Method, rawPath, n, time.Since(start).Seconds()*1000)
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

	log.Printf("Bedrock Auth Proxy on %s -> %s", listenAddr, upstreamURL.Host)
	if debug {
		log.Printf("[DEBUG] debug logging enabled")
		log.Printf("[DEBUG] auth header: %s = %s", authHeaderName, maskValue(authHeaderVal))
	}
	log.Fatal(http.ListenAndServe(listenAddr, http.HandlerFunc(proxyHandler)))
}
