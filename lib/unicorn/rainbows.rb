require 'unicorn'
require 'revactor'

# :stopdoc:
module Unicorn

  # People get the impression that we're a big bad, old-school
  # Unix server and then we start talking about Rainbows...
  class Rainbows < HttpServer
    DEFAULTS = HttpRequest::DEFAULTS.merge({
      # we need to observe many of the rules for thread-safety with Revactor
      "rack.multithread" => true,
      "SERVER_SOFTWARE" => "Unicorn Rainbows! #{Const::UNICORN_VERSION}",
    })

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client)
      env = {}
      remote_addr = client.remote_addr
      hp = HttpParser.new
      buf = client.read

      begin
        while ! hp.headers(env, buf)
          buf << client.read
        end

        env[Const::REMOTE_ADDR] = remote_addr
        env[Const::RACK_INPUT] = 0 == hp.content_length ?
                 HttpRequest::NULL_IO : TeeInput.new(client, env, hp, buf)
        response = app.call(env.update(DEFAULTS))

        if 100 == response.first.to_i
          client.write(Const::EXPECT_100_RESPONSE)
          env.delete(Const::HTTP_EXPECT)
          response = app.call(env)
        end
        HttpResponse.write(client, response, hp.keepalive?)
      end while hp.keepalive? and hp.reset.nil? and env.clear
      client.close
    # if we get any error, try to write something back to the client
    # assuming we haven't closed the socket, but don't get hung up
    # if the socket is already closed or broken.  We'll always ensure
    # the socket is closed at the end of this function
    rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
      emergency_response(client, Const::ERROR_500_RESPONSE)
    rescue HttpParserError # try to tell the client they're bad
      emergency_response(client, Const::ERROR_400_RESPONSE)
    rescue Object => e
      emergency_response(client, Const::ERROR_500_RESPONSE)
      logger.error "Read error: #{e.inspect}"
      logger.error e.backtrace.join("\n")
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      ppid = master_pid
      init_worker_process(worker)
      alive = worker.tmp # tmp is our lifeline to the master process

      trap(:USR1) { reopen_worker_logs(worker.nr) }
      trap(:QUIT) { alive = false; LISTENERS.each { |s| s.close rescue nil } }
      [:TERM, :INT].each { |sig| trap(sig) { exit!(0) } } # instant shutdown

      Actor.current.trap_exit = true

      listeners = LISTENERS.map { |s|
        TCPServer === s ? Revactor::TCP.listen(s, nil) : nil
      }
      listeners.compact!

      logger.info "worker=#{worker.nr} ready with Rainbows"
      clients = []

      listeners.map! do |s|
        Actor.spawn(s) do |l|
          begin
            clients << Actor.spawn(l.accept) { |s| process_client(s) }
          rescue Errno::EAGAIN, Errno::ECONNABORTED
          rescue Object => e
            if alive
              logger.error "Unhandled listen loop exception #{e.inspect}."
              logger.error e.backtrace.join("\n")
            end
          end while alive
        end
      end

      nr = 0
      begin
        Actor.sleep 1
        clients.delete_if { |a| a.dead? }
        if alive
          alive.chmod(nr = 0 == nr ? 1 : 0)
          ppid == Process.ppid or alive = false
        end
      end while alive || ! clients.empty?
    end

  private

    # write a response without caring if it went out or not
    # This is in the case of untrappable errors
    def emergency_response(client, response_str)
      client.instance_eval { @_io.write_nonblock(response_str) rescue nil }
      client.close rescue nil
    end

  end
end

if $0 == __FILE__
  app = lambda { |env|
    if /\A100-continue\z/i =~ env['HTTP_EXPECT']
      return [ 100, {}, [] ]
    end
    env['REQUEST_URI'] =~ %r{^/sleep/(\d+(?:\.\d*)?)} and Actor.sleep($1.to_f)
    digest = Digest::SHA1.new
    input = env['rack.input']
    buf = Unicorn::Z.dup
    while buf = input.read(16384, buf)
      digest.update(buf)
    end
    body = env.inspect << "\n"
    header = {
      'X-SHA1' => digest.hexdigest,
      'Content-Length' => body.size.to_s,
      'Content-Type' => 'text/plain',
    }
    [ 200, header, [ body ] ]
  }
  options = {
    :listeners => %w(0.0.0.0:8080 0.0.0.0:8090),
  }
  Unicorn::Rainbows.new(app, options).start.join
end