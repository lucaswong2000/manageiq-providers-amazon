class ManageIQ::Providers::Amazon::Inventory::Collector::TargetCollection < ManageIQ::Providers::Amazon::Inventory::Collector
  def initialize(_manager, _target)
    super
    parse_targets!
    infer_related_ems_refs!

    # Reset the target cache, so we can access new targets inside
    target.manager_refs_by_association_reset
  end

  def references(collection)
    target.manager_refs_by_association.try(:[], collection).try(:[], :ems_ref).try(:to_a) || []
  end

  def instances
    return @instances unless @instances.blank?
    @instances = hash_collection.new(
      aws_ec2.instances(:filters => [{:name => 'instance-id', :values => references(:vms)}])
    )
  end

  def private_images
    hash_collection.new(
      aws_ec2.client.describe_images(:filters => [{:name => 'image-id', :values => references(:miq_templates)}]).images
    )
  end

  def stacks
    # TODO(lsmola) we can filter only one stack, so that means too many requests, lets try to figure out why
    # CLoudFormations API doesn't support a standard filter
    result = references(:orchestrations_stacks).map do |stack_ref|
      begin
        aws_cloud_formation.client.describe_stacks(:stack_name => stack_ref)[:stacks]
      rescue Aws::CloudFormation::Errors::ValidationError => _e
        # A missing stack throws and exception like this, we want to ignore it and just don't list it
      end
    end.flatten.compact

    hash_collection.new(result)
  end

  def cloud_networks
    hash_collection.new(
      aws_ec2.client.describe_vpcs(:filters => [{:name => 'vpc-id', :values => references(:cloud_networks)}]).vpcs
    )
  end

  def cloud_subnets
    hash_collection.new(
      aws_ec2.client.describe_subnets(:filters => [{:name => 'subnet-id', :values => references(:cloud_subnets)}]).subnets
    )
  end

  def security_groups
    hash_collection.new(
      aws_ec2.security_groups(:filters => [{:name => 'group-id', :values => references(:security_groups).to_a}])
    )
  end

  def network_ports
    return @network_ports unless @network_ports.blank?

    @network_ports = hash_collection.new(aws_ec2.client.describe_network_interfaces(
      :filters => [{:name => 'network-interface-id', :values => references(:network_ports).to_a}]
    ).network_interfaces)
  end

  def load_balancers
    return [] if references(:load_balancers).blank?

    result = []
    references(:load_balancers).each do |load_balancers_ref|
      begin
        result += aws_elb.client.describe_load_balancers(
          :load_balancer_names => [load_balancers_ref]
        ).load_balancer_descriptions
      rescue ::Aws::ElasticLoadBalancing::Errors::LoadBalancerNotFound => _e
        # TODO(lsmola) maybe it will be faster to fetch all LBs and filter them?
        # Ignore LB that was not found, it will be deleted from our DB
      end
    end

    hash_collection.new(result)
  end

  def floating_ips
    hash_collection.new(
      aws_ec2.client.describe_addresses(:filters => [{:name => 'allocation-id', :values => references(:floating_ips)}]).addresses
    )
  end

  def cloud_volumes
    hash_collection.new(
      aws_ec2.client.describe_volumes(:filters => [{:name => 'volume-id', :values => references(:cloud_volumes)}]).volumes
    )
  end

  def cloud_volume_snapshots
    hash_collection.new(
      aws_ec2.client.describe_snapshots(
        :filters => [{:name => 'snapshot-id', :values => references(:cloud_volumes_snapshots)}]
      ).snapshots
    )
  end

  def cloud_object_store_containers
    # hash_collection.new(aws_s3.client.list_buckets.buckets)
    []
  end

  def cloud_object_store_objects
    # hash_collection.new([])
    []
  end

  # Nested API calls, we want all of them for our filtered list of LBs and Stacks
  def stack_resources(stack_name)
    begin
      stack_resources = aws_cloud_formation.client.list_stack_resources(:stack_name => stack_name).try(:stack_resource_summaries)
    rescue Aws::CloudFormation::Errors::ValidationError => _e
      # When Stack was deleted we want to return empty list of resources
    end

    hash_collection.new(stack_resources || [])
  end

  def health_check_members(load_balancer_name)
    hash_collection.new(aws_elb.client.describe_instance_health(
      :load_balancer_name => load_balancer_name
    ).instance_states)
  end

  def stack_template(stack_name)
    aws_cloud_formation.client.get_template(:stack_name => stack_name).template_body
  rescue Aws::CloudFormation::Errors::ValidationError => _e
    # When Stack was deleted we want to return empty string for template
    ""
  end

  private

  def parse_targets!
    target.targets.each do |t|
      case t
      when Vm
        parse_vm_target!(t)
      end
    end
  end

  def parse_vm_target!(t)
    add_simple_target!(:vms, t.ems_ref)
  end

  def infer_related_ems_refs!
    # We have a list of instances_refs collected from events. Now we want to look into our DB and API, and collect
    # ems_refs of every related object. Now this is not very nice fro ma design point of view, but we really want
    # to see changes in VM's associated objects, so the VM view is always consistent and have fresh data. The partial
    # reason for this is, that AWS doesn't send all the objects state change,
    unless references(:vms).blank?
      infer_related_vm_ems_refs_db!
      infer_related_vm_ems_refs_api!
    end
  end

  def infer_related_vm_ems_refs_db!
    changed_vms = manager.vms.where(:ems_ref => references(:vms)).includes(:key_pairs, :network_ports, :floating_ips,
                                                                           :orchestration_stack, :cloud_subnets)
    changed_vms.each do |vm|
      stack      = vm.orchestration_stack
      all_stacks = ([stack] + (stack.try(:ancestors) || [])).compact

      all_stacks.collect(&:ems_ref).compact.each { |ems_ref| add_simple_target!(:orchestration_stacks, ems_ref) }
      vm.key_pairs.collect(&:name).compact.each { |ems_ref| add_simple_target!(:key_pairs, ems_ref) }
      vm.network_ports.collect(&:ems_ref).compact.each { |ems_ref| add_simple_target!(:network_ports, ems_ref) }
      vm.cloud_subnets.collect(&:ems_ref).compact.each { |ems_ref| add_simple_target!(:cloud_subnets, ems_ref) }
      vm.floating_ips.collect(&:ems_ref).compact.each { |ems_ref| add_simple_target!(:floating_ips, ems_ref) }
    end
  end

  def infer_related_vm_ems_refs_api!
    # TODO(lsmola) should we filter the VMs by only VMs we want to do full refresh for? Some of them, like FloatingIps
    # need to be scanned for all, due to the fake FloatingIps we create.
    instances.each do |vm|
      add_simple_target!(:miq_templates, vm["image_id"])
      add_simple_target!(:key_pairs, vm["key_name"])
      add_simple_target!(:orchestration_stacks, get_from_tags(vm, "aws:cloudformation:stack-id"))

      vm["network_interfaces"].each do |network_interface|
        add_simple_target!(:network_ports, network_interface["network_interface_id"])
        add_simple_target!(:cloud_subnet, network_interface["subnet_id"])
        add_simple_target!(:cloud_network, network_interface["vpc_id"])
      end

      vm["security_groups"].each do |security_group|
        add_simple_target!(:security_groups, security_group["group_id"])
      end

      vm["block_device_mappings"].each do |cloud_volume|
        add_simple_target!(:cloud_volumes, cloud_volume.fetch_path("ebs", "volume_id"))
      end

      # EC2 classic floating ips
      if vm["network_interfaces"].blank? && vm['public_ip_address'].present?
        add_simple_target!(:floating_ips, vm['public_ip_address'])
      end
    end

    # TODO(lsmola) I don't like this anymore, the TargetCollection should just build structure with unique targets
    # inside. The we don't need to do this cache invalidate, since add_target would be modifying it directly.
    # Reset target cache, so we can get a fresh list of network_ports ids
    target.manager_refs_by_association_reset

    # We need to go through all network ports, to get a correct list of the floating IPs, for some reason, the list
    # under a vm is missing allocation_ids.
    network_ports.each do |network_port|
      network_port['private_ip_addresses'].each do |private_ip_address|
        floating_ip_id = (private_ip_address.fetch_path("association", "allocation_id") ||
          private_ip_address.fetch_path("association", "public_ip"))
        add_simple_target!(:floating_ips, floating_ip_id)
      end
    end
  end

  def add_simple_target!(association, ems_ref)
    return if ems_ref.blank?

    target.add_target(:association => association, :manager_ref => {:ems_ref => ems_ref})
  end

  def get_from_tags(resource, item)
    (resource['tags'] || []).detect { |tag, _| tag['key'].downcase == item.to_s.downcase }.try(:[], 'value')
  end
end
