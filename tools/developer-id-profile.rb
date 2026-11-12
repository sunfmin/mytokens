#!/usr/bin/env ruby
# The Developer ID provisioning profile the release archive signs with in GitHub
# Actions (ADR-0017): an active MAC_APP_DIRECT profile of BUNDLE_ID that carries
# the Developer ID Application certificate in KEYCHAIN, found through the App
# Store Connect API, or made there when none does. It is installed where Xcode
# looks for profiles, and its UUID is printed. The API key is read from
# ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64 and never written to disk or
# printed.
#   tools/developer-id-profile.rb KEYCHAIN BUNDLE_ID
require 'openssl'
require 'base64'
require 'json'
require 'net/http'
require 'fileutils'

keychain, bundle = ARGV
abort 'usage: tools/developer-id-profile.rb KEYCHAIN BUNDLE_ID' unless keychain && bundle
%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64].each { |v| abort "developer-id-profile: #{v} is not set" if ENV[v].to_s.empty? }

pem = IO.popen(['security', 'find-certificate', '-c', 'Developer ID Application', '-p', keychain], &:read)
abort "developer-id-profile: no Developer ID Application certificate in #{keychain}" if pem.empty?
serial = OpenSSL::X509::Certificate.new(pem).serial.to_s(16).upcase.sub(/\A0+/, '')

key = OpenSSL::PKey::EC.new(Base64.decode64(ENV['ASC_KEY_P8_BASE64']))
b64 = ->(s) { Base64.urlsafe_encode64(s).delete('=') }
now = Time.now.to_i
input = b64.(JSON.dump(alg: 'ES256', kid: ENV['ASC_KEY_ID'], typ: 'JWT')) + '.' +
        b64.(JSON.dump(iss: ENV['ASC_ISSUER_ID'], iat: now, exp: now + 900, aud: 'appstoreconnect-v1'))
r, s = OpenSSL::ASN1.decode(key.sign('SHA256', input)).value.map { |i| i.value.to_s(2).rjust(32, "\0")[-32, 32] }
JWT = input + '.' + b64.(r + s)

def api(method, path, body = nil)
  u = URI("https://api.appstoreconnect.apple.com#{path}")
  req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(u)
  req['Authorization'] = "Bearer #{JWT}"
  if body
    req['Content-Type'] = 'application/json'
    req.body = JSON.dump(body)
  end
  res = Net::HTTP.start(u.host, u.port, use_ssl: true) { |h| h.request(req) }
  abort "developer-id-profile: #{method.upcase} #{u.path} answered #{res.code}" unless res.code.start_with?('2')
  JSON.parse(res.body)
end

norm = ->(sn) { sn.to_s.upcase.sub(/\A0+/, '') }
bundle_id = api(:get, "/v1/bundleIds?filter[identifier]=#{bundle}&limit=200")['data']
            .find { |b| b['attributes']['identifier'] == bundle }
abort "developer-id-profile: no bundle ID #{bundle} on the team" unless bundle_id
cert = api(:get, '/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION&limit=200')['data']
       .find { |c| norm.(c['attributes']['serialNumber']) == serial }
abort 'developer-id-profile: the keychain\'s Developer ID certificate is not on the team' unless cert

profile = api(:get, "/v1/bundleIds/#{bundle_id['id']}/profiles?limit=200")['data']
          .select { |p| p['attributes']['profileType'] == 'MAC_APP_DIRECT' && p['attributes']['profileState'] == 'ACTIVE' }
          .map { |p| api(:get, "/v1/profiles/#{p['id']}?include=certificates&limit[certificates]=50")['data'] }
          .find { |p| (p.dig('relationships', 'certificates', 'data') || []).any? { |c| c['id'] == cert['id'] } }
if profile
  warn "developer-id-profile: using #{profile['attributes']['name']}"
else
  name = "#{bundle} Developer ID #{cert['attributes']['serialNumber']}"
  profile = api(:post, '/v1/profiles', data: {
    type: 'profiles',
    attributes: { name: name, profileType: 'MAC_APP_DIRECT' },
    relationships: {
      bundleId: { data: { type: 'bundleIds', id: bundle_id['id'] } },
      certificates: { data: [{ type: 'certificates', id: cert['id'] }] }
    }
  })['data']
  warn "developer-id-profile: made #{name}"
end

uuid = profile['attributes']['uuid']
content = Base64.decode64(profile['attributes']['profileContent'])
[File.expand_path('~/Library/MobileDevice/Provisioning Profiles'),
 File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles')].each do |dir|
  FileUtils.mkdir_p(dir)
  File.binwrite(File.join(dir, "#{uuid}.provisionprofile"), content)
end
puts uuid
