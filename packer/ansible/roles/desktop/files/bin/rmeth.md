```bash
docker run --rm -it -v $(pwd):/workspace -w /workspace crystallang/crystal:latest-alpine crystal build controller.cr --release --static
docker run --rm -it -v $(pwd):/workspace -w /workspace crystallang/crystal:latest-alpine crystal build agent.cr --release --static
```

# agent
#!/usr/bin/env crystal
# agent.cr —SOCKS5 reverse tunnel agent via WebSocket
#
# On startup the agent dials out to the controller and maintains
# MAX_SESSIONS concurrent WebSocket connections.  Each connection carries
# one SOCKS5 session (the controller bridges a SOCKS5 client's TCP stream
# over the WebSocket to this agent, which fulfills the request and relays
# data back).  When a session ends the worker immediately reconnects.

require "socket"
require "http/web_socket"   # HTTP::WebSocket client
require "time"

# ── controller endpoint (compile-time defaults, overridable at runtime) ───────
CONTROLLER_HOST  = "127.0.0.1"
CONTROLLER_PORT  = 8080
CONTROLLER_PATH  = "/rsocks"
MAX_SESSIONS     = 5   # concurrent WebSocket connections kept open

module Socks
  class Config
    property cb_host : String
    property cb_port : Int32
    property cb_path : String
    property timeout : Int32
    property verbose : Bool

    def initialize(
      @cb_host = CONTROLLER_HOST,
      @cb_port = CONTROLLER_PORT,
      @cb_path = CONTROLLER_PATH,
      @timeout = 30,
      @verbose = false
    )
    end

    # Usage: crocks_final [cb_host [cb_port [cb_path [timeout [verbose]]]]]
    def self.from_args(args)
      new(
        cb_host: args[0]? || CONTROLLER_HOST,
        cb_port: (args[1]? || CONTROLLER_PORT.to_s).to_i,
        cb_path: args[2]? || CONTROLLER_PATH,
        timeout: (args[3]? || "30").to_i,
        verbose: args[4]? == "true",
      )
    end
  end

  module Log
    def self.info(msg);  puts "[INFO]  #{Time.local}  #{msg}"; end
    def self.error(msg); puts "[ERROR] #{Time.local}  #{msg}"; end
  end

  module Rep
    SUCCESS     = 0x00_u8
    FAILURE     = 0x01_u8
    UNREACHABLE = 0x04_u8
  end

  # ── WebSocketIO ─────────────────────────────────────────────────────────────
  # Wraps HTTP::WebSocket as a plain IO so all existing SOCKS5 protocol code
  # (which calls read_byte / read_fully / write / flush) works unchanged.
  #
  # Threading model (Crystal cooperative fibers):
  #   Fiber A  →  ws.run  →  on_binary callback  →  @recv_queue.send(chunk)
  #   Fiber B  →  Session  →  ws_io.read          →  @recv_queue.receive
  #
  # ws.run MUST be spawned in a separate fiber BEFORE the first read call so
  # the scheduler can alternate between driving incoming frames and consuming
  # them.  Both fibers share the same ws object safely because Crystal's event
  # loop only executes one fiber at a time and ws.send / ws.run operate on
  # different directions of the underlying TCP socket.
  class WebSocketIO < IO
    getter ws : HTTP::WebSocket

    def initialize(@ws : HTTP::WebSocket)
      # Buffered channel: on_binary can get a few frames ahead of the reader.
      @recv_queue = Channel(Bytes?).new(64)  # nil = EOF sentinel
      @leftover   = Bytes.empty              # bytes left over from a partial read

      @ws.on_binary do |bytes|
        # bytes.dup: own the data — the WebSocket may reuse its read buffer.
        @recv_queue.send(bytes.dup) rescue nil
      end

      @ws.on_close do |_code, _msg|
        # Unblock any fiber blocked in read.
        @recv_queue.send(nil) rescue nil
      end
    end

    # ── IO contract ────────────────────────────────────────────────────────

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?

      # Drain bytes left over from a previously oversized frame first.
      if @leftover.size > 0
        n = Math.min(slice.size, @leftover.size)
        @leftover[0, n].copy_to(slice)
        remaining = @leftover.size - n
        @leftover = if remaining > 0
          tmp = Bytes.new(remaining)
          @leftover[n, remaining].copy_to(tmp)
          tmp
        else
          Bytes.empty
        end
        return n
      end

      # Block until the next WebSocket frame arrives (Fiber A puts it here).
      chunk = begin
        @recv_queue.receive
      rescue Channel::ClosedError
        return 0
      end

      return 0 if chunk.nil?  # EOF from on_close

      n = Math.min(slice.size, chunk.size)
      chunk[0, n].copy_to(slice)

      # Save any bytes that did not fit in slice for the next read call.
      remaining = chunk.size - n
      if remaining > 0
        @leftover = Bytes.new(remaining)
        chunk[n, remaining].copy_to(@leftover)
      end

      n
    end

    def write(slice : Bytes) : Nil
      # Each call produces one binary WebSocket frame.  The frame is sent
      # synchronously to the kernel send buffer — no extra flushing needed.
      @ws.send(slice)
    end

    # No-op: WebSocket frames are dispatched immediately by ws.send.
    def flush : Nil; end

    def close : Nil
      @ws.close rescue nil
      # Unblock any fiber waiting in read so it gets EOF and exits cleanly.
      @recv_queue.close rescue nil
    end
  end

  # ── Protocol ────────────────────────────────────────────────────────────────
  # All methods accept IO so they work with both WebSocketIO and TCPSocket.

  module Protocol
    class Handshake
      def self.perform(client : IO)
        ver = client.read_byte
        raise "Empty handshake" if ver.nil?
        raise "Not SOCKS5 (VER=#{ver})" unless ver == 5

        nmethods = (client.read_byte || raise "Truncated NMETHODS").to_i
        methods  = Bytes.new(nmethods)
        client.read_fully(methods) if nmethods > 0

        if methods.any? { |b| b == 0x00_u8 }
          client.write Bytes[5, 0]
          client.flush
        else
          client.write Bytes[5, 0xFF]
          client.flush
          raise "No acceptable auth method"
        end
      end
    end

    class Request
      def self.read(client : IO)
        ver = client.read_byte
        raise "Empty request" if ver.nil?
        raise "Not SOCKS5" unless ver == 5

        cmd  = client.read_byte || raise "Truncated CMD"
        client.read_byte                  # RSV — discard
        atyp = client.read_byte || raise "Truncated ATYP"

        address = case atyp
        when 1_u8  # IPv4
          buf = Bytes.new(4)
          client.read_fully(buf)
          "#{buf[0]}.#{buf[1]}.#{buf[2]}.#{buf[3]}"
        when 3_u8  # domain name
          len = (client.read_byte || raise "Truncated domain length").to_i
          buf = Bytes.new(len)
          client.read_fully(buf)
          String.new(buf)
        when 4_u8
          raise "IPv6 not supported"
        else
          raise "Unknown ATYP: #{atyp}"
        end

        port_buf = Bytes.new(2)
        client.read_fully(port_buf)
        port = (port_buf[0].to_u16 << 8) | port_buf[1].to_u16

        {cmd: cmd.to_u8, address: address, port: port.to_i, atyp: atyp.to_u8}
      end

      def self.reply(client : IO, rep : UInt8, bind_addr = "0.0.0.0", bind_port = 0)
        bytes = Bytes.new(10)
        bytes[0] = 5_u8
        bytes[1] = rep
        bytes[2] = 0_u8
        bytes[3] = 1_u8   # ATYP = IPv4

        parts = bind_addr.split(".")
        4.times { |i| bytes[4 + i] = (parts[i]? || "0").to_u8 }

        bytes[8] = ((bind_port >> 8) & 0xFF).to_u8
        bytes[9] =  (bind_port       & 0xFF).to_u8

        client.write(bytes)
        client.flush
      end
    end
  end

  # ── Relay ────────────────────────────────────────────────────────────────────

  class Relay
    # Bidirectional relay between any IO (WebSocketIO, TCPSocket, …) and a
    # TCPSocket target.  Blocks the calling fiber until both directions finish.
    def self.between(local : IO, remote : TCPSocket, timeout : Int32)
      remote.read_timeout = timeout.seconds
      # Also set timeout on local if it supports it (TCPSocket does via
      # IO::Buffered; WebSocketIO ignores it because it has no such method —
      # its read already unblocks when on_close fires).
      if local.responds_to?(:read_timeout=)
        local.read_timeout = timeout.seconds
      end

      done = Channel(Nil).new(2)
      spawn { Relay.pipe(local, remote, done) }
      spawn { Relay.pipe(remote, local, done) }
      2.times { done.receive }
    end

    # UDP associate relay (unchanged from forward-proxy version).
    def self.udp(sock : UDPSocket, timeout : Int32)
      sock.read_timeout = timeout.seconds
      inbound = Bytes.new(65536)

      loop do
        sz, src_addr = sock.receive(inbound)

        next if sz < 4 || inbound[2] != 0_u8

        atyp = inbound[3]
        dst_host, hdr_end = Relay.parse_udp_addr(inbound, atyp, 4)
        next if dst_host.nil? || hdr_end + 2 > sz

        dst_port = (inbound[hdr_end].to_u16 << 8) | inbound[hdr_end + 1]
        payload  = inbound[hdr_end + 2, sz - hdr_end - 2]

        reply_buf = Bytes.new(65536)
        reply_sz  = 0
        fwd : UDPSocket? = nil

        begin
          fwd = UDPSocket.new
          fwd.connect(dst_host, dst_port.to_i)
          fwd.read_timeout = timeout.seconds
          fwd.write(payload)
          reply_sz = fwd.read(reply_buf)
        rescue
          next
        ensure
          fwd.try(&.close)
        end

        next if reply_sz == 0

        hdr_size = hdr_end + 2
        packet = Bytes.new(hdr_size + reply_sz)
        packet[0, hdr_size].copy_from(inbound[0, hdr_size])
        packet[hdr_size, reply_sz].copy_from(reply_buf[0, reply_sz])
        sock.send(packet, src_addr)
      rescue IO::TimeoutError
        break
      rescue IO::Error
        break
      rescue ex
        Log.error("UDP relay error: #{ex.message}")
      end
    end

    # One-directional pipe between any two IOs.
    # Closes only src on exit (peer direction detects the close itself).
    # Signals `done` so `between` knows this direction has finished.
    def self.pipe(src : IO, dst : IO, done : Channel(Nil))
      buf = Bytes.new(16384)
      loop do
        n = src.read(buf)
        break if n == 0
        dst.write(buf[0, n])
        dst.flush
      end
    rescue ex : IO::TimeoutError
      raise ex
    rescue IO::Error
    ensure
      src.close rescue nil
      done.send(nil) rescue nil
    end

    def self.parse_udp_addr(buf : Bytes, atyp : UInt8, offset : Int32)
      case atyp
      when 1_u8
        return {nil, 0} if offset + 4 > buf.size
        addr = "#{buf[offset]}.#{buf[offset + 1]}.#{buf[offset + 2]}.#{buf[offset + 3]}"
        {addr, offset + 4}
      when 3_u8
        return {nil, 0} if offset >= buf.size
        len = buf[offset].to_i
        return {nil, 0} if offset + 1 + len > buf.size
        addr = String.new(buf[offset + 1, len])
        {addr, offset + 1 + len}
      else
        {nil, 0}
      end
    end
  end

  # ── Session ──────────────────────────────────────────────────────────────────
  # Client is IO so it works with both WebSocketIO (reverse tunnel) and
  # TCPSocket (if the forward-proxy Server class is used in future).

  class Session
    def initialize(@client : IO, @config : Config)
    end

    def start
      Protocol::Handshake.perform(@client)
      req = Protocol::Request.read(@client)

      case req[:cmd]
      when 1_u8 then handle_connect(req)
      when 2_u8 then handle_bind(req)
      when 3_u8 then handle_udp_associate(req)
      else
        Protocol::Request.reply(@client, Rep::FAILURE)
        raise "Unknown CMD: #{req[:cmd]}"
      end
    rescue ex
      Log.error("Session error: #{ex.message}")
      @client.close rescue nil
    end

    private def handle_connect(req)
      remote = begin
        TCPSocket.new(req[:address], req[:port])
      rescue ex
        Log.error("CONNECT #{req[:address]}:#{req[:port]} — #{ex.message}")
        Protocol::Request.reply(@client, Rep::UNREACHABLE)
        return
      end

      Log.info("CONNECT #{req[:address]}:#{req[:port]}")
      Protocol::Request.reply(@client, Rep::SUCCESS)
      Relay.between(@client, remote, @config.timeout)
    end

    private def handle_bind(req)
      bind_server = TCPServer.new("0.0.0.0", 0)
      local_addr  = bind_server.local_address
      Protocol::Request.reply(@client, Rep::SUCCESS,
                               local_addr.address, local_addr.port)

      remote = bind_server.accept
      bind_server.close

      peer = remote.remote_address
      Log.info("BIND inbound from #{peer}")
      Protocol::Request.reply(@client, Rep::SUCCESS, peer.address, peer.port)

      Relay.between(@client, remote, @config.timeout)
    end

    private def handle_udp_associate(req)
      udp = UDPSocket.new
      begin
        udp.bind("0.0.0.0", 0)
        local_addr = udp.local_address

        Protocol::Request.reply(@client, Rep::SUCCESS,
                                 local_addr.address, local_addr.port)
        Log.info("UDP ASSOCIATE on #{local_addr.address}:#{local_addr.port}")

        spawn Relay.udp(udp, @config.timeout)

        # RFC 1928 §7: UDP association lives as long as this TCP/WS control
        # connection.  Block here until it closes.
        discard = Bytes.new(256)
        loop { break if @client.read(discard) == 0 }
      rescue
      ensure
        udp.close rescue nil
      end
    end
  end

  # ── ReverseClient ────────────────────────────────────────────────────────────
  # Maintains MAX_SESSIONS concurrent outbound WebSocket connections to the
  # controller.  Each worker:
  #   1. Opens a WebSocket to CONTROLLER_HOST:CONTROLLER_PORT/CONTROLLER_PATH
  #   2. Spawns ws.run in a background fiber (processes incoming frames,
  #      fires on_binary/on_close, handles WS-level ping/pong).
  #   3. Wraps the WebSocket in WebSocketIO and hands it to a Session.
  #   4. When the session ends, closes the WebSocket and immediately reconnects.
  #
  # Exponential back-off (2 → 4 → 8 → … → 30 s) prevents thundering-herd
  # reconnects after a controller outage.

  class ReverseClient
    def initialize(@config : Config)
    end

    def start
      Log.info("Reverse SOCKS5 agent — connecting to " \
               "ws://#{@config.cb_host}:#{@config.cb_port}#{@config.cb_path} " \
               "(#{MAX_SESSIONS} concurrent sessions)")

      MAX_SESSIONS.times do |id|
        spawn { worker_loop(id) }
      end

      sleep  # Keep the main fiber (and the process) alive indefinitely.
    end

    private def worker_loop(id : Int32)
      backoff = 2

      loop do
        ws : HTTP::WebSocket? = nil

        begin
          Log.info("[worker #{id}] connecting...")

          ws = HTTP::WebSocket.new(
            host: @config.cb_host,
            path: @config.cb_path,
            port: @config.cb_port,
          )

          ws_io = WebSocketIO.new(ws)

          # ws.run blocks in a loop reading frames and firing callbacks.
          # It must run concurrently with the Session fiber so on_binary
          # can feed data to ws_io.read while Session is blocked waiting
          # for it.  A bare `rescue nil` prevents an abrupt network drop
          # from crashing the spawned fiber silently.
          spawn { ws.run rescue nil }

          Log.info("[worker #{id}] connected — waiting for SOCKS5 session")
          Session.new(ws_io, @config).start

          backoff = 2  # clean session; reset back-off

        rescue ex
          Log.error("[worker #{id}] #{ex.message}")
          sleep(backoff.seconds)
          backoff = Math.min(backoff * 2, 30)

        ensure
          # Close the WebSocket regardless of how we exited.  ws.close is
          # idempotent — safe to call even if Session already closed it.
          ws.try(&.close) rescue nil
        end
      end
    end
  end
end

# ── entry point ───────────────────────────────────────────────────────────────
# Usage: crocks_final [cb_host [cb_port [cb_path [timeout_seconds [verbose]]]]]
# cb_host / cb_port default to the hardcoded CONTROLLER_HOST / CONTROLLER_PORT.
config = Socks::Config.from_args(ARGV)
Socks::ReverseClient.new(config).start






















# controller


#!/usr/bin/env crystal
# controller.cr — reverse-SOCKS5 WebSocket controller
#
# Two listeners:
#   Agent WebSocket  →  ws://AGENT_LISTEN_HOST:AGENT_LISTEN_PORT/rsocks
#   SOCKS5 clients   →  SOCKS5_LISTEN_HOST:SOCKS5_LISTEN_PORT
#
# For each SOCKS5 client, the controller dequeues one idle agent WebSocket
# and bridges the raw TCP byte stream over it.  The agent handles all
# SOCKS5 framing — the controller is a dumb binary bridge.
#
# Fiber model per session:
#
#   HTTP server fiber (owns ws.run after proc returns):
#     ws.run ──on_binary──► writes raw bytes to TCPSocket client
#
#   Spawned fiber (created when client is paired):
#     TCPSocket client ──read──► ws.send ──► agent
#
# No double ws.run: HTTP::WebSocketHandler calls ws.run after the proc
# returns, so the proc must only register callbacks and return quickly.
#
# No callback race: the agent's Session blocks on its first read_byte
# (waiting for the SOCKS5 client greeting) and sends nothing until after
# it receives data.  We register on_binary and spawn the TCP→WS fiber
# before sending anything, so ws.run can never fire on_binary before it
# has been set.

require "http"
require "http/web_socket"
require "socket"
require "time"

AGENT_LISTEN_HOST  = "0.0.0.0"
AGENT_LISTEN_PORT  = 8080
AGENT_PATH         = "/rsocks"
SOCKS5_LISTEN_HOST = "127.0.0.1"
SOCKS5_LISTEN_PORT = 1080

# Capacity: up to 1 000 idle agents queued without back-pressure.
POOL_CAPACITY = 1_000

module Controller
  module Log
    @@mu = Mutex.new

    def self.info(msg)
      @@mu.synchronize { puts "[INFO]  #{Time.local}  #{msg}" }
    end

    def self.error(msg)
      @@mu.synchronize { puts "[ERROR] #{Time.local}  #{msg}" }
    end
  end

  # One slot per connected-but-unassigned agent.
  #
  # `done` is a Channel(Nil) with capacity 1.  It is signalled by on_close
  # so the SOCKS5 client handler knows when the WebSocket has closed and it
  # can clean up the TCP client socket.  Capacity 1 ensures the send never
  # blocks even if the receiver has already exited (e.g. client timed out).
  record AgentSlot, ws : HTTP::WebSocket, done : Channel(Nil)

  # Fallback handler: returns 404 for any non-WebSocket or wrong-path request.
  # Must be a named class that includes HTTP::Handler so it can appear in an
  # Indexable(HTTP::Handler) alongside HTTP::WebSocketHandler.
  class NotFoundHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      context.response.respond_with_status(404)
    end
  end

  # AgentServer: HTTP server that accepts WebSocket connections from agents.
  #
  # The WebSocketHandler proc ONLY registers callbacks and adds the slot to
  # the pool, then returns.  HTTP::WebSocketHandler calls ws.run after the
  # proc, which drives on_binary / on_close / on_ping for the lifetime of
  # the connection.
  class AgentServer
    def initialize(@pool : Channel(AgentSlot))
    end

    def start
      ws_handler = HTTP::WebSocketHandler.new do |ws, ctx|
        # Reject wrong paths before the slot ever enters the pool.
        # ws.close here is safe: the framework's subsequent ws.run sees
        # a closed socket and returns immediately.
        unless ctx.request.path == AGENT_PATH
          ws.close rescue nil
          next
        end

        Log.info("Agent connected")

        done = Channel(Nil).new(1)

        # on_close MUST be set in the proc (before ws.run starts) because
        # the agent can disconnect at any time while idle in the pool.
        ws.on_close do |_code, _msg|
          done.send(nil) rescue nil
          Log.info("Agent disconnected")
        end

        # Crystal's HTTP::WebSocket does not auto-pong; do it manually.
        ws.on_ping { |msg| ws.pong(msg) rescue nil }

        @pool.send(AgentSlot.new(ws, done))
        # Return here — framework calls ws.run.
      end

      server = HTTP::Server.new([ws_handler, NotFoundHandler.new] of HTTP::Handler)
      Log.info("Agent listener on ws://#{AGENT_LISTEN_HOST}:#{AGENT_LISTEN_PORT}#{AGENT_PATH}")
      server.listen(AGENT_LISTEN_HOST, AGENT_LISTEN_PORT)
    end
  end

  # SocksServer: plain TCP server that accepts SOCKS5 clients.
  class SocksServer
    def initialize(@pool : Channel(AgentSlot))
    end

    def start
      server = TCPServer.new(SOCKS5_LISTEN_HOST, SOCKS5_LISTEN_PORT)
      Log.info("SOCKS5 listener on #{SOCKS5_LISTEN_HOST}:#{SOCKS5_LISTEN_PORT}")

      loop do
        client = server.accept
        spawn handle(client)
      end
    end

    private def handle(client : TCPSocket)
      addr = client.remote_address.to_s
      Log.info("SOCKS5 client #{addr} — waiting for agent")

      # Block until an idle agent slot is available.
      slot = @pool.receive

      Log.info("SOCKS5 client #{addr} — assigned to agent, bridging")
      bridge(client, slot, addr)
    rescue ex
      Log.error("SOCKS5 handler #{client.remote_address rescue "?"}: #{ex.message}")
    ensure
      client.close rescue nil
    end

    # Bridge the TCP SOCKS5 client ↔ agent WebSocket.
    #
    # Direction A — TCPSocket → WebSocket (spawned fiber):
    #   Reads raw bytes from the SOCKS5 client and sends them as binary
    #   WebSocket frames to the agent.  On TCP EOF or error, calls ws.close
    #   to signal the agent and let ws.run (in the HTTP server fiber) return.
    #
    # Direction B — WebSocket → TCPSocket (callback, runs in ws.run's fiber):
    #   on_binary is set here, before the spawned fiber sends any data.
    #   Because the agent will not transmit until it has first received the
    #   SOCKS5 handshake bytes, ws.run cannot fire on_binary before we set
    #   it — there is no race.
    #
    # Lifetime: bridge blocks on slot.done.receive, which fires when ws.run
    # exits (via on_close).  This keeps the SOCKS5 client fiber alive for
    # the full session and ensures client.close happens exactly once.
    private def bridge(client : TCPSocket, slot : AgentSlot, addr : String)
      # Direction B: register on_binary BEFORE spawning Direction A so that
      # any response from the agent is never dropped.
      slot.ws.on_binary do |bytes|
        client.write(bytes)
        client.flush
      rescue
        slot.ws.close rescue nil
      end

      # Direction A: TCP → WS (spawned fiber).
      spawn do
        buf = Bytes.new(16384)
        loop do
          n = client.read(buf)
          break if n == 0
          slot.ws.send(buf[0, n])
        end
      rescue
      ensure
        # Closing the WebSocket from this fiber causes ws.run (in the HTTP
        # server fiber) to receive the close frame and return, which fires
        # on_close, which sends to slot.done, unblocking the line below.
        slot.ws.close rescue nil
      end

      # Block until the WebSocket closes (agent session ended or error).
      # slot.done was pre-loaded with nil if the agent disconnected while
      # idle in the pool, so this returns immediately in that case.
      slot.done.receive rescue nil

      Log.info("SOCKS5 client #{addr} — session done")
    end
  end
end

# ── entry point ───────────────────────────────────────────────────────────────
# Usage: controller [agent_port [socks5_port]]
# Ports can also be overridden at compile time by changing the constants above.
pool = Channel(Controller::AgentSlot).new(POOL_CAPACITY)

spawn { Controller::AgentServer.new(pool).start }
Controller::SocksServer.new(pool).start
