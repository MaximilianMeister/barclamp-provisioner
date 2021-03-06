# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

states = node["provisioner"]["dhcp"]["state_machine"]
tftproot = node["provisioner"]["root"]
timezone = (node["provisioner"]["timezone"] rescue "UTC") || "UTC"
pxecfg_dir = "#{tftproot}/discovery/pxelinux.cfg"
uefi_dir = "#{tftproot}/discovery"
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
web_port = node[:provisioner][:web_port]
provisioner_web = "http://#{admin_ip}:#{web_port}"
dhcp_hosts_dir = node["provisioner"]["dhcp_hosts"]

nodes = search(:node, "*:*")
if not nodes.nil? and not nodes.empty?
  nodes.map{|n|Node.load(n.name)}.each do |mnode|
    next if mnode[:state].nil?

    new_group = states[mnode[:state]]
    if new_group.nil? || new_group == "noop"
      Chef::Log.info("#{mnode[:fqdn]}: #{mnode[:state]} does not map to a DHCP state.")
      next
    end

    boot_ip_hex = mnode["crowbar"]["boot_ip_hex"] rescue nil
    Chef::Log.info("#{mnode[:fqdn]}: transition to #{new_group} boot file: #{boot_ip_hex}")

    mac_list = []
    unless mnode["network"].nil? || mnode["network"]["interfaces"].nil?
      mnode["network"]["interfaces"].each do |net, net_data|
        net_data.each do |field, field_data|
          next if field != "addresses"
          field_data.each do |addr, addr_data|
            next if addr_data["family"] != "lladdr"
            mac_list << addr unless mac_list.include? addr
          end
        end
      end
      mac_list.sort!
    end
    Chef::Log.warn("#{mnode[:fqdn]}: no MAC address found; DHCP will not work for that node!") if mac_list.empty?

    # delete dhcp hosts that we will not overwrite/delete (ie, index is too
    # high); this happens if there were more mac addresses at some point in the
    # past
    valid_host_files = mac_list.each_with_index.map { |mac, i| "#{mnode.name}-#{i}" }
    host_files = Dir.glob("#{dhcp_hosts_dir}/#{mnode.name}-*.conf")
    host_files.each do |absolute_host_file|
      host_file = ::File.basename(absolute_host_file, ".conf")
      unless valid_host_files.include? host_file
        dhcp_host host_file do
          action :remove
        end
      end
    end

    # no boot_ip means that no admin network address has been assigned to node,
    # and it will boot into the default discovery image. But it won't help if
    # we're trying to delete the node.
    if boot_ip_hex
      pxefile = "#{pxecfg_dir}/#{boot_ip_hex}"
      uefifile = "#{uefi_dir}/#{boot_ip_hex}.conf"
    else
      Chef::Log.warn("#{mnode[:fqdn]}: no boot IP known; PXE/UEFI boot files won't get updated!")
      pxefile = nil
      uefifile = nil
    end

    # needed for dhcp
    admin_data_net = Chef::Recipe::Barclamp::Inventory.get_network_by_type(mnode, "admin")

    case
    when (new_group == "delete")
      Chef::Log.info("Deleting #{mnode[:fqdn]}")
      # Delete the node
      system("knife node delete -y #{mnode.name} -u chef-webui -k /etc/chef/webui.pem")
      system("knife role delete -y crowbar-#{mnode.name.gsub(".","_")} -u chef-webui -k /etc/chef/webui.pem")

      # find all dhcp hosts for a node (not just ones matching currently known MACs)
      host_files = Dir.glob("#{dhcp_hosts_dir}/#{mnode.name}-*.conf")
      host_files.each do |host_file|
        dhcp_host ::File.basename(host_file, ".conf") do
          action :remove
        end
      end

      [pxefile,uefifile].each do |f|
        file f do
          action :delete
        end unless f.nil?
      end

      directory "#{tftproot}/nodes/#{mnode[:fqdn]}" do
        recursive true
        action :delete
      end

    when new_group == "execute"
      mac_list.each_index do |i|
        dhcp_host "#{mnode.name}-#{i}" do
          hostname mnode.name
          if mnode.macaddress == mac_list[i]
            ipaddress admin_data_net.address
          end
          macaddress mac_list[i]
          action :add
        end
      end

      [pxefile,uefifile].each do |f|
        file f do
          action :delete
        end unless f.nil?
      end

    else
      append = []
      mac_list.each_index do |i|
        dhcp_host "#{mnode.name}-#{i}" do
          hostname mnode.name
          macaddress mac_list[i]
          if mnode.macaddress == mac_list[i]
            ipaddress admin_data_net.address
            options [
     '      if option arch = 00:06 {
        filename = "discovery/bootia32.efi";
     } else if option arch = 00:07 {
        filename = "discovery/bootx64.efi";
     } else if option arch = 00:09 {
        filename = "discovery/bootx64.efi";
     } else {
        filename = "discovery/pxelinux.0";
     }',
                     "next-server #{admin_ip}"
                    ]
          end
          action :add
        end
      end

      if new_group == "os_install"
        # This eventaully needs to be conifgurable on a per-node basis
        # We select the os based on the target platform specified.
        os=mnode[:target_platform]
        if os.nil? or os.empty?
          os = node[:provisioner][:default_os]
        end

        unless defined?(append) and append.include? node[:provisioner][:available_oses][os][:append_line]
          append << node[:provisioner][:available_oses][os][:append_line]
        end

        append << node[:provisioner][:available_oses][os][:append_line]
        node_cfg_dir="#{tftproot}/nodes/#{mnode[:fqdn]}"
        node_url="#{provisioner_web}/nodes/#{mnode[:fqdn]}"
        os_url="#{provisioner_web}/#{os}"
        install_url="#{os_url}/install"

        directory node_cfg_dir do
          action :create
          owner "root"
          group "root"
          mode "0755"
          recursive true
        end

        if (mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"] rescue nil)
          append << "BOOTIF=01-#{mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"].gsub(':',"-")}"
        end

        case
        when os =~ /^ubuntu/
          append << "url=#{node_url}/net_seed"
          template "#{node_cfg_dir}/net_seed" do
            mode 0644
            owner "root"
            group "root"
            source "net_seed.erb"
            variables(:install_name => os,
                      :cc_use_local_security => node[:provisioner][:use_local_security],
                      :cc_install_web_port => web_port,
                      :boot_device => (mnode[:crowbar_wall][:boot_device] rescue nil),
                      :cc_built_admin_node_ip => admin_ip,
                      :timezone => timezone,
                      :node_name => mnode[:fqdn],
                      :install_path => "#{os}/install")
          end

        when os =~ /^(redhat|centos)/
          append << "ks=#{node_url}/compute.ks method=#{install_url}"
          template "#{node_cfg_dir}/compute.ks" do
            mode 0644
            source "compute.ks.erb"
            owner "root"
            group "root"
            variables(
                      :admin_node_ip => admin_ip,
                      :web_port => web_port,
                      :node_name => mnode[:fqdn],
                      :boot_device => (mnode[:crowbar_wall][:boot_device] rescue nil),
                      :repos => node[:provisioner][:repositories][os],
                      :uefi => (mnode[:crowbar_wall][:uefi] rescue nil),
                      :admin_web => install_url,
                      :timezone => timezone,
                      :crowbar_join => "#{os_url}/crowbar_join.sh")
          end

        when os =~ /^(open)?suse/
          append << "install=#{install_url} autoyast=#{node_url}/autoyast.xml"

          Provisioner::Repositories.inspect_repos(node)
          repos = Provisioner::Repositories.get_repos(node, "suse")
          Chef::Log.info("repos: #{repos.inspect}")

          if node[:provisioner][:suse]
            if node[:provisioner][:suse][:autoyast]
              ssh_password = node[:provisioner][:suse][:autoyast][:ssh_password]
              append << "UseSSH=1 SSHPassword=#{ssh_password}" if ssh_password
            end
          end

          template "#{node_cfg_dir}/autoyast.xml" do
            mode 0644
            source "autoyast.xml.erb"
            owner "root"
            group "root"
            variables(
                      :admin_node_ip => admin_ip,
                      :web_port => web_port,
                      :repos => repos,
                      :rootpw_hash => node[:provisioner][:root_password_hash] || "",
                      :timezone => timezone,
                      :boot_device => (mnode[:crowbar_wall][:boot_device] rescue nil),
                      :raid_type => (mnode[:crowbar_wall][:raid_type] || "single"),
                      :raid_disks => (mnode[:crowbar_wall][:raid_disks] || []),
                      :node_name => mnode[:fqdn],
                      :crowbar_join => "#{os_url}/crowbar_join.sh")
          end

        when os =~ /^(hyperv|windows)/
          os_dir_win = "#{tftproot}/#{os}"
          crowbar_key = ::File.read("/etc/crowbar.install.key").chomp.strip
          case
          when /^windows/ =~ os
            image_name = "Windows Server 2012 SERVERSTANDARD"
          when /^hyperv/ =~ os
            image_name = "Hyper-V Server 2012 SERVERHYPERCORE"
          end
          template "#{os_dir_win}/unattend/unattended.xml" do
            mode 0644
            owner "root"
            group "root"
            source "unattended.xml.erb"
            variables(:license_key => mnode[:license_key] || "",
                      :os_name => os,
                      :image_name => image_name,
                      :admin_ip => admin_ip,
                      :admin_name => node[:hostname],
                      :crowbar_key => crowbar_key,
                      :admin_pass => "crowbar",
                      :domain_name => node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain]))
          end

        else
          raise RangeError.new("Do not know how to handle #{os} in update_nodes.rb!")
        end

        [{:file => pxefile, :src => "default.erb"},
         {:file => uefifile, :src => "default.elilo.erb"}].each do |t|
          template t[:file] do
            mode 0644
            owner "root"
            group "root"
            source t[:src]
            variables(:append_line => append.join(' '),
                      :install_name => node[:provisioner][:available_oses][os][:install_name],
                      :initrd => node[:provisioner][:available_oses][os][:initrd],
                      :kernel => node[:provisioner][:available_oses][os][:kernel])
          end unless t[:file].nil?
        end

      else
        [{:file => pxefile, :src => "default.erb"},
         {:file => uefifile, :src => "default.elilo.erb"}].each do |t|
          template t[:file] do
            mode 0644
            owner "root"
            group "root"
            source t[:src]
            variables(:append_line => "#{node[:provisioner][:sledgehammer_append_line]} crowbar.hostname=#{mnode[:fqdn]} crowbar.state=#{new_group}",
                      :install_name => new_group,
                      :initrd => "initrd0.img",
                      :kernel => "vmlinuz0")
          end unless t[:file].nil?
        end
      end
    end
  end
end
