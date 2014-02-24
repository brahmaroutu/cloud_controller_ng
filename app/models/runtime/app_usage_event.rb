module VCAP::CloudController
  class AppUsageEvent < Sequel::Model
    plugin :serialization
    export_attributes :state, :memory_in_mb_per_instance, :instance_count, :app_guid, :app_name, :app_buildpack, :app_detected_buildpack, :space_guid, :space_name, :org_guid
  end
end
