require "spec_helper"

module VCAP::CloudController
  describe VCAP::CloudController::DeaClient do
    let(:message_bus) { CfMessageBus::MockMessageBus.new }
    let(:stager_pool) { double(:stager_pool) }
    let(:dea_pool) { double(:dea_pool) }
    let(:num_service_instances) { 3 }
    let(:app) do
      app = AppFactory.make.tap do |app|
        num_service_instances.times do
          instance = ManagedServiceInstance.make(:space => app.space)
          binding = ServiceBinding.make(
            :app => app,
            :service_instance => instance
          )
          app.add_service_binding(binding)
        end
      end
    end

    let(:blobstore_url_generator) do
      double("blobstore_url_generator", :droplet_download_url => "app_uri")
    end

    before do
      DeaClient.configure(TestConfig.config, message_bus, dea_pool, stager_pool, blobstore_url_generator)
    end

    describe ".run" do
      it "registers subscriptions for dea_pool" do
        dea_pool.should_receive(:register_subscriptions)
        described_class.run
      end
    end

    describe "update_uris" do
      it "does not update deas if app isn't staged" do
        app.update(:package_state => "PENDING")
        message_bus.should_not_receive(:publish)
        DeaClient.update_uris(app)
      end

      it "sends a dea update message" do
        app.update(:package_state => "STAGED")
        message_bus.should_receive(:publish).with(
          "dea.update",
          hash_including(
            # XXX: change this to actual URLs from user once we do it
            :uris => kind_of(Array),
            :version => app.version
          )
        )
        DeaClient.update_uris(app)
      end
    end

    describe "start_instances" do
      it "should send a start messages to deas with message override" do
        app.instances = 3

        dea_pool.should_receive(:find_dea).twice.and_return("dea_123")
        dea_pool.should_receive(:mark_app_started).twice.with(dea_id: "dea_123", app_id: app.guid)
        dea_pool.should_receive(:reserve_app_memory).twice.with("dea_123", app.memory)
        stager_pool.should_receive(:reserve_app_memory).twice.with("dea_123", app.memory)
        message_bus.should_receive(:publish).with(
          "dea.dea_123.start",
          hash_including(
            :index => 1,
          )
        ).ordered

        message_bus.should_receive(:publish).with(
          "dea.dea_123.start",
          hash_including(
            :index => 2,
          )
        ).ordered

        DeaClient.start_instances(app, [1, 2])
      end
    end

    describe "start_instance_at_index" do
      it "should send a start messages to deas with message override" do
        app.instances = 2

        dea_pool.should_receive(:find_dea).once.and_return("dea_123")
        dea_pool.should_receive(:mark_app_started).once.with(dea_id: "dea_123", app_id: app.guid)
        dea_pool.should_receive(:reserve_app_memory).once.with("dea_123", app.memory)
        stager_pool.should_receive(:reserve_app_memory).once.with("dea_123", app.memory)
        message_bus.should_receive(:publish).with(
          "dea.dea_123.start",
          hash_including(
            :index => 1,
          )
        )

        DeaClient.start_instance_at_index(app, 1)
      end

      it "should not log passwords" do
        logger = double(Steno)
        allow(DeaClient).to receive(:logger).and_return(logger)

        dea_pool.should_receive(:find_dea).once.and_return(nil)
        logger.should_receive(:error) do |msg, data|
          data[:message].should_not include(:services, :env, :executableUri)
        end.once

        DeaClient.start_instance_at_index(app, 1)
      end

      context "when droplet is missing" do
        let(:blobstore_url_generator) do
          double("blobstore_url_generator", :droplet_download_url => nil)
        end

        it "should raise an error if the droplet is missing" do
          expect {
            DeaClient.start_instance_at_index(app, 1)
          }.to raise_error Errors::ApiError, "The app package could not be found: #{app.guid}"
        end
      end
    end

    describe "start" do
      it "should send start messages to deas" do
        app.instances = 2
        dea_pool.should_receive(:find_dea).and_return("abc")
        dea_pool.should_receive(:find_dea).and_return("def")
        dea_pool.should_receive(:mark_app_started).with(dea_id: "abc", app_id: app.guid)
        dea_pool.should_receive(:mark_app_started).with(dea_id: "def", app_id: app.guid)
        dea_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        dea_pool.should_receive(:reserve_app_memory).with("def", app.memory)
        stager_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        stager_pool.should_receive(:reserve_app_memory).with("def", app.memory)
        message_bus.should_receive(:publish).with("dea.abc.start", kind_of(Hash))
        message_bus.should_receive(:publish).with("dea.def.start", kind_of(Hash))

        DeaClient.start(app)
      end

      it "should start the specified number of instances" do
        app.instances = 2
        dea_pool.stub(:find_dea).and_return("abc", "def")

        dea_pool.should_receive(:mark_app_started).with(dea_id: "abc", app_id: app.guid)
        dea_pool.should_not_receive(:mark_app_started).with(dea_id: "def", app_id: app.guid)
        dea_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        dea_pool.should_not_receive(:reserve_app_memory).with("def", app.memory)
        stager_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        stager_pool.should_not_receive(:reserve_app_memory).with("def", app.memory)

        DeaClient.start(app, :instances_to_start => 1)
      end

      it "sends a dea start message that includes cc_partition" do
        TestConfig.override(:cc_partition => "ngFTW")
        DeaClient.configure(TestConfig.config, message_bus, dea_pool, stager_pool, blobstore_url_generator)

        app.instances = 1
        dea_pool.should_receive(:find_dea).and_return("abc")
        dea_pool.should_receive(:mark_app_started).with(dea_id: "abc", app_id: app.guid)
        dea_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        stager_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
        message_bus.should_receive(:publish).with("dea.abc.start", hash_including(:cc_partition => "ngFTW"))

        DeaClient.start(app)
      end

      it "includes memory in find_dea request" do
        app.instances = 1
        app.memory = 512
        dea_pool.should_receive(:find_dea).with(include(mem: 512))
        DeaClient.start(app)
      end

      it "includes disk in find_dea request" do
        app.instances = 1
        app.disk_quota = 13
        dea_pool.should_receive(:find_dea).with(include(disk: 13))
        DeaClient.start(app)
      end
    end

    describe "stop_indices" do
      it "should send stop messages to deas" do
        app.instances = 3
        message_bus.should_receive(:publish).with(
          "dea.stop",
          hash_including(
            :droplet   => app.guid,
            :indices   => [0, 2],
          )
        )

        DeaClient.stop_indices(app, [0,2])
      end
    end

    describe "stop_instances" do
      it "should send stop messages to deas" do
        app.instances = 3
        message_bus.should_receive(:publish).with(
          "dea.stop",
          hash_including(
            droplet: app.guid,
            instances: ["a", "b"]
          )
        ) do |_, payload|
          expect(payload).to_not include(:version)
        end

        DeaClient.stop_instances(app.guid, ["a", "b"])
      end

      it "should support single instance" do
        message_bus.should_receive(:publish).with(
          "dea.stop",
          hash_including(droplet: app.guid, instances: ["a"])
        ) do |_, payload|
          expect(payload).to_not include(:version)
        end

        DeaClient.stop_instances(app.guid, "a")
      end
    end

    describe "stop" do
      it "should send a stop messages to deas" do
        app.instances = 2
        message_bus.should_receive(:publish).with("dea.stop", kind_of(Hash))

        DeaClient.stop(app)
      end
    end

    describe "find_specific_instance" do
      it "should find a specific instance" do
        app.should_receive(:guid).and_return(1)

        encoded = {:droplet => 1, :other_opt => "value"}
        message_bus.should_receive(:synchronous_request).
          with("dea.find.droplet", encoded, {:timeout=>2}).
          and_return(["instance"])

        DeaClient.find_specific_instance(app, { :other_opt => "value" }).should == "instance"
      end
    end

    describe "find_instances" do
      it "should use specified message options" do
        app.should_receive(:guid).and_return(1)
        app.should_receive(:instances).and_return(2)

        instance_json = "instance"
        encoded = {
          droplet: 1,
          other_opt_0: "value_0",
          other_opt_1: "value_1",
        }
        message_bus.should_receive(:synchronous_request).
          with("dea.find.droplet", encoded, { :result_count => 2, :timeout => 2 }).
          and_return([instance_json, instance_json])

        message_options = {
          :other_opt_0 => "value_0",
          :other_opt_1 => "value_1",
        }

        DeaClient.find_instances(app, message_options).should == ["instance", "instance"]
      end

      it "should use default values for expected instances and timeout if none are specified" do
        app.should_receive(:guid).and_return(1)
        app.should_receive(:instances).and_return(2)

        instance_json = "instance"
        encoded = { :droplet => 1 }
        message_bus.should_receive(:synchronous_request).
          with("dea.find.droplet", encoded, { :result_count => 2, :timeout => 2 }).
          and_return([instance_json, instance_json])

        DeaClient.find_instances(app).should == ["instance", "instance"]
      end

      it "should use the specified values for expected instances and timeout" do
        app.should_receive(:guid).and_return(1)

        instance_json = "instance"
        encoded = { :droplet => 1, :other_opt => "value" }
        message_bus.should_receive(:synchronous_request).
          with("dea.find.droplet", encoded, { :result_count => 5, :timeout => 10 }).
          and_return([instance_json, instance_json])

        DeaClient.find_instances(app, { :other_opt => "value" },
                                   { :result_count => 5, :timeout => 10 }).
                                   should == ["instance", "instance"]
      end
    end

    describe "get_file_uri_for_instance" do
      include Errors

      it "should raise an error if the app is in stopped state" do
        app.should_receive(:stopped?).once.and_return(true)
        app.stub(:instances) { 1 }

        instance = 0
        path = "test"

        expect {
          DeaClient.get_file_uri_for_active_instance_by_index(app, path, instance)
        }.to raise_error Errors::ApiError, "File error: Request failed for app: #{app.name} path: #{path} as the app is in stopped state."
      end

      it "should raise an error if the instance is out of range" do
        app.instances = 5

        instance = 10
        path = "test"

        expect {
          DeaClient.get_file_uri_for_active_instance_by_index(app, path, instance)
        }.to raise_error { |error|
          error.should be_an_instance_of Errors::ApiError
          error.name.should == "FileError"

          msg = "File error: Request failed for app: #{app.name}"
          msg << ", instance: #{instance} and path: #{path} as the instance is"
          msg << " out of range."

          error.message.should == msg
        }
      end

      it "should return the file uri if the required instance is found via DEA v1" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance = 1
        path = "test"

        search_options = {
          :indices => [instance],
          :states => DeaClient::ACTIVE_APP_STATES,
          :version => app.version,
          :path => "test",
          :droplet => app.guid
        }

        instance_found = {
          "file_uri" => "http://1.2.3.4/",
          "staged" => "staged",
          "credentials" => ["username", "password"],
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_found])

        result = DeaClient.get_file_uri_for_active_instance_by_index(app, path, instance)
        result.file_uri_v1.should == "http://1.2.3.4/staged/test"
        result.file_uri_v2.should be_nil
        result.credentials.should == ["username", "password"]

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {timeout: 2})
      end

      it "should return both file_uri_v2 and file_uri_v1 from DEA v2" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance = 1
        path = "test"

        search_options = {
          :indices => [instance],
          :states => DeaClient::ACTIVE_APP_STATES,
          :version => app.version,
          :path => "test",
          :droplet => app.guid
        }

        instance_found = {
          "file_uri_v2" => "file_uri_v2",
          "file_uri" => "http://1.2.3.4/",
          "staged" => "staged",
          "credentials" => ["username", "password"],
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_found])

        info = DeaClient.get_file_uri_for_active_instance_by_index(app, path, instance)
        info.file_uri_v2.should == "file_uri_v2"
        info.file_uri_v1.should == "http://1.2.3.4/staged/test"
        info.credentials.should == ["username", "password"]

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {timeout: 2})
      end

      it "should raise an error if the instance is not found" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance = 1
        path = "test"
        msg = "File error: Request failed for app: #{app.name}"
        msg << ", instance: #{instance} and path: #{path} as the instance is"
        msg << " not found."

        search_options = {
          :indices => [instance],
          :states => DeaClient::ACTIVE_APP_STATES,
          :version => app.version,
          :path => "test",
          :droplet => app.guid
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [])

        expect {
          DeaClient.get_file_uri_for_active_instance_by_index(app, path, instance)
        }.to raise_error Errors::ApiError, msg

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {timeout: 2})
      end
    end

    describe "get_file_uri_for_instance_id" do
      include Errors

      it "should raise an error if the app is in stopped state" do
        app.should_receive(:stopped?).once.and_return(true)

        instance_id = "abcdef"
        path = "test"
        msg = "File error: Request failed for app: #{app.name}"
        msg << " path: #{path} as the app is in stopped state."

        expect {
          DeaClient.get_file_uri_by_instance_guid(app, path, instance_id)
        }.to raise_error Errors::ApiError, msg
      end

      it "should return the file uri if the required instance is found via DEA v1" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance_id = "abcdef"
        path = "test"

        search_options = {
          instance_ids: [instance_id],
          states: [:STARTING, :RUNNING, :CRASHED],
          path: "test",
          droplet: app.guid
        }

        instance_found = {
          "file_uri" => "http://1.2.3.4/",
          "staged" => "staged",
          "credentials" => ["username", "password"],
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_found])

        result = DeaClient.get_file_uri_by_instance_guid(app, path, instance_id)
        result.file_uri_v1.should == "http://1.2.3.4/staged/test"
        result.file_uri_v2.should be_nil
        result.credentials.should == ["username", "password"]

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {timeout: 2})
      end

      it "should return both file_uri_v2 and file_uri_v1 from DEA v2" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance_id = "abcdef"
        path = "test"

        search_options = {
          instance_ids: [instance_id],
          states: [:STARTING, :RUNNING, :CRASHED],
          path: "test",
          droplet: app.guid
        }

        instance_found = {
          "file_uri_v2" => "file_uri_v2",
          "file_uri" => "http://1.2.3.4/",
          "staged" => "staged",
          "credentials" => ["username", "password"],
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_found])

        info = DeaClient.get_file_uri_by_instance_guid(app, path, instance_id)
        info.file_uri_v2.should == "file_uri_v2"
        info.file_uri_v1.should == "http://1.2.3.4/staged/test"
        info.credentials.should == ["username", "password"]

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {timeout: 2})
      end

      it "should raise an error if the instance_id is not found" do
        app.instances = 2
        app.should_receive(:stopped?).once.and_return(false)

        instance_id = "abcdef"
        path = "test"

        search_options = {
          :instance_ids => [instance_id],
          :states => [:STARTING, :RUNNING, :CRASHED],
          :path => "test",
        }

        DeaClient.should_receive(:find_specific_instance).
          with(app, search_options).and_return(nil)

        expect {
          DeaClient.get_file_uri_by_instance_guid(app, path, instance_id)
        }.to raise_error { |error|
          error.should be_an_instance_of Errors::ApiError
          error.name.should == "FileError"

          msg = "File error: Request failed for app: #{app.name}"
          msg << ", instance_id: #{instance_id} and path: #{path} as the instance_id is"
          msg << " not found."

          error.message.should == msg
        }
      end
    end

    describe "find_stats" do
      it "should return the stats for all instances" do
        app.instances = 2

        stats = double("mock stats")
        instance_0 = {
          "index" => 0,
          "state" => "RUNNING",
          "stats" => stats,
        }

        instance_1 = {
          "index" => 1,
          "state" => "RUNNING",
          "stats" => stats,
        }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_0, instance_1])

        app_stats = DeaClient.find_stats(app)
        expect(app_stats).to eq(
          0 => {
            state: "RUNNING",
            stats: stats,
          },
          1 => {
            state: "RUNNING",
            stats: stats,
          }
        )
      end

      it "should return filler stats for instances that have not responded" do
        app.instances = 2

        search_options = {
          include_stats: true,
          states: [:RUNNING],
          version: app.version,
          droplet: app.guid
        }

        stats = double("mock stats")
        instance = {
          "index" => 0,
          "state" => "RUNNING",
          "stats" => stats,
        }

        Time.stub(:now) { 1 }

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance])

        app_stats = DeaClient.find_stats(app)

        expect(app_stats).to eq(
          0 => {
            :state => "RUNNING",
            :stats => stats,
          },
          1 => {
            :state => "DOWN",
            :since => 1,
          }
        )

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {result_count: 2, timeout: 2})
      end

      it "should return filler stats for instances with out of range indices" do
        app.instances = 2

        search_options = {
          :include_stats => true,
          :states => [:RUNNING],
          :version => app.version,
          :droplet => app.guid
        }

        stats = double("mock stats")
        instance_0 = {
          "index" => -1,
          "state" => "RUNNING",
          "stats" => stats,
        }

        instance_1 = {
          "index" => 0,
          "state" => "RUNNING",
          "stats" => stats,
        }

        instance_2 = {
          "index" => 2,
          "state" => "RUNNING",
          "stats" => stats,
        }

        Time.stub(:now).and_return(1)

        message_bus.respond_to_synchronous_request("dea.find.droplet", [instance_0, instance_1, instance_2])

        app_stats = DeaClient.find_stats(app)
        expect(app_stats).to eq(
          0 => {
            :state => "RUNNING",
            :stats => stats,
          },
          1 => {
            :state => "DOWN",
            :since => 1,
          }
        )

        expect(message_bus).to have_requested_synchronous_messages("dea.find.droplet", search_options, {result_count: 2, timeout: 2})
      end
    end

    describe "find_all_instances" do
      let!(:health_manager_client) do
        CloudController::DependencyLocator.instance.health_manager_client.tap do |hm|
          VCAP::CloudController::DeaClient.stub(:health_manager_client) { hm }
        end
      end

      include Errors

      it "should return starting or running instances" do
        app.instances = 3

        flapping_instances = [
            { "index" => 0, "since" => 1 },
          ]

        health_manager_client.should_receive(:find_flapping_indices).
          with(app).and_return(flapping_instances)

        search_options = {
          :states => [:STARTING, :RUNNING],
          :version => app.version,
        }

        starting_instance  = {
          "index" => 1,
          "state" => "STARTING",
          "state_timestamp" => 2,
          "debug_ip" => "1.2.3.4",
          "debug_port" => 1001,
          "console_ip" => "1.2.3.5",
          "console_port" => 1002,
        }

        running_instance  = {
          "index" => 2,
          "state" => "RUNNING",
          "state_timestamp" => 3,
          "debug_ip" => "2.3.4.5",
          "debug_port" => 2001,
          "console_ip" => "2.3.4.6",
          "console_port" => 2002,
        }

        DeaClient.should_receive(:find_instances).
          with(app, search_options, {:expected => 2}).
          and_return([starting_instance, running_instance])

        app_instances = DeaClient.find_all_instances(app)
        app_instances.should == {
          0 => {
            :state => "FLAPPING",
            :since => 1,
          },
          1 => {
            :state => "STARTING",
            :since => 2,
            :debug_ip => "1.2.3.4",
            :debug_port => 1001,
            :console_ip => "1.2.3.5",
            :console_port => 1002,
          },
          2 => {
            :state => "RUNNING",
            :since => 3,
            :debug_ip => "2.3.4.5",
            :debug_port => 2001,
            :console_ip => "2.3.4.6",
            :console_port => 2002,
          },
        }
      end

      it "should ignore out of range indices of starting or running instances" do
        app.instances = 2

        health_manager_client.should_receive(:find_flapping_indices).
          with(app).and_return([])

        search_options = {
          :states => [:STARTING, :RUNNING],
          :version => app.version,
        }

        starting_instance  = {
          "index" => -1,  # -1 is out of range.
          "state_timestamp" => 1,
          "debug_ip" => "1.2.3.4",
          "debug_port" => 1001,
          "console_ip" => "1.2.3.5",
          "console_port" => 1002,
        }

        running_instance  = {
          "index" => 2,  # 2 is out of range.
          "state" => "RUNNING",
          "state_timestamp" => 2,
          "debug_ip" => "2.3.4.5",
          "debug_port" => 2001,
          "console_ip" => "2.3.4.6",
          "console_port" => 2002,
        }

        DeaClient.should_receive(:find_instances).
          with(app, search_options, { :expected => 2 }).
          and_return([starting_instance, running_instance])

        Time.stub(:now) { 1 }

        app_instances = DeaClient.find_all_instances(app)
        app_instances.should == {
          0 => {
            :state => "DOWN",
            :since => 1,
          },
          1 => {
            :state => "DOWN",
            :since => 1,
          },
        }
      end

      it "should return fillers for instances that have not responded" do
        app.instances = 2

        health_manager_client.should_receive(:find_flapping_indices).
          with(app).and_return([])

        search_options = {
          :states => [:STARTING, :RUNNING],
          :version => app.version,
        }

        DeaClient.should_receive(:find_instances).
          with(app, search_options, {:expected => 2}).
          and_return([])

        Time.stub(:now) { 1 }

        app_instances = DeaClient.find_all_instances(app)
        app_instances.should == {
          0 => {
            :state => "DOWN",
            :since => 1,
          },
          1 => {
            :state => "DOWN",
            :since => 1,
          },
        }
      end
    end

    describe "change_running_instances" do
      context "increasing the instance count" do
        it "should issue a start command with extra indices" do
          dea_pool.should_receive(:find_dea).and_return("abc")
          dea_pool.should_receive(:find_dea).and_return("def")
          dea_pool.should_receive(:find_dea).and_return("efg")
          dea_pool.should_receive(:mark_app_started).with(dea_id: "abc", app_id: app.guid)
          dea_pool.should_receive(:mark_app_started).with(dea_id: "def", app_id: app.guid)
          dea_pool.should_receive(:mark_app_started).with(dea_id: "efg", app_id: app.guid)

          dea_pool.should_receive(:reserve_app_memory).with("abc", app.memory)
          dea_pool.should_receive(:reserve_app_memory).with("def", app.memory)
          dea_pool.should_receive(:reserve_app_memory).with("efg", app.memory)
          stager_pool.
              should_receive(:reserve_app_memory).with("abc", app.memory)
          stager_pool.
              should_receive(:reserve_app_memory).with("def", app.memory)
          stager_pool.
              should_receive(:reserve_app_memory).with("efg", app.memory)

          message_bus.should_receive(:publish).with("dea.abc.start", kind_of(Hash))
          message_bus.should_receive(:publish).with("dea.def.start", kind_of(Hash))
          message_bus.should_receive(:publish).with("dea.efg.start", kind_of(Hash))

          app.instances = 4
          app.save

          DeaClient.change_running_instances(app, 3)
        end
      end

      context "decreasing the instance count" do
        it "should stop the higher indices" do
          message_bus.should_receive(:publish).with("dea.stop", kind_of(Hash))
          app.instances = 5
          app.save

          DeaClient.change_running_instances(app, -2)
        end
      end

      context "with no changes" do
        it "should do nothing" do
          app.instances = 9
          app.save

          DeaClient.change_running_instances(app, 0)
        end
      end
    end
  end
end
