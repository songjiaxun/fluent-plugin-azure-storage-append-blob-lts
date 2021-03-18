#---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See License.txt in the project root for license information.
#--------------------------------------------------------------------------------------------*/

require 'azure/storage/common'
require 'azure/storage/blob'
require 'faraday'
require 'fluent/plugin/output'
require 'json'

module Fluent
  module Plugin
    class AzureStorageAppendBlobOut < Output
      Fluent::Plugin.register_output('azure-storage-append-blob', self)

      helpers :formatter, :inject

      DEFAULT_FORMAT_TYPE = 'out_file'.freeze
      AZURE_BLOCK_SIZE_LIMIT = 4 * 1024 * 1024 - 1

      def initialize
        super
        @use_msi = false

        # Storage endpoint suffixes for various environments, see https://github.com/Azure/go-autorest/blob/master/autorest/azure/environments.go
        @storage_endpoint_mapping = {
          'AZURECHINACLOUD' => 'core.chinacloudapi.cn',
          'AZUREGERMANCLOUD' => 'core.cloudapi.de',
          'AZUREPUBLICCLOUD' => 'core.windows.net',
          'AZUREUSGOVERNMENTCLOUD' => 'core.usgovcloudapi.net'
        }
      end

      config_param :path, :string, default: ''
      config_param :azure_storage_account, :string, default: nil
      config_param :azure_storage_access_key, :string, default: nil, secret: true
      config_param :azure_storage_connection_string, :string, default: nil, secret: true
      config_param :azure_storage_dns_suffix, :string, default: nil
      config_param :azure_storage_sas_token, :string, default: nil, secret: true
      config_param :azure_cloud, :string, default: 'AZUREPUBLICCLOUD'
      config_param :azure_msi_client_id, :string, default: nil
      config_param :azure_container, :string, default: nil
      config_param :azure_imds_api_version, :string, default: '2019-08-15'
      config_param :azure_token_refresh_interval, :integer, default: 60
      config_param :azure_object_key_format, :string, default: '%{path}%{time_slice}-%{index}.log'
      config_param :auto_create_container, :bool, default: true
      config_param :compute_checksums, :bool, default: true
      config_param :format, :string, default: DEFAULT_FORMAT_TYPE
      config_param :time_slice_format, :string, default: '%Y%m%d'
      config_param :localtime, :bool, default: false

      config_section :format do
        config_set_default :@type, DEFAULT_FORMAT_TYPE
      end

      config_section :buffer do
        config_set_default :chunk_keys, ['time']
        config_set_default :timekey, (60 * 60 * 24)
      end

      attr_reader :bs

      def configure(conf)
        super

        @formatter = formatter_create

        @path_slicer = if @localtime
                         proc do |path|
                           Time.now.strftime(path)
                         end
                       else
                         proc do |path|
                           Time.now.utc.strftime(path)
                         end
                       end

        if @azure_cloud == 'AZURESTACKCLOUD'
          if @azure_storage_dns_suffix.nil?
            raise ConfigError 'azure_storage_dns_suffix invalid, must not be empty for AZURESTACKCLOUD'
          end
        else
          @azure_storage_dns_suffix = @storage_endpoint_mapping[@azure_cloud]
          if @azure_storage_dns_suffix.nil?
            raise ConfigError 'azure_cloud invalid, must be either of AZURECHINACLOUD, AZUREGERMANCLOUD, AZUREPUBLICCLOUD, AZUREUSGOVERNMENTCLOUD'
          end
        end

        if (@azure_storage_access_key.nil? || @azure_storage_access_key.empty?) &&
           (@azure_storage_sas_token.nil? || @azure_storage_sas_token.empty?) &&
           (@azure_storage_connection_string.nil? || @azure_storage_connection_string.empty?)
          log.info 'Using MSI since neither of azure_storage_access_key, azure_storage_sas_token, azure_storage_connection_string was provided.'
          @use_msi = true
        elsif @azure_storage_connection_string.nil? || @azure_storage_connection_string.empty?
          raise ConfigError, 'azure_storage_account needs to be specified' if @azure_storage_account.nil?
          raise ConfigError, 'azure_container needs to be specified' if @azure_container.nil?
        end

        @blob_options = {}

        if !@compute_checksums
          @blob_options[:content_md5] = ''
        end
      end

      def multi_workers_ready?
        true
      end

      def get_access_token
        access_key_request = Faraday.new('http://169.254.169.254/metadata/identity/oauth2/token?' \
                                         "api-version=#{@azure_imds_api_version}" \
                                         '&resource=https://storage.azure.com/' \
                                         "#{!azure_msi_client_id.nil? ? "&client_id=#{azure_msi_client_id}" : ''}",
                                         headers: { 'Metadata' => 'true' }).get

        if access_key_request.status == 200
          JSON.parse(access_key_request.body)['access_token']
        else
          raise 'Access token request was not sucssessful. Possibly due to missing azure_msi_client_id config parameter.'
        end
      end

      def start
        super
        if @use_msi
          token_credential = Azure::Storage::Common::Core::TokenCredential.new get_access_token
          token_signer = Azure::Storage::Common::Core::Auth::TokenSigner.new token_credential
          @bs = Azure::Storage::Blob::BlobService.new(
            storage_account_name: @azure_storage_account,
            storage_dns_suffix: @azure_storage_dns_suffix,
            signer: token_signer
          )

          refresh_interval = @azure_token_refresh_interval * 60
          cancelled = false
          renew_token = Thread.new do
            Thread.stop
            until cancelled
              sleep(refresh_interval)

              token_credential.renew_token get_access_token
            end
          end
          sleep 0.1 while renew_token.status != 'sleep'
          renew_token.run
        elsif !@azure_storage_connection_string.nil? && !@azure_storage_connection_string.empty?
          @bs = Azure::Storage::Blob::BlobService.create_from_connection_string(@azure_storage_connection_string)
        else
          @bs_params = { storage_account_name: @azure_storage_account, storage_dns_suffix: @azure_storage_dns_suffix }

          if !@azure_storage_access_key.nil? && !@azure_storage_access_key.empty?
            @bs_params.merge!({ storage_access_key: @azure_storage_access_key })
          elsif !@azure_storage_sas_token.nil? && !@azure_storage_sas_token.empty?
            @bs_params.merge!({ storage_sas_token: @azure_storage_sas_token })
          end

          @bs = Azure::Storage::Blob::BlobService.create(@bs_params)

        end

        ensure_container
        @azure_storage_path = ''
        @last_azure_storage_path = ''
        @current_index = 0
      end

      def format(tag, time, record)
        r = inject_values_to_record(tag, time, record)
        @formatter.format(tag, time, r)
      end

      def write(chunk)
        tmp = Tempfile.new('azure-')
        begin
          chunk.write_to(tmp)

          generate_log_name(chunk, @current_index)
          if @last_azure_storage_path != @azure_storage_path
            @current_index = 0
            generate_log_name(chunk, @current_index)
          end

          content = File.open(tmp.path, 'rb', &:read)

          append_blob(content, chunk)
          @last_azure_storage_path = @azure_storage_path
        ensure
          begin
            tmp.close(true)
          rescue StandardError
            nil
          end
        end
      end

      def container_exists?(container)
        begin
          @bs.get_container_properties(container)
        rescue Azure::Core::Http::HTTPError => e
          if e.status_code == 404 # container does not exist
            return false
          else
            raise
          end
        end
        true
      end

      private

      def ensure_container
        unless container_exists? @azure_container
          if @auto_create_container
            @bs.create_container(@azure_container)
          else
            raise "The specified container does not exist: container = #{@azure_container}"
          end
        end
      end

      def generate_log_name(chunk, index)
        metadata = chunk.metadata
        time_slice = if metadata.timekey.nil?
                       ''.freeze
                     else
                       Time.at(metadata.timekey).utc.strftime(@time_slice_format)
                     end

        path = @path_slicer.call(@path)
        values_for_object_key = {
          '%{path}' => path,
          '%{time_slice}' => time_slice,
          '%{index}' => index
        }
        storage_path = @azure_object_key_format.gsub(/%{[^}]+}/, values_for_object_key)
        @azure_storage_path = extract_placeholders(storage_path, chunk)
      end

      def append_blob(content, chunk)
        position = 0
        log.debug "azure_storage_append_blob: append_blob.start: Content size: #{content.length}"
        loop do
          size = [content.length - position, AZURE_BLOCK_SIZE_LIMIT].min
          log.debug "azure_storage_append_blob: append_blob.chunk: content[#{position}..#{position + size}]"
          @bs.append_blob_block(@azure_container, @azure_storage_path, content[position..position + size - 1], options=@blob_options)
          position += size
          break if position >= content.length
        rescue Azure::Core::Http::HTTPError => e
          status_code = e.status_code

          if status_code == 409 # exceeds azure block limit
            @current_index += 1
            old_azure_storage_path = @azure_storage_path
            generate_log_name(chunk, @current_index)

            # If index is not a part of format, rethrow exception.
            if old_azure_storage_path == @azure_storage_path
              log.warn 'azure_storage_append_blob: append_blob: blocks limit reached, you need to use %{index} for the format.'
              raise
            end

            log.debug "azure_storage_append_blob: append_blob: blocks limit reached, creating new blob #{@azure_storage_path}."
            @bs.create_append_blob(@azure_container, @azure_storage_path)
          elsif status_code == 404 # blob not found
            log.debug "azure_storage_append_blob: append_blob: #{@azure_storage_path} blob doesn't exist, creating new blob."
            @bs.create_append_blob(@azure_container, @azure_storage_path)
          else
            raise
          end
        end
        log.debug 'azure_storage_append_blob: append_blob.complete'
      end
    end
  end
end
