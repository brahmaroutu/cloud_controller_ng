require "spec_helper"

module VCAP::CloudController
  describe VCAP::CloudController::ServiceCreateEvent, type: :model do
    before do
      TestConfig.override({ :billing_event_writing_enabled => true })
    end

    it_behaves_like "a CloudController model", {
      :required_attributes => [
        :timestamp,
        :organization_guid,
        :organization_name,
        :space_guid,
        :space_name,
        :service_instance_guid,
        :service_instance_name,
        :service_guid,
        :service_label,
        :service_plan_guid,
        :service_plan_name,
      ],
      :db_required_attributes => [
        :timestamp,
        :organization_guid,
        :organization_name,
      ],
      :disable_examples => :deserialization
    }

    describe "create_from_service_instance" do
      context "on an org without billing enabled" do
        it "should do nothing" do
          ServiceCreateEvent.should_not_receive(:create)
          si = ManagedServiceInstance.make
          org = si.space.organization
          org.billing_enabled = false
          org.save(:validate => false)
          ServiceCreateEvent.create_from_service_instance(si)
        end
      end

      context "on an org with billing enabled" do
        it "should create an service create event" do
          si = ManagedServiceInstance.make
          org = si.space.organization
          org.billing_enabled = true
          org.save(:validate => false)
          ServiceCreateEvent.should_receive(:create)
          ServiceCreateEvent.create_from_service_instance(si)
        end
      end
    end
  end
end
