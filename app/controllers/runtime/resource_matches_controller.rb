module VCAP::CloudController
  class ResourceMatchesController < RestController::BaseController
    put "/v2/resource_match", :match
    def match
      return ApiError.new_from_details("NotAuthorized") unless user
      fingerprints_all_clientside_bits = Yajl::Parser.parse(body)
      fingerprints_existing_in_blobstore = ResourcePool.instance.match_resources(fingerprints_all_clientside_bits)
      Yajl::Encoder.encode(fingerprints_existing_in_blobstore)
    end
  end
end
