# Copyright (c) 2012 Piston Cloud Computing, Inc.

module Bosh::OpenStackCloud

  class Cloud < Bosh::Cloud
    ##
    # Initialize BOSH OpenStack CPI
    # @param [Hash] options CPI options
    #
    def initialize(options)
      @options = options.dup

      validate_options

      @logger = Bosh::Clouds::Config.logger

      @agent_properties = @options["agent"] || {}
      @openstack_properties = @options["openstack"]

      openstack_params = {
        :provider => "OpenStack",
        :openstack_auth_url => @openstack_properties["openstack_auth_url"],
        :openstack_username => @openstack_properties["openstack_username"],
        :openstack_api_key => @openstack_properties["openstack_api_key"],
        :openstack_tenant => @openstack_properties["openstack_tenant"]
      }

      @openstack = Fog::Compute.new(openstack_params)
    end

    ##
    # Creates OpenStack instance and waits until it's in running state
    # @param [String] agent_id Agent id associated with new VM
    # @param [String] stemcell_id AMI id that will be used
    #   to power on new instance
    # @param [Hash] resource_pool Resource pool specification
    # @param [Hash] network_spec Network specification, if it contains
    #  security groups they must be existing
    # @param [optional, Array] disk_locality List of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment Data to be merged into
    #   agent settings
    #
    # @return [String] created instance id
    def create_vm(agent_id, stemcell_id, resource_pool,
                  network_spec, disk_locality = nil, environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        network_configurator = NetworkConfigurator.new(network_spec)

        if disk_locality
          # TODO: use as hint for availability zones
          @logger.debug("Disk locality is ignored by AWS CPI")
        end

        instance_params = {
          :image_id => stemcell_id,
          :flavor_id => resource_pool["instance_type"],
        }

        @logger.info("Creating new instance...")
        instance = @os.servers.create(instance_params)
        state = instance.state

        @logger.info("Creating new instance `#{instance.id}', " \
                     "state is `#{state}'")

        wait_resource(instance, state, :running)

        network_configurator.configure(@ec2, instance)

        settings = initial_agent_settings(agent_id, network_spec, environment)

        instance.id
      end
    end

    ##
    # Terminates OpenStack instance and waits until it reports as terminated
    # @param [String] vm_id Running instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        instance = @os.instances[instance_id]

        instance.destroy
        state = instance.state

        @logger.info("Deleting instance `#{instance.id}', " \
                     "state is `#{state}'")

        wait_resource(instance, state, :deleted)
      end
    end

    ##
    # Reboots OpenStack instance
    # @param [String] instance_id Running instance id
    def reboot_vm(instance_id)
      with_thread_name("reboot_vm(#{instance_id})") do
        instance = @os.instances[instance_id]
        soft_reboot(instance)
      end
    end

    ##
    # Creates a new EBS volume
    # @param [Integer] size disk size in MiB
    # @param [optional, String] instance_id vm id
    #        of the VM that this disk will be attached to
    # @return [String] created EBS volume id
    def create_disk(size, instance_id = nil)
      with_thread_name("create_disk(#{size}, #{instance_id})") do
        unless size.kind_of?(Integer)
          raise ArgumentError, "disk size needs to be an integer"
        end

        if (size < 1024)
          cloud_error("AWS CPI minimum disk size is 1 GiB")
        end

        if (size > 1024 * 1000)
          cloud_error("AWS CPI maximum disk size is 1 TiB")
        end

        volume_params = {
          :size => (size / 1024.0).ceil,
        }

        volume = @ec2.volumes.create(volume_params)
        state = volume.state

        @logger.info("Creating volume `#{volume.id}', " \
                     "state is `#{state}'")

        wait_resource(volume, state, :available)

        volume.id
      end
    end

    ##
    # Deletes EBS volume
    # @param [String] disk_id volume id
    # @raise [Bosh::Clouds::CloudError] if disk is not in available state
    # @return nil
    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        volume = @ec2.volumes[disk_id]
        state = volume.state

        if state != :available
          cloud_error("Cannot delete volume `#{volume.id}', state is #{state}")
        end

        volume.delete

        begin
          state = volume.state
          @logger.info("Deleting volume `#{volume.id}', " \
                       "state is `#{state}'")

          wait_resource(volume, state, :deleted)
        rescue AWS::EC2::Errors::InvalidVolume::NotFound
        end

        @logger.info("Volume `#{disk_id}' has been deleted")
      end
    end

    def attach_disk(instance_id, disk_id)
      with_thread_name("attach_disk(#{instance_id}, #{disk_id})") do
        instance = @ec2.instances[instance_id]
        volume = @ec2.volumes[disk_id]

        device_name = attach_ebs_volume(instance, volume)

        update_agent_settings(instance) do |settings|
          settings["disks"] ||= {}
          settings["disks"]["persistent"] ||= {}
          settings["disks"]["persistent"][disk_id] = device_name
        end
      end
    end

    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id})") do
        instance = @ec2.instances[instance_id]
        volume = @ec2.volumes[disk_id]

        update_agent_settings(instance) do |settings|
          settings["disks"] ||= {}
          settings["disks"]["persistent"] ||= {}
          settings["disks"]["persistent"].delete(disk_id)
        end

        detach_ebs_volume(instance, volume)

        @logger.info("Detached `#{disk_id}' from `#{instance_id}'")
      end
    end

    def configure_networks(instance_id, network_spec)
      not_implemented(:configure_networks)
    end

    def create_stemcell(image_path, cloud_properties)
      not_implemented(:create_stemcell)
    end

    def delete_stemcell(stemcell_id)
      not_implemented(:delete_stemcell)
    end

    def validate_deployment(old_manifest, new_manifest)
      not_implemented(:validate_deployment)
    end

    private

    ##
    # Generates initial agent settings. These settings will be read by agent
    # from the OS API on a target instance. Disk conventions for amazon are:
    # system disk: /dev/sda
    # ephemeral disk: /dev/sdb
    # EBS volumes can be configured to map to other device names later (sdf
    # through sdp, also some kernels will remap sd* to xvd*).
    #
    # @param [String] agent_id Agent id (will be picked up by agent to
    #   assume its identity
    # @param [Hash] network_spec Agent network spec
    # @param [Hash] environment
    # @return [Hash]
    def initial_agent_settings(agent_id, network_spec, environment)
      settings = {
        "vm" => {
          "name" => "vm-#{generate_unique_name}"
        },
        "agent_id" => agent_id,
        "networks" => network_spec,
        "disks" => {
          "system" => "/dev/sda",
          "ephemeral" => "/dev/sdb",
          "persistent" => {}
        }
      }

      settings["env"] = environment if environment
      settings.merge(@agent_properties)
    end

    def update_agent_settings(instance)
      unless block_given?
        raise ArgumentError, "block is not provided"
      end

      settings = @os.server(instance.id)
      yield settings
    end

    def generate_unique_name
      UUIDTools::UUID.random_create.to_s
    end

    def attach_ebs_volume(instance, volume)
      device_names = Set.new(instance.block_device_mappings.keys)
      new_attachment = nil

      ("f".."p").each do |char| # f..p is what console suggests
        # Some kernels will remap sdX to xvdX, so agent needs
        # to lookup both (sd, then xvd)
        dev_name = "/dev/sd#{char}"
        if device_names.include?(dev_name)
          @logger.warn("`#{dev_name}' on `#{instance.id}' is taken")
          next
        end
        new_attachment = volume.attach_to(instance, dev_name)
        break
      end

      if new_attachment.nil?
        # TODO: better messaging?
        cloud_error("Instance has too many disks attached")
      end

      state = new_attachment.status

      @logger.info("Attaching `#{volume.id}' to #{instance.id}, " \
                   "state is #{state}'")

      wait_resource(new_attachment, state, :attached)
      device_name = new_attachment.device

      @logger.info("Attached `#{volume.id}' to `#{instance.id}', " \
                   "device name is `#{device_name}'")

      device_name
    end

    def detach_ebs_volume(instance, volume)
      mappings = instance.block_device_mappings

      device_map = mappings.inject({}) do |hash, (device_name, attachment)|
        hash[attachment.volume.id] = device_name
        hash
      end

      if device_map[volume.id].nil?
        cloud_error("Disk `#{volume.id}' is not attached " \
                    "to instance `#{instance.id}'")
      end

      attachment = volume.detach_from(instance, device_map[volume.id])
      state = attachment.status

      @logger.info("Detaching `#{volume.id}' from `#{instance.id}', " \
                   "state is #{state}'")

      begin
        wait_resource(attachment, state, :detached)
      rescue AWS::Core::Resource::NotFound
        # It's OK, just means attachment is gone when we're asking for state
      end
    end

    ##
    # Soft reboots OpenStack instance
    # @param [AWS::EC2::Instance] instance EC2 instance
    def soft_reboot(instance)
      instance.reboot
    end

    ##
    # Hard reboots OpenStack instance
    # @param [AWS::EC2::Instance] instance EC2 instance
    def hard_reboot(instance)
      instance.reboot(type = 'HARD')
    end

    ##
    # Checks if options passed to CPI are valid and can actually
    # be used to create all required data structures etc.
    #
    def validate_options
      unless @options.has_key?("openstack") &&
          @options["openstack"].is_a?(Hash) &&
          @options["openstack"]["openstack_auth_url"] &&
          @options["openstack"]["openstack_username"] &&
          @options["openstack"]["openstack_api_key"] &&
          @options["openstack"]["openstack_tenant"]
        raise ArgumentError, "Invalid OpenStack configuration parameters"
      end
    end

  end

end
