package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"
)

var expectedProto = []byte{0x08, 0x11, 0x1a, 0x03, 'A', 'd', 'a'}

func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	cert, err := makeCertificate(os.Args[1])
	if err != nil {
		_, _ = os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /sample.UserService/Get", func(w http.ResponseWriter, r *http.Request) {
		request, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if r.ProtoMajor != 2 || r.Header.Get("Content-Type") != "application/grpc" ||
			r.Header.Get("Te") != "trailers" || r.Header.Get("X-Request-Id") != "rpc-1" ||
			r.Header.Get("Grpc-Timeout") == "" || err != nil || len(request) != 12 ||
			request[0] != 0 || int(binary.BigEndian.Uint32(request[1:5])) != len(request)-5 {
			http.Error(w, "invalid unary gRPC request", http.StatusBadRequest)
			return
		}
		for i, b := range expectedProto {
			if request[i+5] != b {
				http.Error(w, "unexpected protobuf bytes", http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/grpc+proto")
		w.Header().Set("Trailer", "grpc-status, grpc-message, x-server")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(request)
		w.Header().Set("grpc-status", "0")
		w.Header().Set("grpc-message", "interop%20ok")
		w.Header().Set("x-server", "go-tls-http2")
	})
	server := &http.Server{
		Addr:      "127.0.0.1:18443",
		Handler:   mux,
		ErrorLog:  log.New(io.Discard, "", 0),
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12, NextProtos: []string{"h2", "http/1.1"}},
	}
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		_, _ = os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
	if err := server.ServeTLS(listener, "", ""); err != nil && err != http.ErrServerClosed {
		_, _ = os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
}

func makeCertificate(path string) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(time.Hour),
		DNSNames:     []string{"localhost"},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: template}, nil
}
