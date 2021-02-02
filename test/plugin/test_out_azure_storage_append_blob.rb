require 'helper'
require 'fluent/plugin/out_azure-storage-append-blob.rb'
require 'azure/core/http/http_response'
require 'azure/core/http/http_error'

include Fluent::Test::Helpers

class AzureStorageAppendBlobOutTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  CONFIG = %(
    azure_cloud AZUREGERMANCLOUD
    azure_storage_account test_storage_account
    azure_storage_access_key MY_FAKE_SECRET
    azure_container test_container
    time_slice_format        %Y%m%d-%H
    path log
  ).freeze

  CONNSTR_CONFIG = %(
    azure_storage_connection_string https://test
    time_slice_format        %Y%m%d-%H
    path log
  ).freeze

  MSI_CONFIG = %(
    azure_storage_account test_storage_account
    azure_container test_container
    azure_imds_api_version 1970-01-01
    azure_token_refresh_interval 120
    time_slice_format        %Y%m%d-%H
    path log
  ).freeze

  def create_driver(conf: CONFIG, service: nil)
    d = Fluent::Test::Driver::Output.new(Fluent::Plugin::AzureStorageAppendBlobOut).configure(conf)
    d.instance.instance_variable_set(:@bs, service)
    d.instance.instance_variable_set(:@azure_storage_path, 'storage_path')
    d
  end

  sub_test_case 'test config' do
    test 'config should reject with no azure container' do
      assert_raise Fluent::ConfigError do
        create_driver conf: %(
          azure_storage_account test_storage_account
          azure_storage_access_key MY_FAKE_SECRET
          time_slice_format        %Y%m%d-%H
          time_slice_wait          10m
          path log
        )
      end
    end

    test 'config with access key should set instance variables' do
      d = create_driver
      assert_equal 'core.cloudapi.de', d.instance.instance_variable_get(:@azure_storage_dns_suffix)
      assert_equal 'test_storage_account', d.instance.azure_storage_account
      assert_equal 'MY_FAKE_SECRET', d.instance.azure_storage_access_key
      assert_equal 'test_container', d.instance.azure_container
      assert_equal true, d.instance.auto_create_container
      assert_equal '%{path}%{time_slice}-%{index}.log', d.instance.azure_object_key_format
    end

    test 'config with managed identity enabled should set instance variables' do
      d = create_driver conf: MSI_CONFIG
      assert_equal 'test_storage_account', d.instance.azure_storage_account
      assert_equal 'test_container', d.instance.azure_container
      assert_equal true, d.instance.instance_variable_get(:@use_msi)
      assert_equal true, d.instance.auto_create_container
      assert_equal '%{path}%{time_slice}-%{index}.log', d.instance.azure_object_key_format
      assert_equal 120, d.instance.azure_token_refresh_interval
      assert_equal '1970-01-01', d.instance.azure_imds_api_version
    end

    test 'config with connection string should set instance variables' do
      d = create_driver conf: CONNSTR_CONFIG
      assert_equal 'https://test', d.instance.azure_storage_connection_string
      assert_equal false, d.instance.instance_variable_get(:@use_msi)
      assert_equal true, d.instance.auto_create_container
    end
  end

  sub_test_case 'test path slicing' do
    test 'test path_slicing' do
      config = CONFIG.clone.gsub(/path\slog/, 'path log/%Y/%m/%d')
      d = create_driver conf: config
      path_slicer = d.instance.instance_variable_get(:@path_slicer)
      path = d.instance.instance_variable_get(:@path)
      slice = path_slicer.call(path)
      assert_equal slice, Time.now.utc.strftime('log/%Y/%m/%d')
    end

    test 'path slicing utc' do
      config = CONFIG.clone.gsub(/path\slog/, 'path log/%Y/%m/%d')
      config << "\nutc\n"
      d = create_driver conf: config
      path_slicer = d.instance.instance_variable_get(:@path_slicer)
      path = d.instance.instance_variable_get(:@path)
      slice = path_slicer.call(path)
      assert_equal slice, Time.now.utc.strftime('log/%Y/%m/%d')
    end
  end

  # This class is used to create an Azure::Core::Http::HTTPError. HTTPError parses
  # a response object when it is created.
  class FakeResponse
    def initialize(status = 404)
      @status = status
      @body = 'body'
      @headers = {}
    end

    attr_reader :status, :body, :headers
  end

  # This class is used to test plugin functions which interact with the blob service
  class FakeBlobService
    def initialize(status)
      @response = Azure::Core::Http::HttpResponse.new(FakeResponse.new(status))
      @blocks = []
    end
    attr_reader :blocks

    def append_blob_block(_container, _path, data, options={})
      @blocks.append(data)
    end

    def get_container_properties(_container)
      unless @response.status_code == 200
        raise Azure::Core::Http::HTTPError.new(@response)
      end
    end
  end

  sub_test_case 'test container_exists' do
    test 'container 404 returns false' do
      d = create_driver service: FakeBlobService.new(404)
      assert_false d.instance.container_exists? 'anything'
    end

    test 'existing container returns true' do
      d = create_driver service: FakeBlobService.new(200)
      assert_true d.instance.container_exists? 'anything'
    end

    test 'unexpected exception raises' do
      d = create_driver service: FakeBlobService.new(500)
      assert_raise_kind_of Azure::Core::Http::HTTPError do
        d.instance.container_exists? 'anything'
      end
    end
  end

  # Override the block size limit so that mocked requests do not require huge buffers
  class Fluent::Plugin::AzureStorageAppendBlobOut
    AZURE_BLOCK_SIZE_LIMIT = 10
  end

  sub_test_case 'test append blob buffering' do
    def fake_appended_blocks(content)
      # run the append on the fake blob service, return a list of append request buffers
      svc = FakeBlobService.new(200)
      d = create_driver service: svc
      d.instance.send(:append_blob, content, nil)
      svc.blocks
    end

    test 'short buffer appends once' do
      content = '123456789'
      blocks = fake_appended_blocks content
      assert_equal [content], blocks
    end

    test 'single character appends once' do
      content = '1'
      blocks = fake_appended_blocks content
      assert_equal [content], blocks
    end

    test 'empty appends once' do
      content = ''
      blocks = fake_appended_blocks content
      assert_equal [''], blocks
    end

    test 'long buffer appends multiple times' do
      limit = Fluent::Plugin::AzureStorageAppendBlobOut::AZURE_BLOCK_SIZE_LIMIT
      buf1 = 'a' * limit
      buf2 = 'a' * 3
      blocks = fake_appended_blocks buf1 + buf2
      assert_equal [buf1, buf2], blocks
    end
  end
end
