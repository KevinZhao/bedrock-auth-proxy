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

	rawPath := r.URL.RawPath
	if rawPath == "" {
		rawPath = r.URL.Path
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

	req, err := http.NewRequestWithContext(r.Context(), r.Method, buildTargetURL(rawPath, r.URL.RawQuery), bytes.NewReader(body))
	if err != nil {
		http.Error(w, `{"error":"build_request_failed"}`, http.StatusBadGateway)
		return
	}

	copyRequestHeaders(req, r)
	req.Header.Set(authHeaderName, authHeaderVal)

	resp, err := httpClient.Do(req)
	if err != nil {
		log.Printf("upstream error: %s %s -> %v", r.Method, rawPath, err)
		http.Error(w, `{"error":"upstream_error"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	copyResponseHeaders(w, resp)
	w.WriteHeader(resp.StatusCode)

	if resp.StatusCode >= 400 {
		log.Printf("upstream %d: %s %s", resp.StatusCode, r.Method, rawPath)
	}

	if strings.Contains(rawPath, "response-stream") {
		flusher, canFlush := w.(http.Flusher)
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
			}
			if err != nil {
				break
			}
		}
		return
	}

	io.Copy(w, resp.Body)
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
	log.Fatal(http.ListenAndServe(listenAddr, http.HandlerFunc(proxyHandler)))
}
