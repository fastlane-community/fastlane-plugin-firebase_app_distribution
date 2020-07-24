describe Fastlane::Client::FirebaseAppDistributionApiClient do
  let(:fake_binary_path) { "binary_path" }
  let(:fake_binary_contents) { "Hello World" }
  let(:fake_binary) { double("Binary") }
  let(:headers) { { 'Authorization' => 'Bearer auth_token' } }

  let(:api_client) { Fastlane::Client::FirebaseAppDistributionApiClient.new("auth_token") }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:conn) do
    Faraday.new(url: "https://firebaseappdistribution.googleapis.com") do |b|
      b.response(:json, parser_options: { symbolize_names: true })
      b.response(:raise_error)
      b.adapter(:test, stubs)
    end
  end

  before(:each) do
    allow(File).to receive(:open)
      .with(fake_binary_path)
      .and_return(fake_binary)

    allow(fake_binary).to receive(:read)
      .and_return(fake_binary_contents)

    allow(api_client).to receive(:connection)
      .and_return(conn)
  end

  after(:each) do
    stubs.verify_stubbed_calls
    Faraday.default_connection = nil
  end

  describe '#get_upload_token' do
    it 'returns the upload token after a successfull GET call' do
      stubs.get("/v1alpha/apps/app_id", headers) do |env|
        [
          200,
          {},
          {
            projectNumber: "project_number",
            appId: "app_id",
            contactEmail: "Hello@world.com"
          }
        ]
      end
      upload_token = api_client.get_upload_token("app_id", fake_binary_path)
      binary_hash = Digest::SHA256.hexdigest(fake_binary_contents)
      expect(upload_token).to eq(CGI.escape("projects/project_number/apps/app_id/releases/-/binaries/#{binary_hash}"))
    end

    it 'crash if the app has no contact email' do
      stubs.get("/v1alpha/apps/app_id", headers) do |env|
        [
          200,
          {},
          {
            projectNumber: "project_number",
            appId: "app_id",
            contactEmail: ""
          }
        ]
      end
      expect { api_client.get_upload_token("app_id", fake_binary_path) }
        .to raise_error(ErrorMessage::GET_APP_NO_CONTACT_EMAIL_ERROR)
    end

    it 'crashes when given an invalid app_id' do
      stubs.get("/v1alpha/apps/invalid_app_id", headers) do |env|
        [
          404,
          {},
          {}
        ]
      end
      expect { api_client.get_upload_token("invalid_app_id", fake_binary_path) }
        .to raise_error("#{ErrorMessage::INVALID_APP_ID}: invalid_app_id")
    end

    it 'crashes when given an invalid binary_path' do
      expect(File).to receive(:open)
        .with("invalid_binary_path")
        .and_raise(Errno::ENOENT.new("file not found"))
      expect { api_client.get_upload_token("app_id", "invalid_binary_path") }
        .to raise_error("#{ErrorMessage::APK_NOT_FOUND}: invalid_binary_path")
    end
  end

  describe '#upload_binary' do
    it 'uploads the binary successfully when the input is valid' do
      stubs.post("/app-binary-uploads?app_id=app_id", fake_binary_contents, headers) do |env|
        [
          202,
          {},
          {
            token: "projects/project_id/apps/app_id/releases/-/binaries/binary_hash"
          }
        ]
      end
      api_client.upload_binary("app_id", fake_binary_path)
    end

    it 'should crash if given an invalid app_id' do
      stubs.post("/app-binary-uploads?app_id=invalid_app_id", fake_binary_contents, headers) do |env|
        [
          404,
          {},
          {}
        ]
      end
      expect { api_client.upload_binary("invalid_app_id", fake_binary_path) }
        .to raise_error("#{ErrorMessage::INVALID_APP_ID}: invalid_app_id")
    end

    it 'crashes when given an invalid binary_path' do
      expect(File).to receive(:open)
        .with("invalid_binary_path")
        .and_raise(Errno::ENOENT.new("file not found"))
      expect { api_client.upload_binary("app_id", "invalid_binary_path") }
        .to raise_error("#{ErrorMessage::APK_NOT_FOUND}: invalid_binary_path")
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
          release: {} }
      )
    end

    before(:each) do
      # Stub out polling interval for quick specs
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::POLLING_INTERVAL_SECONDS", 0)

      # Expect a call to get_upload_token every time
      expect(api_client).to receive(:get_upload_token)
        .with("app_id", fake_binary_path)
        .and_return("upload_token")
    end

    it 'skips the upload step if the binary has already been uploaded' do
      # upload should not attempt to upload the binary at all
      expect(api_client).to_not(receive(:upload_binary))
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_success)

      release_id = api_client.upload("app_id", fake_binary_path)
      expect(release_id).to eq("release_id")
    end

    it 'uploads the app binary then returns the release_id' do
      # return an error then a success after being uploaded
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_error, upload_status_response_success)

      # upload_binary should only be called once
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path)
        .at_most(:once)

      release_id = api_client.upload("app_id", fake_binary_path)
      expect(release_id).to eq("release_id")
    end

    it 'polls MAX_POLLING_RETRIES times' do
      max_polling_retries = 2
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::MAX_POLLING_RETRIES", max_polling_retries)

      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_error)
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path)
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_in_progress)
        .exactly(max_polling_retries).times

      release_id = api_client.upload("app_id", fake_binary_path)
      expect(release_id).to be_nil
    end

    it 'uploads the app binary once then polls until success' do
      max_polling_retries = 3
      stub_const("Fastlane::Client::FirebaseAppDistributionApiClient::MAX_POLLING_RETRIES", max_polling_retries)

      # return error the first time
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_error)
      expect(api_client).to receive(:upload_binary)
        .with("app_id", fake_binary_path)
        .at_most(:once)
      # return in_progress for a couple polls
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_in_progress)
        .exactly(2).times
      expect(api_client).to receive(:get_upload_status)
        .with("app_id", "upload_token")
        .and_return(upload_status_response_success)

      release_id = api_client.upload("app_id", fake_binary_path)
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

    it 'crashes when given an invalid app_id' do
      stubs.post("/v1alpha/apps/invalid_app_id/releases/release_id/notes", release_notes, headers) do |env|
        [
          404,
          {},
          {}
        ]
      end
      expect { api_client.post_notes("invalid_app_id", "release_id", "release_notes") }
        .to raise_error("#{ErrorMessage::INVALID_APP_ID}: invalid_app_id")
    end

    it 'crashes when given an invalid release_id' do
      stubs.post("/v1alpha/apps/invalid_app_id/releases/invalid_release_id/notes", release_notes, headers) do |env|
        [
          500,
          {},
          {}
        ]
      end
      expect { api_client.post_notes("invalid_app_id", "invalid_release_id", "release_notes") }
        .to raise_error("#{ErrorMessage::INVALID_RELEASE_ID}: invalid_release_id")
    end
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

    it 'crashes when given an invalid app_id' do
      stubs.get("/v1alpha/apps/invalid_app_id/upload_status/app_token", headers) do |env|
        [
          404,
          {},
          {}
        ]
      end
      expect { api_client.get_upload_status("invalid_app_id", "app_token") }
        .to raise_error("#{ErrorMessage::INVALID_APP_ID}: invalid_app_id")
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

    it 'posts when group_ids are defined and tester emails is nil' do
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

    it 'posts when tester emails are defined and group_ids is nil' do
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

    it 'crashes when given an invalid app_id' do
      payload = { emails: ["testers"], groupIds: ["groups"] }
      stubs.post("/v1alpha/apps/invalid_app_id/releases/release_id/enable_access", payload.to_json) do |env|
        [
          404,
          {},
          {}
        ]
      end
      expect { api_client.enable_access("invalid_app_id", "release_id", ["testers"], ["groups"]) }
        .to raise_error("#{ErrorMessage::INVALID_APP_ID}: invalid_app_id")
    end

    it 'crashes when given an invalid group_id' do
      emails = ["testers"]
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

    it 'crashes when given an invalid email' do
      emails = ["invalid_tester"]
      group_ids = ["groups"]
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
