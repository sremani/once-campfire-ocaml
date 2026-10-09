#!/usr/bin/env ruby
# Run the pinned shared verification route contracts and acknowledged-write audit.
# The only credential is read inside this disposable container from the pinned
# test fixture; neither stdout nor generated JSON contains it.
require "digest"
require "json"
require "net/http"
require "uri"
require "cgi"
require_relative "/verify/bench/contracts"
require_relative "/verify/bench/validate_acks"

base, database, labels_path, manifest_path, sessions_path, destination = ARGV
abort "six arguments required" unless destination
labels = JSON.parse(File.read(labels_path))
manifest = JSON.parse(File.read(manifest_path))
cookie = JSON.parse(File.read(sessions_path)).fetch("sessions").first.fetch("cookie_header")
css = "/assets/" + manifest.fetch("_reset.css").fetch("digested_path")
FileUtils.mkdir_p(destination)
uri = URI(base)

def sql(database, query)
  output, error, status = Open3.capture3("sqlite3", "-cmd", ".timeout 10000", "-readonly", "-json", database, query)
  raise "SQLite query failed: #{error}" unless status.success?
  output.strip.empty? ? [] : JSON.parse(output)
end

result = { "source" => "once-campfire-verification@6f71d70b5e1f17507404ad06cac134aa453a04a6" }
begin
  prepared = BenchmarkContracts.prepare(base, cookie, database, labels, css, File.join(destination, "contracts"))
  result["preflight"] = prepared.fetch(:preflight)
  result["route_contracts"] = prepared.fetch(:contracts).keys
  result["route_contracts_status"] = "pass"
rescue StandardError => error
  result["route_contracts_status"] = "fail"
  result["route_contracts_error"] = error.message.gsub(cookie, "<fixture cookie>")[0, 300]
end

begin
  room = Integer(labels.fetch("rooms.hq"))
  initial = sql(database, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{room}").first.fetch("n")
  page = Net::HTTP.new(uri.host, uri.port, nil).start do |http|
    http.get("/rooms/#{room}", "Cookie" => cookie, "Accept-Encoding" => "identity")
  end
  raise "write room inaccessible" unless page.code == "200" && page.body.include?("</html>")
  write_targets = page.body.scan(/id="(messages_[^"]+)"/).flatten.select do |id|
    id.match?(/\Amessages_(?:rooms_[a-z]+|room)_#{room}\z/)
  end
  raise "missing or ambiguous write-room DOM target" unless write_targets.size == 1
  csrf = page.body[/<meta name="csrf-token" content="([^"]*)"/, 1].to_s
  token = "bench write #{Digest::SHA256.hexdigest("m8-t2-#{base}")[0, 24]}"
  form = URI.encode_www_form("message[body]" => token,
                             "message[client_message_id]" => "m8t2#{Digest::SHA256.hexdigest(base)[0, 16]}",
                             "authenticity_token" => csrf)
  post = Net::HTTP::Post.new("/rooms/#{room}/messages")
  post["Cookie"] = cookie
  post["Content-Type"] = "application/x-www-form-urlencoded"
  post["Accept"] = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
  post["X-CSRF-Token"] = csrf
  post["Origin"] = base
  post["Sec-Fetch-Site"] = "same-origin"
  post.body = form
  response = Net::HTTP.new(uri.host, uri.port, nil).start { |http| http.request(post) }
  body = response.body
  contract = if result["route_contracts_status"] == "pass"
    JSON.parse(File.read(prepared.fetch(:contracts).fetch("post_message")))
  else
    { "kind" => "post_message", "content_type" => "text/vnd.turbo-stream.html",
      "required" => ["action=\"append\"", "target=\"#{write_targets.first}\""] }
  end
  ids = body.scan(/data-message-id="(\d+)"/).flatten.map(&:to_i)
  valid = response.code == "200" && response["content-type"].to_s.start_with?(contract.fetch("content_type")) &&
          body.start_with?("<turbo-stream") && body.rstrip.end_with?("</turbo-stream>") &&
          contract.fetch("required").all? { |marker| body.include?(marker) } &&
          body.include?(token) && ids.size == 1
  result["write_status"] = response.code.to_i
  result["write_response_valid"] = valid
  result["write_body_sha256"] = Digest::SHA256.hexdigest(body)
  result["write_message_ids"] = ids
  if valid
    audit = File.join(destination, "acknowledged.jsonl")
    File.write(audit, JSON.generate({ id: ids.first, token: token }) + "\n")
    result["acknowledged_write"] = AcknowledgedWrites.verify(database, room, [audit], 1)
  else
    result["acknowledged_write"] = { "verified" => false }
  end
  final = sql(database, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{room}").first.fetch("n")
  result["persisted_message_delta"] = final - initial
  result["integrity_check"] = sql(database, "PRAGMA integrity_check;").first.values.first
rescue StandardError => error
  result["acknowledged_write"] = { "verified" => false }
  result["write_error"] = error.message.gsub(cookie, "<fixture cookie>")[0, 300]
end

File.write(File.join(destination, "result.json"), JSON.pretty_generate(result) + "\n")
puts JSON.generate(result.reject { |key, _| key == "preflight" })
exit(result["route_contracts_status"] == "pass" && result.dig("acknowledged_write", "verified") &&
     result["persisted_message_delta"] == 1 && result["integrity_check"] == "ok" ? 0 : 1)
