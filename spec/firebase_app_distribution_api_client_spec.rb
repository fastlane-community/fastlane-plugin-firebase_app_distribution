describe Fastlane::Client::FirebaseAppDistributionApiClient do
  let(:fake_binary_path) { "binary.apk" }
  let(:fake_binary_contents) { "Hello World" }
  let(:fake_binary) { double("Binary") }
  let(:headers) { { 'Authorization' => 'Bearer auth_token' } }

  let(:api_client) { Fastlane::Client::FirebaseAppDistributionApiClient.new("auth_token") }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:conn) do
    Faraday.new(url: "https://firebaseappdistribution.googleapis.com") do |b|
      Fastlane::Client::FirebaseAppDistributionApiClient.configure_connection(b)
      b.adapter(:test, stubs)
    end
  end

  before(:each) do
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open)
      .with(fake_binary_path, "rb")
      .and_return(fake_binary)

    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?)
      .with(fake_binary_path)
      .and_return(true)

    allow(fake_binary).to receive(:read)
      .and_return(fake_binary_contents)

    allow(api_client).to receive(:connection)
      .and_return(conn)
  end

  after(:each) do
    stubs.verify_stubbed_calls
    Faraday.default_connection = nil
  end

  describe '#get_app' do
    it 'returns an app with appView BASIC' do
      response = {
        projectNumber: "project_number",
        appId: "app_id",
        contactEmail: "user@example.com"
      }
      stubs.get("/v1alpha/apps/app_id?appView=BASIC", headers) do |env|
        [
          200,
          {},
          response
        ]
      end
      app = api_client.get_app("app_id")
      binary_hash = Digest::SHA256.hexdigest(fake_binary_contents)
      expect(app.project_number).to eq("project_number")
      expect(app.app_id).to eq("app_id")
      expect(app.contact_email).to eq("user@example.com")
      expect(app.aab_certificate.empty?).to eq(true)
    end

    it 'returns an app with appView BASIC and aab certificate' do
      response = {
        projectNumber: "project_number",
        appId: "app_id",
        contactEmail: "user@example.com",
        aabCertificate: {
          certificateHashMd5: "md5-cert-hash",
          certificateHashSha1: "sha1-cert-hash",
          certificateHashSha256: "sha256-cert-hash"
        }
      }
      stubs.get("/v1alpha/apps/app_id?appView=BASIC", headers) do |env|
        [
          200,
          {},
          response
        ]
      end
      app = api_client.get_app("app_id")
      binary_hash = Digest::SHA256.hexdigest(fake_binary_contents)
      expect(app.project_number).to eq("project_number")
      expect(app.app_id).to eq("app_id")
      expect(app.contact_email).to eq("user@example.com")
      expect(app.aab_certificate.empty?).to eq(false)
      expect(app.aab_certificate.md5_certificate_hash).to eq("md5-cert-hash")
      expect(app.aab_certificate.sha1_certificate_hash).to eq("sha1-cert-hash")
      expect(app.aab_certificate.sha256_certificate_hash).to eq("sha256-cert-hash")
    end

    it 'returns an app with appView FULL' do
      response = {
        projectNumber: "project_number",
        appId: "app_id",
        contactEmail: "user@example.com",
        aabState: "ACTIVE"
      }
      stubs.get("/v1alpha/apps/app_id?appView=FULL", headers) do |env|
        [
          200,
          {},
          response
        ]
      end
      app = api_client.get_app("app_id", "FULL")
      binary_hash = Digest::SHA256.hexdigest(fake_binary_contents)
      expect(app.project_number).to eq("project_number")
      expect(app.app_id).to eq("app_id")
      expect(app.contact_email).to eq("user@example.com")
      expect(app.aab_state).to eq("ACTIVE")
    end
  end

  describe '#upload_binary' do
    let(:upload_headers) do
      { 'Authorization' => 'Bearer auth_token',
      'X-APP-DISTRO-API-CLIENT-ID' => 'fastlane',
      'X-APP-DISTRO-API-CLIENT-TYPE' =>  "android",
      'X-APP-DISTRO-API-CLIENT-VERSION' => Fastlane::FirebaseAppDistribution::VERSION,
      'X-GOOG-UPLOAD-FILE-NAME' => File.basename(fake_binary_path),
      'X-GOOG-UPLOAD-PROTOCOL' => 'raw' }
    end
    it 'uploads the binary successfully when the input is valid' do
      stubs.post("/app-binary-uploads?app_id=app_id", fake_binary_contents, upload_headers) do |env|
        [
          202,
          {},
          {
            token: "projects/project_id/apps/app_id/releases/-/binaries/binary_hash"
          }
        ]
      end
      api_client.upload_binary("app_id", fake_binary_path, "android")
    end

    it 'crashes when given an invalid binary_path' do
      expect(File).to receive(:open)
        .with("invalid_binary.apk", "rb")
        .and_raise(Errno::ENOENT.new("file not found"))
      expect { api_client.upload_binary("app_id", "invalid_binary.apk", "android") }
        .to raise_error("#{ErrorMessage.binary_not_found('APK')}: invalid_binary.apk")
    end

    it 'retries if a server error occurs' do
      responses = [
        [
          500,
          {},
          "Server Error"
        ],
        [
          202,
          {},
          {
            token: "projects/project_id/apps/app_id/releases/-/binaries/binary_hash"
          }
        ]
      ]
      stubs.post("/app-binary-uploads?app_id=app_id", fake_binary_contents, upload_headers) do |env|
        responses.shift
      end
      api_client.upload_binary("app_id", fake_binary_path, "android")
      expect(responses).to be_empty, "the upload should have been retried after the initial failure"
    end
  end

  describe '#upload' do
    let(:upload_status_response_success) do
      UploadStatusResponse.new(
        { status: "SUCCESS",
          release: { id: "release_id" } }
      )
    end
    let(:upload_status_response_in_progress) do
      UploadStatusResponse.new(
        { status: "IN_PROGRESS",
          release: {} }
      )
    end
    let(:upload_status_response_error) do
      UploadStatusResponse.new(
        { status: "ERROR",
          release: {},
          message: "There was an error." }
      )
    end
    let(:upload_status_response_status_unspecified) do
      UploadStatusResponse.new(
        { status: "STATUS_UNSPECIFIED",
          release: {} }
      )
    end
    let(:upload_token) do
      CGI.escape("projects/project_number/apps/app_id/releases/-/binaries/#{Digest::SHA256.hexdigest(fake_binary_contents)}")
    end

    before(:each) do
      # Stub out polling interval for quick specs
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::POLLING_INTERVAL_SECONDS", 0)
    end

    it 'skips the upload step if the binary has already been uploaded' do
      # upload should not attempt to upload the binary at all
      expect(api_client).to_not(receive(:upload_binary))
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_success)

      release_id = api_client.upload("project_number", "app_id", fake_binary_path, "android")
      expect(release_id).to eq("release_id")
    end

    it 'uploads the app binary then returns the release_id' do
      # return an error then a success after being uploaded
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_error, upload_status_response_success)

      # upload_binary should only be called once
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path, "android")
        .at_most(:once)

      release_id = api_client.upload("project_number", "app_id", fake_binary_path, "android")
      expect(release_id).to eq("release_id")
    end

    it 'raises an error after polling MAX_POLLING_RETRIES times' do
      max_polling_retries = 2
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::MAX_POLLING_RETRIES", max_polling_retries)

      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_error)
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path, "android")
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_in_progress)
        .exactly(max_polling_retries).times

      expect do
        api_client.upload("project_number", "app_id", fake_binary_path, "android")
      end.to raise_error
    end

    it 'uploads the app binary once then polls until success' do
      max_polling_retries = 3
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::MAX_POLLING_RETRIES", max_polling_retries)

      # return error the first time
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_error)
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path, "android")
        .at_most(:once)
      # return in_progress for a couple polls
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_in_progress)
        .exactly(2).times
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_success)

      release_id = api_client.upload("project_number", "app_id", fake_binary_path, "android")
      expect(release_id).to eq("release_id")
    end

    it 'crashes after failing to upload with status error' do
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_error).twice
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path, "android")

      expect { api_client.upload("project_number", "app_id", fake_binary_path, "android") }
        .to raise_error("#{ErrorMessage.upload_binary_error('APK')}: #{upload_status_response_error.message}")
    end

    it 'crashes after failing to upload with status unspecified' do
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_status_unspecified).twice
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path, "android")

      expect { api_client.upload("project_number", "app_id", fake_binary_path, "android") }
        .to raise_error(ErrorMessage.upload_binary_error("APK"))
    end

    it 'does not call upload when the intial check returns in progress' do
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_in_progress)
      expect(api_client).to_not(receive(:upload_binary))
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", upload_token)
        .and_return(upload_status_response_success)

      release_id = api_client.upload("project_number", "app_id", fake_binary_path, "android")
      expect(release_id).to eq("release_id")
    end
  end

  describe '#post_notes' do
    let(:release_notes)  { "{\"releaseNotes\":{\"releaseNotes\":\"release_notes\"}}" }

    it 'post call is successfull when input is valid' do
      stubs.post("/v1alpha/apps/app_id/releases/release_id/notes", release_notes, headers) do |env|
        [
          200,
          {},
          {}
        ]
      end
      api_client.post_notes("app_id", "release_id", "release_notes")
    end

    it 'skips posting when release_notes is empty' do
      expect(conn).to_not(receive(:post))
      api_client.post_notes("app_id", "release_id", "")
    end

    it 'skips posting when release_notes is nil' do
      expect(conn).to_not(receive(:post))
      api_client.post_notes("app_id", "release_id", nil)
    end

    it 'raises a user error when a client error is returned' do
      stubs.post("/v1alpha/apps/app_id/releases/release_id/notes", release_notes, headers) do |env|
        [
          400,
          {},
          { error: { message: "client error response message" } }.to_json
        ]
      end
      expect { api_client.post_notes("app_id", "release_id", "release_notes") }
        .to raise_error("#{ErrorMessage::INVALID_RELEASE_NOTES}: client error response message")
    end

    # BUG: 500 errors causes a ClientError locally but ServerError on CircleCI specs, causing this test to be flaky.
    # it 'crashes when given an invalid release_id' do
    #   stubs.post("/v1alpha/apps/invalid_app_id/releases/invalid_release_id/notes", release_notes, headers) do |env|
    #     [
    #       500,
    #       {},
    #       {}
    #     ]
    #   end
    #   expect { api_client.post_notes("invalid_app_id", "invalid_release_id", "release_notes") }
    #     .to raise_error("#{ErrorMessage::INVALID_RELEASE_ID}: invalid_release_id")
    # end
  end

  describe '#upload_status' do
    it 'returns the proper status when the get call is successfull' do
      stubs.get("/v1alpha/apps/app_id/upload_status/app_token", headers) do |env|
        [
          200,
          {},
          { status: "SUCCESS" }
        ]
      end
      status = api_client.get_upload_status("app_id", "app_token")
      expect(status.success?).to eq(true)
    end
  end

  describe '#get_udids' do
    let(:udids) do
      [
        { udid: 'device-udid-1', name: 'device-name-1', platform: 'ios' },
        { udid: 'device-udid-1', name: 'device-name-1', platform: 'ios' }
      ]
    end

    it 'returns the list of UDIDs when the get call is successfull' do
      stubs.get("/v1alpha/apps/app_id/testers:getTesterUdids", headers) do |env|
        [
          200,
          {},
          { testerUdids: udids }
        ]
      end
      result = api_client.get_udids("app_id")
      expect(result).to eq(udids)
    end

    it 'returns an empty list UDIDs when there are no udids' do
      stubs.get("/v1alpha/apps/app_id/testers:getTesterUdids", headers) do |env|
        [
          200,
          {},
          {}
        ]
      end
      result = api_client.get_udids("app_id")
      expect(result).to eq([])
    end
  end

  describe '#enable_access' do
    it 'posts successfully when tester emails and groupIds are defined' do
      payload = { emails: ["testers"], groupIds: ["groups"] }
      stubs.post("/v1alpha/apps/app_id/releases/release_id/enable_access", payload.to_json, headers) do |env|
        [
          202,
          {},
          {}
        ]
      end
      api_client.enable_access("app_id", "release_id", ["testers"], ["groups"])
    end

    it 'posts when groupIds are defined and tester emails is nil' do
      payload = { emails: nil, groupIds: ["groups"] }
      stubs.post("/v1alpha/apps/app_id/releases/release_id/enable_access", payload.to_json, headers) do |env|
        [
          202,
          {},
          {}
        ]
      end
      api_client.enable_access("app_id", "release_id", nil, ["groups"])
    end

    it 'posts when tester emails are defined and groupIds is nil' do
      payload = { emails: ["testers"], groupIds: nil }
      stubs.post("/v1alpha/apps/app_id/releases/release_id/enable_access", payload.to_json, headers) do |env|
        [
          202,
          {},
          {}
        ]
      end
      api_client.enable_access("app_id", "release_id", ["testers"], nil)
    end

    it 'skips posting if testers and groups are nil' do
      expect(conn).to_not(receive(:post))
      api_client.enable_access("app_id", "release_id", nil, nil)
    end

    it 'skips posting if testers and groups are empty' do
      expect(conn).to_not(receive(:post))
      api_client.enable_access("app_id", "release_id", [], [])
    end

    it 'raises a user eror when a client error is returned' do
      emails = ["invalid_tester_email"]
      group_ids = ["invalid_group_id"]
      payload = { emails: emails, groupIds: group_ids }
      stubs.post("/v1alpha/apps/app_id/releases/release_id/enable_access", payload.to_json) do |env|
        [
          400,
          {},
          {}
        ]
      end
      expect { api_client.enable_access("app_id", "release_id", emails, group_ids) }
        .to raise_error("#{ErrorMessage::INVALID_TESTERS} \nEmails: #{emails} \nGroups: #{group_ids}")
    end
  end
end
